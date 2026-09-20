import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../config/api_config.dart';
import '../l10n/app_strings.dart';
import '../models/frame_playback_profile.dart';
import '../services/app_diag_log.dart';
import '../services/device_store.dart';
import '../services/gallery_photo_picker.dart';
import '../services/frame_api_client.dart';
import '../services/frame_ble_mac_slug.dart';
import '../services/frame_cloud_cast_service.dart';
import '../services/upload_queue_controller.dart';
import '../services/frame_online_guard.dart';
import '../services/slideshow_playlist_store.dart';
import '../services/slideshow_remote_api.dart';
import '../services/frame_settings_store.dart';
import '../services/ble_frame_device_transport.dart';
import '../settings/app_settings.dart';
import '../services/send_albums_store.dart';
import '../widgets/progress_action_button.dart';
import '../widgets/safe_render_boundary.dart';
import '../widgets/shell_navigation.dart';
import 'frame_settings_screen.dart';

class EditColorGradeScreen extends StatefulWidget {
  final List<File> selectedImages;
  final int initialIntervalSeconds;
  final String playlistName;
  final String? albumId;

  const EditColorGradeScreen({
    super.key,
    required this.selectedImages,
    required this.initialIntervalSeconds,
    required this.playlistName,
    this.albumId,
  });

  @override
  State<EditColorGradeScreen> createState() => _EditColorGradeScreenState();
}

class _EditColorGradeScreenState extends State<EditColorGradeScreen> {
  late List<File> _images;
  late final PageController _pageController;
  int _currentIndex = 0;
  bool _isSending = false;
  int _sendCurrent = 0;
  int _sendTotal = 0;
  int _listEpoch = 0;

  // Global settings loaded cache
  FramePlaybackProfile _globalProfile = FramePlaybackProfile.externalShareDefaults;
  bool _frameOnline = false;

  // ValueNotifier for instant send-button loading feedback
  final ValueNotifier<bool> _sendingNotifier = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _images = List<File>.from(widget.selectedImages);
    _currentIndex = clampImageIndex(0, _images.length);
    _pageController = PageController(initialPage: _currentIndex);
    unawaited(_loadGlobalProfile());
  }

  Future<void> _loadGlobalProfile() async {
    try {
      await DeviceStore.instance.load();
      final paired = DeviceStore.instance.cached;
      final profile = await FrameSettingsStore.instance.load(paired);
      if (!mounted) return;
      final online = paired == null
          ? false
          : await FrameOnlineGuard.isFrameEffectivelyOnline(paired);
      if (!mounted) return;
      setState(() {
        _globalProfile = profile;
        _frameOnline = online;
      });
    } catch (e) {
      AppDiagLog.verbose('[EditColorGrade] load global profile failed: $e');
    }
  }

  @override
  void didUpdateWidget(covariant EditColorGradeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_samePaths(oldWidget.selectedImages, widget.selectedImages)) {
      _adoptImages(List<File>.from(widget.selectedImages));
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  bool _samePaths(List<File> a, List<File> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].path != b[i].path) return false;
    }
    return true;
  }

  void _adoptImages(List<File> next) {
    final clamped = clampImageIndex(_currentIndex, next.length);
    setState(() {
      _images = next;
      _currentIndex = clamped;
      _listEpoch++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      if (_images.isEmpty) return;
      _pageController.jumpToPage(_currentIndex);
    });
  }

  Key get _previewKey => ValueKey(
        'playlist-preview-$_listEpoch-${_images.length}-${_images.map((f) => f.path).join('|').hashCode}',
      );

  Future<void> _handleSendPlaylist() async {
    HapticFeedback.lightImpact();
    if (_isSending) return;
    final total = _images.length;
    if (total == 0) return;
    if (total > kMaxMultiPick) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.of(context).maxPhotosAllowed(kMaxMultiPick))),
      );
      return;
    }

    _isSending = true;
    _sendingNotifier.value = true;
    setState(() {
      _sendCurrent = 0;
      _sendTotal = total;
    });

    SchedulerBinding.instance.addPostFrameCallback((_) => _sendPlaylistHeavy());
  }

  Future<void> _sendPlaylistHeavy() async {
    final s = AppStrings.of(context);
    try {
      if (!mounted) return;
      final app = AppSettingsScope.of(context);
      final authToken = app.authToken;

      await DeviceStore.instance.load();
      final activePaired = DeviceStore.instance.cached;
      if (activePaired == null || !activePaired.canUploadToServer) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s.pleaseConnectFrame), backgroundColor: Colors.red),
          );
        }
        return;
      }
      if (!mounted) return;
      if (!await FrameOnlineGuard.ensureOnlineForSend(context, frame: activePaired)) {
        return;
      }
      if (!mounted) return;

      // Reload global config fresh to ensure sync
      final profile = await FrameSettingsStore.instance.load(activePaired);

      final pairingToken = activePaired.resolvedPairingToken;
      final api = FrameApiClient();
      final allIds = <String>[];
      final allPaths = <String>[];

      final sendFiles = List<File>.from(_images);

      for (var i = 0; i < sendFiles.length; i++) {
        if (!mounted) return;
        setState(() => _sendCurrent = i + 1);

        final file = sendFiles[i];
        allPaths.add(file.path);
        if (!await file.exists()) {
          AppDiagLog.verbose('[EditColorGrade] file not found: ${file.path}');
          continue;
        }

        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        final isFirstUpload = allIds.isEmpty;
        final ts = DateTime.now().millisecondsSinceEpoch;
        final filename = 'slideshow_$ts.jpg';

        final cast = await FrameCloudCastService.instance.castPhoto(
          api: api,
          paired: activePaired,
          jpegBytes: bytes,
          filename: filename,
          slideshowStyle: 'classic',
          displaySeconds: profile.intervalMinutes * 60,
          strings: s,
          userAuthToken: authToken,
          syncSlideshowAfterSuccess: false,
          skipPlay: true,
          editsJson: null,
          onProgress: (_) {},
          // Source isolation: multi-photo playlist uploads must NOT bleed into
          // the user's Personal Album grid. Backend uses source=playlist to
          // exclude these from GET /api/user/gallery.
          source: UploadSource.playlist,
          playlistId: widget.albumId,
          // Multi-image albums: the banner is powered by ONE strategy_bin job
          // (tracked after publish). A lone photo still registers its single push.
          registerPushProgress: sendFiles.length == 1,
        );

        if (!cast.ok) {
          AppDiagLog.verbose('[EditColorGrade] upload ${i + 1} failed: ${cast.message}');
          continue;
        }

        final id = cast.slideshowImageId?.trim();
        if (id != null && id.isNotEmpty && !allIds.contains(id)) {
          allIds.add(id);
        }

        if (i + 1 < sendFiles.length) {
          await Future<void>.delayed(const Duration(seconds: 5));
        }
      }

      if (allIds.length != sendFiles.length) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s.allUploadsFailed), backgroundColor: Colors.red),
          );
        }
        return;
      }

      final name = widget.playlistName.trim().isEmpty
          ? s.myNewPlaylist
          : widget.playlistName.trim();
      final albumId = widget.albumId?.trim();
      if (albumId != null && albumId.isNotEmpty) {
        final ok = await SendAlbumsStore.instance.replaceAlbumPaths(albumId, allPaths);
        if (!ok) {
          await SendAlbumsStore.instance.createAlbum(name, allPaths);
        } else if (name.isNotEmpty) {
          await SendAlbumsStore.instance.renameAlbum(albumId, name);
        }
      } else {
        await SendAlbumsStore.instance.createAlbum(name, allPaths);
      }

      unawaited(SlideshowPlaylistStore.instance.save(
        paired: activePaired,
        imageIds: allIds,
        intervalMinutes: profile.intervalMinutes,
        albumId: widget.albumId,
      ));
      try {
        final playlistMsgid = await SlideshowRemoteApi(baseUrl: ApiConfig.baseUrl).publish(
          bearerToken: authToken,
          pairingToken: pairingToken,
          macSlug: frameBleMacSlug(activePaired),
          imageIds: allIds,
          intervalMinutes: profile.intervalMinutes,
          strategy: profile.playbackMode == FramePlaybackProfile.modeRandom ? 2 : 1,
          durationHours: profile.durationHours,
          skipPlay: true,
          source: 'playlist',
        );
        // Track the ONE playlist push job (banner completes on first render ACK).
        if (playlistMsgid != null && playlistMsgid.isNotEmpty) {
          UploadQueueController.instance.trackPush(
            mac: FrameCloudCastService.instance.uploadDeviceId(activePaired),
            msgid: playlistMsgid,
              notifyOnCompletion: false,
              treatTimeoutAsSuccess: true,
            pairingToken: pairingToken,
            userAuthToken: authToken,
          );
        }
      } catch (e) {
        AppDiagLog.verbose('[EditColorGrade] playlist publish failed: $e');
        rethrow;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${s.playlistSent} (${s.selectedPhotos(allIds.length)})'),
          backgroundColor: const Color(0xFF4CAF50),
          duration: const Duration(seconds: 2),
        ),
      );

      await SchedulerBinding.instance.endOfFrame;
      if (!mounted) return;
      ShellNavigation.routeToGalleryAfterCast(context, isPlaylist: true);
    } catch (e, st) {
      AppDiagLog.verbose('[EditColorGrade] send error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.uploadFailed(e.toString())), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        _isSending = false;
        _sendingNotifier.value = false;
        setState(() {
          _sendCurrent = 0;
          _sendTotal = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final s = AppStrings.of(context);
    final cs = Theme.of(context).colorScheme;
    final count = _images.length;
    final safeIndex = clampImageIndex(_currentIndex, count);

    // Target frame parsing
    final paired = DeviceStore.instance.cached;
    final frameName = paired?.frameName ?? s.unknownFrameName;
    final frameSlug = paired != null ? frameBleMacSlug(paired).toUpperCase() : '';
    final isOnline = _frameOnline;

    // Apply rule strings localization
    final modeLabel = _globalProfile.playbackMode == FramePlaybackProfile.modeRandom ? s.randomShuffle : s.sequential;
    final ruleText = s.appliedRuleLabel('${_globalProfile.intervalMinutes}', modeLabel);

    return PopScope(
      canPop: !_isSending,
      child: Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(
          leading: IconButton(
            icon: Icon(Icons.chevron_left, color: cs.onSurface, size: 28),
            onPressed: _isSending ? null : () => Navigator.pop(context),
          ),
          title: Text(
            count == 0
                ? s.multiImageCasting(0, 0)
                : s.multiImageCasting(safeIndex + 1, count),
            style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: SafeArea(
          child: AbsorbPointer(
            absorbing: _isSending,
            child: Column(
              children: [
                Expanded(
                  child: count == 0
                      ? SafeRenderFallback(
                          message: s.playlistAddPhotosBeforeSend,
                          onRetry: () => Navigator.pop(context),
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 8),
                              // Expanded photo carousel taking up major portion of view
                              Container(
                                height: screenHeight * 0.42,
                                decoration: BoxDecoration(
                                  color: cs.surface,
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: Theme.of(context).brightness == Brightness.dark
                                            ? 0.35
                                            : 0.04,
                                      ),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: SafeRenderBoundary(
                                    child: PageView.builder(
                                      key: _previewKey,
                                      controller: _pageController,
                                      itemCount: count,
                                      onPageChanged: (idx) {
                                        setState(() {
                                          _currentIndex = clampImageIndex(idx, _images.length);
                                        });
                                      },
                                      itemBuilder: (context, index) {
                                        if (index < 0 || index >= _images.length) {
                                          return SafeRenderFallback(onRetry: () {
                                            setState(() {
                                              _currentIndex = clampImageIndex(0, _images.length);
                                              _listEpoch++;
                                            });
                                          });
                                        }
                                        final file = _images[index];
                                        return SafeFileImage(
                                          key: ValueKey('img-${file.path}'),
                                          path: file.path,
                                          fit: BoxFit.contain,
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ),
                              if (count > 1)
                                Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: List.generate(count, (i) {
                                      return Container(
                                        width: 6,
                                        height: 6,
                                        margin: const EdgeInsets.symmetric(horizontal: 3),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: i == safeIndex
                                              ? cs.primary
                                              : cs.outlineVariant,
                                        ),
                                      );
                                    }),
                                  ),
                                ),
                              const SizedBox(height: 24),
                              // Sleek Target Frame target Destination Info Card
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.tv_rounded, color: cs.primary, size: 24),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            s.sendingToDevice(frameName),
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                              color: cs.onSurface,
                                            ),
                                          ),
                                          if (frameSlug.isNotEmpty)
                                            Text(
                                              frameSlug,
                                              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                                            ),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: isOnline ? Colors.green : Colors.grey,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      isOnline ? s.statusOnline : s.statusOffline,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: isOnline ? Colors.green : Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              // Active Global Rule summary Chip / Link
                              GestureDetector(
                                onTap: () async {
                                  await Navigator.push<void>(
                                    context,
                                    MaterialPageRoute(builder: (_) => const FrameSettingsScreen()),
                                  );
                                  unawaited(_loadGlobalProfile());
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: cs.primary.withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: cs.primary.withValues(alpha: 0.15)),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(Icons.tune_rounded, size: 16, color: cs.primary),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          ruleText,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: cs.primary,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        s.editLabel,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: cs.primary,
                                          decoration: TextDecoration.underline,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                            ],
                          ),
                        ),
                ),
                Material(
                  color: cs.surface,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _sendingNotifier,
                      builder: (context, isSending, _) {
                        return ProgressActionButton(
                          label: s.sendPlaylistN(count),
                          isLoading: isSending,
                          statusMessage: s.progressSendingPhotos,
                          currentStep: _sendCurrent > 0 ? _sendCurrent : null,
                          totalSteps: _sendTotal > 1 ? _sendTotal : null,
                          progress: (isSending && _sendTotal > 0 && _sendCurrent > 0)
                              ? (_sendCurrent / _sendTotal).clamp(0.05, 1.0)
                              : null,
                          onPressed: (isSending || count == 0) ? null : _handleSendPlaylist,
                          backgroundColor: cs.primary,
                          foregroundColor: cs.onPrimary,
                          disabledBackgroundColor: cs.primary.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(14),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
