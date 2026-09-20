import '../core/utils/error_sanitizer.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as imgLib;
import 'package:image_picker/image_picker.dart';

import '../services/gallery_photo_picker.dart';
import '../services/gallery_image_normalizer.dart';
import '../config/api_config.dart';
import '../l10n/app_strings.dart';
import '../services/app_diag_log.dart';
import '../services/device_store.dart';
import '../services/frame_api_client.dart';
import '../services/frame_cloud_cast_service.dart';
import '../services/upload_queue_controller.dart';
import '../services/frame_online_guard.dart';
import '../services/network_link.dart';
import '../services/slideshow_playlist_store.dart';
import '../services/slideshow_style.dart';
import '../services/slideshow_remote_api.dart';
import '../services/frame_ble_mac_slug.dart';
import '../widgets/shell_navigation.dart';
import '../widgets/frame_target_selector.dart';
import '../services/user_playlist_remote_api.dart';
import '../settings/app_settings.dart';
import '../widgets/progress_action_button.dart';

/// Multi-photo upload with progress + server slideshow playlist POST.
class SlideshowBatchScreen extends StatefulWidget {
  const SlideshowBatchScreen({
    super.key,
    this.imagePaths,
    this.playlistTitle,
    this.albumId,
  });

  /// When set, skip the gallery picker and upload these local files.
  final List<String>? imagePaths;
  final String? playlistTitle;
  final String? albumId;

  @override
  State<SlideshowBatchScreen> createState() => _SlideshowBatchScreenState();
}

class _SlideshowBatchScreenState extends State<SlideshowBatchScreen> {
  static const _intervals = [2, 5, 10, 30, 60];
  int _intervalMinutes = 10;
  var _busy = false;
  var _sendCurrent = 0;
  var _sendTotal = 0;
  final _api = FrameApiClient();

  bool get _hasPresetPaths =>
      widget.imagePaths != null && widget.imagePaths!.isNotEmpty;

  String _intervalLabel(AppStrings s, int m) {
    return switch (m) {
      2 => '2 min',
      5 => '5 min',
      10 => '10 min',
      30 => '30 min',
      60 => '1 h',
      _ => '$m min',
    };
  }

  Future<List<XFile>> _pickPhotos() => GalleryPhotoPicker.pickMulti(context);

  Set<String> _targetIds = {};

  List<PairedFrame> _selectedFrames(List<PairedFrame> all, PairedFrame active) {
    final sel = all.where((f) => _targetIds.contains(f.deviceId)).toList();
    if (sel.isEmpty) return [active];
    return sel;
  }

  Future<void> _runPipeline() async {
    if (_busy) return;
    final s = AppStrings.of(context);
    await DeviceStore.instance.load();
    final active = DeviceStore.instance.cached;
    final allFrames =
        DeviceStore.instance.pairedFrames.where((f) => f.canUploadToServer).toList();
    if (active == null || !active.canUploadToServer) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(s.connectFrameFirst)));
      }
      return;
    }
    if (!await FrameOnlineGuard.ensureOnlineForSend(context, frame: active)) {
      return;
    }

    final presetPaths = _hasPresetPaths
        ? widget.imagePaths!
            .where((p) {
              try {
                return File(p).existsSync();
              } catch (_) {
                return false;
              }
            })
            .toList()
        : <String>[];
    final picked = _hasPresetPaths ? <XFile>[] : await _pickPhotos();
    if (_hasPresetPaths) {
      if (presetPaths.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(s.playlistNeedPhotos)));
        }
        return;
      }
    } else if (picked.isEmpty) {
      return;
    }
    if (!(await hasNetworkInterface())) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(s.authErrorNetwork)));
      }
      return;
    }

    final sourcePaths = _hasPresetPaths
        ? presetPaths
        : picked.map((f) => f.path).toList();
    if (sourcePaths.toSet().length < sourcePaths.length) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(s.duplicatePhotosError)));
      }
      return;
    }

    final token = AppSettingsScope.of(context).authToken.trim();
    final targets = _selectedFrames(allFrames, active);
    setState(() {
      _busy = true;
      _sendCurrent = 0;
      _sendTotal = sourcePaths.length;
    });

    final failures = <String>[];
    var anySuccess = false;
    try {
      for (var fi = 0; fi < targets.length; fi++) {
        final frame = targets[fi];
        if (!mounted) break;
        final frameTitle = frame.listDisplayTitle(s);
        if (targets.length > 1) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(days: 1),
            content: Text('$frameTitle · ${s.slideshowSendingProgress(1, sourcePaths.length)}'),
          ));
        }
        try {
          await _sendPlaylistToFrame(
            frame: frame,
            sourcePaths: sourcePaths,
            token: token,
            s: s,
          );
          anySuccess = true;
        } catch (e, st) {
          AppDiagLog.verbose('[Slideshow] frame "$frameTitle" failed: $e\n$st');
          failures.add('$frameTitle: ${ErrorSanitizer.getUserFriendlyMessage(e)}');
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (anySuccess) {
        final msg = failures.isEmpty
            ? s.slideshowBatchDone(sourcePaths.length)
            : '${s.slideshowBatchDone(sourcePaths.length)} · ${failures.length} failed';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        ShellNavigation.routeToGalleryAfterCast(context, isPlaylist: true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(failures.isNotEmpty ? failures.first : s.slideshowSendFailedHint),
        ));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _sendCurrent = 0;
          _sendTotal = 0;
        });
      }
    }
  }

  /// Uploads every photo sequentially to ONE frame, then commits the playlist.
  /// Throws on the first failure so the caller can isolate per-frame errors.
  Future<void> _sendPlaylistToFrame({
    required PairedFrame frame,
    required List<String> sourcePaths,
    required String token,
    required AppStrings s,
  }) async {
    final total = sourcePaths.length;
    final pairingToken = frame.resolvedPairingToken;
    final ids = <String>[];

    for (var i = 0; i < total; i++) {
      if (!mounted) break;
      final idx = i + 1;
      setState(() => _sendCurrent = idx);
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(days: 1),
          content: Text(s.slideshowSendingProgress(idx, total)),
        ),
      );

      final raw = await File(sourcePaths[i]).readAsBytes();
      final jpeg = await GalleryImageNormalizer.toJpegBytes(
        raw,
        pathHint: sourcePaths[i],
      );
      if (jpeg == null || jpeg.isEmpty) {
        throw StateError('Unable to prepare playlist photo');
      }
      final img = imgLib.decodeImage(jpeg);
      if (img == null) {
        throw StateError('Unable to decode playlist photo');
      }
      final resized = imgLib.copyResize(img, width: 1200);
      final compressed = Uint8List.fromList(imgLib.encodeJpg(resized, quality: 85));

      final ts = DateTime.now().millisecondsSinceEpoch;
      final cast = await FrameCloudCastService.instance.castPhoto(
        api: _api,
        paired: frame,
        jpegBytes: compressed,
        filename: 'slideshow_$ts.bin',
        slideshowStyle: SlideshowStyle.fade.apiValue,
        strings: s,
        userAuthToken: token.isNotEmpty ? token : null,
        syncSlideshowAfterSuccess: false,
        skipPlay: true,
        onProgress: (_) {},
        source: UploadSource.playlist,
        playlistId: widget.albumId,
        registerPushProgress: total == 1,
      );
      if (!cast.ok) {
        throw StateError(cast.message);
      }
      final id = cast.slideshowImageId?.trim();
      if (id != null && id.isNotEmpty && !ids.contains(id)) {
        ids.add(id);
      }
      if (i + 1 < total) {
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }

    if (ids.length != total) {
      throw StateError(s.slideshowSendFailedHint);
    }

    await SlideshowPlaylistStore.instance.save(
      paired: frame,
      imageIds: ids,
      intervalMinutes: _intervalMinutes,
    );
    final playlistMsgid = await SlideshowRemoteApi(baseUrl: ApiConfig.baseUrl).publish(
      bearerToken: token.isNotEmpty ? token : null,
      pairingToken: pairingToken,
      macSlug: frameBleMacSlug(frame),
      imageIds: ids,
      intervalMinutes: _intervalMinutes,
      skipPlay: true,
      source: 'playlist',
    );
    if (playlistMsgid != null && playlistMsgid.isNotEmpty) {
      UploadQueueController.instance.trackPush(
        mac: FrameCloudCastService.instance.uploadDeviceId(frame),
        msgid: playlistMsgid,
        notifyOnCompletion: false,
              treatTimeoutAsSuccess: true,
        pairingToken: pairingToken,
        userAuthToken: token.isNotEmpty ? token : null,
      );
    }
    final albumId = widget.albumId?.trim();
    if (albumId != null && albumId.isNotEmpty) {
      try {
        await UserPlaylistRemoteApi(bearerToken: token).updatePlaylistPhotos(
          playlistId: albumId,
          photoIds: ids,
        );
      } catch (e) {
        AppDiagLog.verbose('[Slideshow] playlist sync: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final cs = Theme.of(context).colorScheme;
    final title = widget.playlistTitle?.trim();
    return Scaffold(
      appBar: AppBar(
        title: Text(title?.isNotEmpty == true ? title! : s.slideshowBatchTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Destination target(s): choose one or several paired frames. Uploads
          // run strictly per frame with isolated failures.
          FrameTargetSelector(
            frames: DeviceStore.instance.pairedFrames
                .where((f) => f.canUploadToServer)
                .toList(),
            selectedIds: _targetIds.isEmpty
                ? {
                    if (DeviceStore.instance.cached?.deviceId != null)
                      DeviceStore.instance.cached!.deviceId,
                  }
                : _targetIds,
            onToggle: (id) {
              setState(() {
                final activeId = DeviceStore.instance.cached?.deviceId;
                if (_targetIds.isEmpty && activeId != null) {
                  _targetIds.add(activeId);
                }
                if (_targetIds.contains(id)) {
                  if (_targetIds.length > 1) _targetIds.remove(id);
                } else {
                  _targetIds.add(id);
                }
              });
            },
            title: 'Send to:',
          ),
          if (_hasPresetPaths) ...[
            Text(
              s.slideshowBatchExplain,
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
            ),
            const SizedBox(height: 8),
            Text(
              '${widget.imagePaths!.length} photos',
              style: TextStyle(fontWeight: FontWeight.w700, color: cs.primary),
            ),
            const SizedBox(height: 16),
          ],
          Text(s.slideshowPickInterval, style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in _intervals)
                ChoiceChip(
                  label: Text(_intervalLabel(s, m)),
                  selected: _intervalMinutes == m,
                  onSelected: _busy ? null : (v) => setState(() => _intervalMinutes = m),
                ),
            ],
          ),
          const SizedBox(height: 20),
          ProgressActionButton(
            label: _hasPresetPaths ? s.sendToFrame : s.slideshowRunBatch,
            icon: Icons.collections,
            isLoading: _busy,
            statusMessage: s.progressSendingPhotos,
            currentStep: _sendCurrent > 0 ? _sendCurrent : null,
            totalSteps: _sendTotal > 1 ? _sendTotal : null,
            progress: (_busy && _sendTotal > 0 && _sendCurrent > 0)
                ? (_sendCurrent / _sendTotal).clamp(0.05, 1.0)
                : null,
            onPressed: _busy ? null : _runPipeline,
            height: 52,
            borderRadius: BorderRadius.circular(14),
          ),
        ],
      ),
    );
  }
}
