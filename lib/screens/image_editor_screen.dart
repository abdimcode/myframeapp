import '../core/utils/error_sanitizer.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../config/api_config.dart';
import 'package:path/path.dart' as p;

import '../services/account_sync_service.dart';
import '../services/device_store.dart';
import '../services/gallery_image_cache.dart';
import '../services/personal_gallery_store.dart';
import '../services/frame_api_client.dart';
import '../services/frame_cast_progress.dart';
import '../services/app_diag_log.dart';
import '../services/app_release_guard.dart';
import '../services/cloud_photo_upload_service.dart';
import '../services/in_app_notification_store.dart';
import '../services/sync_pipeline.dart';
// import '../widgets/debug_slog_overlay.dart';
import '../widgets/shell_navigation.dart';
import '../widgets/frame_target_selector.dart';
import '../services/frame_cloud_cast_service.dart';
import '../services/upload_queue_controller.dart';
import '../services/editor_settings_cache.dart';
import '../services/image_processor_service.dart';
import '../services/image_send_isolate_worker.dart';
import '../services/sd_card_export.dart';
import '../services/slideshow_style.dart';
import '../services/slideshow_playlist_store.dart';
import '../services/slideshow_remote_api.dart';
import '../services/frame_ble_mac_slug.dart';
import '../services/frame_online_guard.dart';
import '../services/frame_recovery_service.dart';
import '../services/user_playlist_remote_api.dart';
import '../services/transport_kind.dart';
import '../services/usage_metrics_store.dart';
import '../services/weather_service.dart';
import '../settings/app_settings.dart';
import '../widgets/progress_action_button.dart';
import '../l10n/app_strings.dart';
import '../navigation/pairing_flow_nav.dart';
import '../models/pairing_nav_result.dart';
import '../models/send_overlay_options.dart';
import '../theme/app_theme.dart';
import 'device_discovery_screen.dart';
import 'wifi_provision_screen.dart';

const Color _kEditorRed = AppTheme.primaryRed;

class _PerImageState {
  img.Image? decoded;
  final Uint8List originalBytes;
  int quarterTurns = 0;
  double brightness = 0, contrast = 30, saturation = 0;
  FrameImageFilter filter = FrameImageFilter.none;
  bool oDate = false, oLocation = false, oGreeting = false, oWeather = false;
  String overlayText = '';
  int textColor = 1;
  double textSize = 24;
  String? selectedSticker;
  double stickerAlignX = 0.35, stickerAlignY = -0.15, stickerSize = 28;
  String cropAspect = '3:4';
  double cropZoom = 100;
  bool flipH = false, flipV = false;
  double cropPanX = 0, cropPanY = 0;
  String borderStyle = 'none';
  String weatherLine = '';
  bool textBold = false;
  double textRotation = 0;
  double stickerRotation = 0;
  String text = '';

  _PerImageState({required this.originalBytes, this.decoded});
}

/// Step 1 from `ra/api`: color grade + filters before resize / E-ink (handled on Send).
class ImageEditorScreen extends StatefulWidget {
  const ImageEditorScreen({
    super.key,
    required this.imageBytes,
    this.deviceId = '',
    this.transport = TransportKind.wifi,
    this.slideshow = SlideshowStyle.fade,
    this.overlay = const SendOverlayOptions(),
    this.overlayLocationOverride,
    this.displaySeconds = 10,
    this.queueIndex = 1,
    this.queueTotal = 1,
    this.galleryPersistPath,
    this.isAiGenerated = false,
    this.autoSendAfterLoad = false,
    this.playlistImages,
    this.playlistPaths,
    this.playlistTitle,
    this.albumId,
  });

  final Uint8List imageBytes;
  final String deviceId;
  final TransportKind transport;
  final SlideshowStyle slideshow;
  final SendOverlayOptions overlay;

  /// When location overlay is on, shown instead of frame name (e.g. city + weather).
  final String? overlayLocationOverride;

  /// Per-photo display duration from album settings sheet (seconds).
  final int displaySeconds;

  /// When sending multiple picks: 1-based index and total count.
  final int queueIndex;
  final int queueTotal;

  /// Durable gallery file from Send pick — updated in place after a successful send.
  final String? galleryPersistPath;

  final bool isAiGenerated;

  /// When true (gallery share flow), upload starts once pairing is loaded.
  final bool autoSendAfterLoad;

  final List<Uint8List>? playlistImages;
  final List<String>? playlistPaths;
  final String? playlistTitle;
  final String? albumId;

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

class _ImageEditorScreenState extends State<ImageEditorScreen>
    with WidgetsBindingObserver {
  final _processor = ImageProcessorService();
  final _api = FrameApiClient();

  img.Image? _decoded;
  Timer? _debounce;

  int _quarterTurns = 0;
  double _brightness = 0;
  double _contrast = 0;
  double _saturation = 0;
  FrameImageFilter _filter = FrameImageFilter.none;

  Uint8List? _previewBytes;
  bool _uploading = false;
  String? _status;
  double? _castProgress;
  bool _castProgressIndeterminate = false;
  int _sendCurrent = 0;
  int _sendTotal = 0;
  final List<String> _castLogLines = [];
  bool _sendSucceeded = false;

  /// Multi-target selection (deviceIds). Empty = just the active frame.
  final Set<String> _targetIds = {};

  /// Paired frames selected as extra destinations (excluding [active]).
  List<PairedFrame> _extraTargets(PairedFrame? active) {
    if (active == null || _targetIds.isEmpty) return const [];
    return DeviceStore.instance.pairedFrames
        .where((f) => f.canUploadToServer && f.deviceId != active.deviceId)
        .where((f) => _targetIds.contains(f.deviceId))
        .toList();
  }
  bool _decodeFailed = false;
  ProcessedFrameResult? _cachedProcess;
  PairedFrame? _paired;
  bool? _frameOnline;

  late TransportKind _transport;
  late SlideshowStyle _slideshow;

  AppStrings? _strings;

  bool get _isPlaylist => widget.playlistImages != null && widget.playlistImages!.length > 1;
  List<_PerImageState>? _perStates;
  int _playlistIndex = 0;
  int _playlistIntervalMinutes = 10;
  final PageController _pageController = PageController();

  Uint8List get _currentBytes {
    if (_isPlaylist && _perStates != null && _playlistIndex < _perStates!.length) {
      return _perStates![_playlistIndex].originalBytes;
    }
    return widget.imageBytes;
  }

  /// Photo caption / overlay: top→bottom on image is custom, greeting, location, date (send sheet + `ra/ui` mock).
  bool _oDate = false;
  bool _oLocation = false;
  bool _oGreeting = false;
  late final TextEditingController _overlayText;

  SendOverlayOptions get _currentOverlay {
    const palette = [
      0xFF000000,
      0xFFFFFFFF,
      0xFFFFFF00,
      0xFFFF0000,
      0xFF0000FF,
      0xFF00FF00,
    ];
    final color = (_textColor >= 0 && _textColor < palette.length)
        ? palette[_textColor]
        : 0xFFFFFFFF;
    return SendOverlayOptions(
      showDate: _oDate,
      showLocation: _oLocation && !_oWeather,
      showGreeting: _oGreeting,
      showWeather: _oWeather,
      customText: '',
      greetingCustom: widget.overlay.greetingCustom,
      centerText: _overlayText.text.trim(),
      centerTextColor: color,
      centerTextSize: _textSize,
      centerSticker: _selectedSticker ?? '',
      stickerAlignX: (_stickerAlignX + 1) / 2, // -1..1 → 0..1
      stickerAlignY: (_stickerAlignY + 1) / 2,
      stickerSize: _stickerSize,
      weatherText: _weatherLine,
      borderStyle: _borderStyle,
    );
  }

  String _weatherLine = '';
  bool _weatherLoading = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _strings = AppStrings.of(context);
  }

  String get _overlayLocationValue {
    final s = _strings ?? AppStrings.current;
    final ovr = widget.overlayLocationOverride?.trim();
    if (_oLocation && ovr != null && ovr.isNotEmpty) {
      return ovr;
    }
    final n = _paired?.frameName?.trim();
    if (n != null && n.isNotEmpty) return n;
    if (_paired != null) return _paired!.listDisplayTitle(s);
    return s.frameDefaultDisplayName;
  }

  Future<void> _copyCastDiagnostics() async {
    final buf = StringBuffer();
    final paired = _paired;
    if (paired != null) {
      buf.writeln('Paired deviceId: ${paired.deviceId}');
      buf.writeln('bleRemoteId: ${paired.bleRemoteId ?? '—'}');
      buf.writeln(
        'Upload device_id: ${FrameCloudCastService.instance.uploadDeviceId(paired)}',
      );
      buf.writeln('API base: ${paired.resolvedApiBaseUrl ?? '—'}');
    }
    if (_castLogLines.isNotEmpty) {
      buf.writeln('--- Cast activity ---');
      for (final line in _castLogLines) {
        buf.writeln(line);
      }
    }
    if (_status != null && _status!.trim().isNotEmpty) {
      buf.writeln('--- Status ---');
      buf.writeln(_status);
    }
    final text = buf.toString().trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    final s = AppStrings.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(s.logCopied),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _appendCastLog(CastProgress p) {
    if (!AppDiagLog.isDebugEnabled) return;
    final line = AppDiagLog.castUiLine(p.phase.name, p.message);
    if (line == null) return;
    _castLogLines.add(line);
    if (_castLogLines.length > 14) {
      _castLogLines.removeAt(0);
    }
  }

  String _userFacingCastStatus(CastProgress p, AppStrings s) {
    return AppDiagLog.userFacingStatus(
      p.message,
      fallback: p.phase == CastPhase.failed
          ? s.couldNotSendPhoto
          : s.sendingToFrame,
    );
  }

  Future<void> _finishSuccessfulSend(
    String status, {
    Uint8List? sentJpeg,
  }) async {
    if (!mounted) return;
    setState(() {
      _status = status;
      _uploading = false;
      _sendSucceeded = true;
      _castProgress = 1;
      _castProgressIndeterminate = false;
    });
    unawaited(AccountSyncService.instance.afterUpload());
    unawaited(UsageMetricsStore.instance.markPhotoSentNow());
    unawaited(
      InAppNotificationStore.instance.photoSent(
        frameName:
            _paired?.frameName ??
            _paired?.listDisplayTitle(_strings ?? AppStrings.current),
      ),
    );
    if (sentJpeg != null && sentJpeg.isNotEmpty) {
      unawaited(
        _saveSentPhotoToGallery(
          sentJpeg,
          persistPath: widget.galleryPersistPath,
        ),
      );
    }

    // Show the modern "Pushing to Frame" confirmation, then route to Gallery
    // (unless another queued photo still needs the editor).
    await _showSendSuccessOverlay(status);
    if (!mounted) return;
    final moreInQueue =
        widget.queueTotal > 1 && widget.queueIndex < widget.queueTotal;
    if (moreInQueue) {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
      return;
    }
    _leaveEditorAfterSend();
  }

  /// Brand-red frosted success sheet that auto-dismisses after ~1.5s (or on
  /// "View in Gallery"), then hands off to [_leaveEditorAfterSend] for routing.
  Future<void> _showSendSuccessOverlay(String status) async {
    if (!mounted) return;
    final frameName = _paired?.frameName ?? _strings?.frameDefaultDisplayName ?? 'MyFrame';
    final strings = _strings;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (_) => _PushingBackgroundDialog(
        frameName: frameName,
        strings: strings,
      ),
    );
  }

  /// Pop any remaining send/picker sheets and route straight to Gallery with
  /// the matching inner segment (Personal for single photo, Playlists for an
  /// album/playlist) — never leave the user on the Send menu.
  void _leaveEditorAfterSend() {
    if (!mounted) return;
    ShellNavigation.routeToGalleryAfterCast(context, isPlaylist: _isPlaylist);
  }

  Future<void> _saveSentPhotoToGallery(
    Uint8List jpeg, {
    String? persistPath,
  }) async {
    try {
      final trimmed = persistPath?.trim();
      late final String destPath;
      if (trimmed != null && trimmed.isNotEmpty) {
        destPath = trimmed;
        await File(destPath).writeAsBytes(jpeg, flush: true);
        await PersonalGalleryStore.instance.load();
        // Already in Personal (album create / picker) — do not insert a second entry.
        if (!PersonalGalleryStore.instance.paths.contains(destPath)) {
          await PersonalGalleryStore.instance.addPaths([destPath]);
        }
      } else {
        final dir = await GalleryImageCache.galleryDirForSync();
        destPath = p.join(
          dir.path,
          'sent_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        await File(destPath).writeAsBytes(jpeg, flush: true);
        await PersonalGalleryStore.instance.addPaths([destPath]);
      }

      // Immediate account gallery sync so the other phone sees the cast.
      if (!mounted) return;
      try {
        await SyncPipeline.instance.onPhotoCasted(
          localPath: destPath,
          deviceId: _paired?.deviceId,
        );
      } catch (_) {}
    } catch (e) {
      AppDiagLog.verbose('[Editor] gallery save failed: $e');
    }
  }

  Future<void> _saveCloudCopyIfConfigured({
    required AppSettings app,
    required ComposeUploadIsolateArgs composeArgs,
    required String filename,
  }) async {
    if (CloudPhotoUploadService.instance.backendFor(app) ==
        PhotoStorageBackend.vps) {
      return;
    }
    try {
      final jpeg = await compute(isolateComposeCloudJpeg, composeArgs);
      if (jpeg == null || jpeg.isEmpty) {
        AppDiagLog.log('[Editor] cloud copy skipped: JPEG render failed');
        return;
      }
      final cloud = await CloudPhotoUploadService.instance.uploadIfConfigured(
        app: app,
        bytes: jpeg,
        filename: filename,
      );
      if (cloud == null) return;
      if (!cloud.ok) {
        AppDiagLog.log('[Editor] cloud copy failed: ${cloud.error}');
        return;
      }
      await InAppNotificationStore.instance.cloudUpload(
        provider: cloud.provider,
        fileName: filename,
      );
      AppDiagLog.log('[Editor] saved to ${cloud.provider} ${cloud.webUrl}');
    } catch (e, st) {
      AppDiagLog.log('[Editor] cloud copy failed: $e\n$st');
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final cached = EditorSettingsCache.instance.last;
    _transport = TransportKind.wifi;
    _slideshow = cached?.slideshow ?? widget.slideshow;
    _overlayText = TextEditingController();
    _overlayText.addListener(_onOverlayTextChanged);

    if (widget.displaySeconds >= 60) {
      _playlistIntervalMinutes = widget.displaySeconds ~/ 60;
    }

    if (_isPlaylist) {
      _perStates = [];
      var skipped = 0;
      for (final bytes in widget.playlistImages!) {
        img.Image? decoded;
        try {
          decoded = bytes.isEmpty ? null : _processor.decode(bytes);
        } catch (e, st) {
          AppDiagLog.verbose('[Editor] playlist decode failed: $e\n$st');
          decoded = null;
        }
        if (decoded == null) {
          skipped++;
          continue;
        }
        _perStates!.add(_PerImageState(originalBytes: bytes, decoded: decoded));
      }
      if (_perStates!.isNotEmpty) {
        _restorePerState(0);
        if (skipped > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final s = AppStrings.of(context);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text(
                  '$skipped ${s.decodeError}',
                ),
              ),
            );
          });
        }
      } else {
        _decodeFailed = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(AppStrings.of(context).decodeError),
            ),
          );
        });
      }
    } else {
      // Fresh pick: plain image only — no sticky overlays / filters / grade.
      _oDate = false;
      _oLocation = false;
      _oGreeting = false;
      _oWeather = false;
      _weatherLine = '';
      _brightness = 0;
      _contrast = 30;
      _saturation = 0;
      _filter = FrameImageFilter.none;
      _quarterTurns = 0;
      try {
        if (widget.imageBytes.isEmpty) {
          _decoded = null;
        } else {
          _decoded = _processor.decode(widget.imageBytes);
        }
      } catch (e, st) {
        AppDiagLog.verbose('[Editor] decode failed: $e\n$st');
        _decoded = null;
      }
      if (_decoded != null) {
        _previewBytes = widget.imageBytes; // instant first frame
        _warmFastPreviewCache();
      } else {
        _decodeFailed = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(AppStrings.of(context).decodeError),
            ),
          );
        });
      }
    }
    _loadPairing().then((_) {
      if (!mounted || !widget.autoSendAfterLoad || _decoded == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _uploading || _sendSucceeded) return;
        unawaited(_send());
      });
    });
  }

  void _onOverlayTextChanged() {
    if (!mounted) return;
    setState(() {});
    _invalidateProcessCache();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh cached online state when returning to the editor so a freshly
      // woken frame shows as online without an explicit status flip.
      unawaited(_refreshFrameOnlineOnFocus());
    }
  }

  Future<void> _refreshFrameOnlineOnFocus() async {
    final paired = _paired;
    if (paired == null) {
      await _loadPairing();
      return;
    }
    final online = await FrameOnlineGuard.isFrameEffectivelyOnline(paired);
    if (mounted) setState(() => _frameOnline = online);
  }

  Future<void> _loadPairing() async {
    await DeviceStore.instance.load();
    if (!mounted) return;
    final paired = DeviceStore.instance.cached;
    setState(() {
      _paired = paired;
      _transport = TransportKind.wifi;
    });
    if (paired == null) {
      if (mounted) setState(() => _frameOnline = null);
      return;
    }
    final online = await FrameOnlineGuard.isFrameEffectivelyOnline(paired);
    if (mounted) setState(() => _frameOnline = online);
  }

  void _saveCurrentPerState() {
    if (_perStates == null || _playlistIndex >= _perStates!.length) return;
    final s = _perStates![_playlistIndex];
    s.decoded = _decoded;
    s.quarterTurns = _quarterTurns;
    s.brightness = _brightness;
    s.contrast = _contrast;
    s.saturation = _saturation;
    s.filter = _filter;
    s.oDate = _oDate;
    s.oLocation = _oLocation;
    s.oGreeting = _oGreeting;
    s.oWeather = _oWeather;
    s.overlayText = _overlayText.text;
    s.textColor = _textColor;
    s.textSize = _textSize;
    s.selectedSticker = _selectedSticker;
    s.stickerAlignX = _stickerAlignX;
    s.stickerAlignY = _stickerAlignY;
    s.stickerSize = _stickerSize;
    s.cropAspect = _cropAspect;
    s.cropZoom = _cropZoom;
    s.flipH = _flipH;
    s.flipV = _flipV;
    s.cropPanX = _cropPanX;
    s.cropPanY = _cropPanY;
    s.borderStyle = _borderStyle;
    s.weatherLine = _weatherLine;
    s.textBold = _textBold;
    s.textRotation = _textRotation;
    s.stickerRotation = _stickerRotation;
    s.text = _textController.text;
  }

  void _restorePerState(int index) {
    if (_perStates == null || index >= _perStates!.length) return;
    final s = _perStates![index];
    _decoded = s.decoded;
    _quarterTurns = s.quarterTurns;
    _brightness = s.brightness;
    _contrast = s.contrast;
    _saturation = s.saturation;
    _filter = s.filter;
    _oDate = s.oDate;
    _oLocation = s.oLocation;
    _oGreeting = s.oGreeting;
    _oWeather = s.oWeather;
    _weatherLine = s.weatherLine;
    _textColor = s.textColor;
    _textSize = s.textSize;
    _selectedSticker = s.selectedSticker;
    _stickerAlignX = s.stickerAlignX;
    _stickerAlignY = s.stickerAlignY;
    _stickerSize = s.stickerSize;
    _cropAspect = s.cropAspect;
    _cropZoom = s.cropZoom;
    _flipH = s.flipH;
    _flipV = s.flipV;
    _cropPanX = s.cropPanX;
    _cropPanY = s.cropPanY;
    _borderStyle = s.borderStyle;
    _textBold = s.textBold;
    _textRotation = s.textRotation;
    _stickerRotation = s.stickerRotation;
    _overlayText.text = s.overlayText;
    _textController.text = s.text;
    if (_decoded != null) {
      _previewBytes = s.originalBytes;
    }
    _invalidateProcessCache();
  }

  void _onPageChanged(int index) {
    if (!_isPlaylist || _perStates == null) return;
    final length = _perStates!.length;
    if (length == 0) return;
    final safe = index < 0 ? 0 : (index >= length ? length - 1 : index);
    _saveCurrentPerState();
    setState(() {
      _playlistIndex = safe;
      _restorePerState(safe);
    });
  }

  void _invalidateProcessCache() {
    _cachedProcess = null;
    // Warm the E-ink Preview JPEG in the background so the button opens instantly.
    _warmFastPreviewCache();
  }

  int _previewGen = 0;
  Timer? _previewWarmTimer;

  void _warmFastPreviewCache() {
    _previewWarmTimer?.cancel();
    _previewWarmTimer = Timer(const Duration(milliseconds: 220), () {
      if (!mounted || _decoded == null) return;
      final gen = ++_previewGen;
      final args = _previewArgs();
      compute(isolateFastPreviewJpeg, args).then((bytes) {
        if (!mounted || gen != _previewGen || bytes == null) return;
        _previewBytes = bytes;
      });
    });
  }

  void _schedulePreview({int delayMs = 80}) {
    // Live preview is Flutter-widget based (instant). Isolate only for send cache.
    _cachedProcess = null;
  }

  /// Kept for six-color / export paths that still need a baked JPEG.
  void _renderPreview() {
    if (_decoded == null) return;
    final gen = ++_previewGen;
    final args = _previewArgs();
    compute(isolateFastPreviewJpeg, args).then((bytes) {
      if (!mounted || gen != _previewGen || bytes == null) return;
      setState(() => _previewBytes = bytes);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _overlayText.removeListener(_onOverlayTextChanged);
    EditorSettingsCache.instance.update(
      EditorSettingsSnapshot(
        transport: _transport,
        slideshow: _slideshow,
        showDate: false,
        showLocation: false,
        showGreeting: false,
        customText: '',
        brightness: 0,
        contrast: 0,
        saturation: 0,
        filter: FrameImageFilter.none,
      ),
    );
    _overlayText.dispose();
    _textController.dispose();
    _weatherTempController.dispose();
    _previewTransform.dispose();
    _debounce?.cancel();
    _previewWarmTimer?.cancel();
    _api.close();
    _pageController.dispose();
    super.dispose();
  }

  Future<ProcessedFrameResult?> _ensureProcessed() async {
    if (_decoded == null) return null;
    if (_cachedProcess != null) return _cachedProcess;
    final result = await compute(isolateFrameProcessOnly, _previewArgs());
    _cachedProcess = result;
    return result;
  }

  Future<Uint8List> _compressImage(Uint8List bytes) async {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final resized = img.copyResize(decoded, width: 1200);
    return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
  }

  Map<String, dynamic> _buildEditsJson() {
    final ov = _currentOverlay;
    return {
      'quarterTurns': _quarterTurns,
      'brightness': 1.0 + (_brightness / 100) * 0.35,
      'contrast': 1.0 + (_contrast / 100) * 0.45,
      'saturation': 1.0 + (_saturation / 100) * 0.45,
      'filter': _filter.name,
      'flipH': _flipH,
      'flipV': _flipV,
      'cropAspect': _cropAspectRatioValue,
      'cropZoom': (_cropZoom / 100).clamp(1.0, 3.0),
      'cropPanX': _cropPanX,
      'cropPanY': _cropPanY,
      'alreadyProcessed': true,
      'borderStyle': _borderStyle,
      'overlay': {
        'showDate': ov.showDate,
        'showLocation': ov.showLocation,
        'showGreeting': ov.showGreeting,
        'showWeather': ov.showWeather,
        'centerText': ov.centerText,
        'centerTextColor': '#${ov.centerTextColor.toRadixString(16).padLeft(8, '0').substring(2)}',
        'centerTextSize': ov.centerTextSize,
        'centerSticker': ov.centerSticker,
        'weatherText': ov.weatherText,
        'stickerAlignX': ov.stickerAlignX,
        'stickerAlignY': ov.stickerAlignY,
        'stickerSize': ov.stickerSize,
        'customText': ov.customText,
        'greetingCustom': ov.greetingCustom,
      },
      'locationText': _overlayLocationValue,
    };
  }

  String _buildEditsJsonForIndex(int index) {
    if (_perStates == null || index >= _perStates!.length) return jsonEncode(_buildEditsJson());
    final s = _perStates![index];
    final ov = SendOverlayOptions(
      showDate: s.oDate,
      showLocation: s.oLocation && !s.oWeather,
      showGreeting: s.oGreeting,
      showWeather: s.oWeather,
      customText: '',
      greetingCustom: widget.overlay.greetingCustom,
      centerText: s.overlayText,
      centerTextColor: const [0xFF000000, 0xFFFFFFFF, 0xFFFFFF00, 0xFFFF0000, 0xFF0000FF, 0xFF00FF00][s.textColor.clamp(0, 5)],
      centerTextSize: s.textSize,
      centerSticker: s.selectedSticker ?? '',
      stickerAlignX: (s.stickerAlignX + 1) / 2,
      stickerAlignY: (s.stickerAlignY + 1) / 2,
      stickerSize: s.stickerSize,
      weatherText: s.weatherLine,
      borderStyle: s.borderStyle,
    );
    final paired = _paired;
    final locationTxt = paired?.frameName?.trim() ?? _strings?.frameDefaultDisplayName ?? '';
    return jsonEncode({
      'quarterTurns': s.quarterTurns,
      'brightness': 1.0 + (s.brightness / 100) * 0.35,
      'contrast': 1.0 + (s.contrast / 100) * 0.45,
      'saturation': 1.0 + (s.saturation / 100) * 0.45,
      'filter': s.filter.name,
      'flipH': s.flipH,
      'flipV': s.flipV,
      'cropAspect': _cropAspectRatioValue,
      'cropZoom': (s.cropZoom / 100).clamp(1.0, 3.0),
      'cropPanX': s.cropPanX,
      'cropPanY': s.cropPanY,
      'borderStyle': s.borderStyle,
      'overlay': {
        'showDate': ov.showDate,
        'showLocation': ov.showLocation,
        'showGreeting': ov.showGreeting,
        'showWeather': ov.showWeather,
        'centerText': ov.centerText,
        'centerTextColor': '#${ov.centerTextColor.toRadixString(16).padLeft(8, '0').substring(2)}',
        'centerTextSize': ov.centerTextSize,
        'centerSticker': ov.centerSticker,
        'weatherText': ov.weatherText,
        'stickerAlignX': ov.stickerAlignX,
        'stickerAlignY': ov.stickerAlignY,
        'stickerSize': ov.stickerSize,
        'customText': ov.customText,
        'greetingCustom': ov.greetingCustom,
      },
      'locationText': locationTxt,
    });
  }

  Future<void> _send() async {
    if (_decoded == null) return;
    try {
      await _sendInner();
    } catch (e, st) {
      AppDiagLog.verbose('[Editor] send failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _status = _strings?.sendFailedRetry ?? 'Image sending failed. Please try again. Make sure WiFi is connected to your frame, or delete the device and resend.';
      });
    }
  }

  Future<void> _sendInner() async {
    if (_paired == null) {
      if (!mounted) return;
      setState(() => _status = _strings?.connectFrameToSend ?? 'Connect your frame to send this photo…');
      final result = await SafeNav.push<PairingNavResult>(
        context,
        MaterialPageRoute<PairingNavResult>(
          builder: (_) =>
              const DeviceDiscoveryScreen(openSendAfterSetup: false),
        ),
      );
      await DeviceStore.instance.load();
      await _loadPairing();
      if (!mounted) return;
      if (result?.success != true && _paired == null) {
        setState(() => _status = _strings?.frameConnectionCancelled ?? 'Frame connection cancelled.');
        return;
      }
      if (_paired == null) {
        setState(
          () => _status = _strings?.noFramePaired ?? 'No frame paired yet. Scan a frame to continue.',
        );
        return;
      }
    }
    final frame = _paired!;
    final sEarly = AppStrings.of(context);
    if (!frame.canUploadToServer) {
      if (!mounted) return;
      setState(() {
        _status = frame.resolvedFrameTargetCandidates.isEmpty
            ? (_strings?.iosBleOnlyHint ?? 'This iPhone pairing has only an iOS Bluetooth UUID, not the frame display ID. Scan the frame pairing QR once, then try upload again.')
            : sEarly.pairingNeedsApiUrl;
      });
      return;
    }
    final onlineNow = await FrameOnlineGuard.isFrameEffectivelyOnline(frame);
    if (mounted) setState(() => _frameOnline = onlineNow);
    // Block dispatch when the frame is genuinely offline. Previously this was
    // an optimistic delivery path that always proceeded — now we require the
    // frame to be reachable so photos are not silently lost.
    if (!onlineNow) {
      if (!mounted) return;
      final blocked = await FrameOnlineGuard.ensureOnlineForSend(
        context,
        frame: frame,
      );
      if (!blocked) return; // user dismissed the dialog or frame stayed offline
      // Frame came back online after the wake — refresh.
      final recheck = await FrameOnlineGuard.isFrameEffectivelyOnline(frame);
      if (mounted) setState(() => _frameOnline = recheck);
      if (!recheck) return;
    }
    if (mounted) {
      setState(() =>
          _status = _strings?.uploadWakingFrame ?? 'Waking frame MQTT session…');
    }
    try {
      await FrameRecoveryService.instance.prepareForCloudUpload(frame);
    } catch (_) {
      // Best-effort: the VPS still wakes the frame via the MQTT play publish.
    }
    var activePaired = frame;
    if (!activePaired.isWifiProvisioned) {
      if (!mounted) return;
      setState(() => _status = _strings?.completeWifiBeforeSending ?? 'Complete Wi‑Fi setup before sending photos…');
      final setup = await SafeNav.push<PairingNavResult>(
        context,
        MaterialPageRoute<PairingNavResult>(
          builder: (_) => const WifiProvisionScreen(firstTimeSetup: true),
        ),
      );
      await DeviceStore.instance.load();
      if (!mounted || setup?.success != true) return;
      final refreshed = DeviceStore.instance.cached;
      if (refreshed == null || !refreshed.isWifiProvisioned) return;
      activePaired = refreshed;
    }
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted) return;
    setState(() {
      _uploading = true;
      _sendSucceeded = false;
      _castLogLines.clear();
      _status = _strings?.preparingImage ?? 'Preparing image for frame…';
      _castProgress = null;
      _castProgressIndeterminate = true;
      _sendCurrent = 0;
      _sendTotal = _isPlaylist ? (_perStates?.length ?? 0) : 1;
    });
    try {
      if (!mounted) return;
      final s = AppStrings.of(context);
      final app = AppSettingsScope.of(context);
      final authToken = app.authToken;
      final pairingToken = activePaired.resolvedPairingToken;

      if (_isPlaylist && _perStates != null) {
        final allIds = <String>[];
        final total = _perStates!.length;
        for (var i = 0; i < total; i++) {
          if (!mounted) break;
          _saveCurrentPerState();
          _restorePerState(i);
          setState(() {
            _playlistIndex = i;
            _sendCurrent = i + 1;
            _sendTotal = total;
            _status = '${s.slideshowSendingProgress(i + 1, total)}';
            _castProgress = ((i + 0.15) / total).clamp(0.05, 0.95);
            _castProgressIndeterminate = false;
          });
          await SchedulerBinding.instance.endOfFrame;
          if (!mounted) break;

          final state = _perStates![i];
          final previewArgs = FrameProcessOnlyArgs(
            imageBytes: state.originalBytes,
            quarterTurns: _quarterTurns,
            brightness: 1.0 + (_brightness / 100) * 0.35,
            contrast: 1.0 + (_contrast / 100) * 0.45,
            saturation: 1.0 + (_saturation / 100) * 0.45,
            filterIndex: _filter.index,
            overlay: _currentOverlay,
            locationText: _overlayLocationValue,
            flipH: _flipH,
            flipV: _flipV,
            cropAspect: _cropAspectRatioValue,
            cropZoom: (_cropZoom / 100).clamp(1.0, 3.0),
            cropPanX: _cropPanX,
            cropPanY: _cropPanY,
          );
          final edited = await compute(isolateFastPreviewJpeg, previewArgs) ?? await _compressImage(state.originalBytes);
          final edits = _buildEditsJsonForIndex(i);
          final ts = DateTime.now().millisecondsSinceEpoch;
          final httpName = 'slideshow_$ts.jpg';
          final isFirstUpload = i == 0;
          final cast = await FrameCloudCastService.instance.castPhoto(
            api: _api,
            paired: activePaired,
            jpegBytes: edited,
            filename: httpName,
            slideshowStyle: _slideshow.apiValue,
            displaySeconds: widget.displaySeconds,
            strings: s,
            userAuthToken: authToken,
            syncSlideshowAfterSuccess: false,
            skipPlay: true,
            editsJson: edits,
            onProgress: (_) {},
            // Source isolation: multi-photo playlist uploads must NOT bleed
            // into the user's Personal Album grid. Backend uses source=playlist
            // to exclude these from GET /api/user/gallery.
            source: UploadSource.playlist,
            playlistId: widget.albumId,
            // One strategy_bin playlist job (tracked after publish) powers the
            // banner — never N per-photo single `play` pushes.
            registerPushProgress: false,
          );
          if (!cast.ok) {
            throw StateError(cast.message);
          }
          final id = cast.slideshowImageId?.trim();
          if (id != null && id.isNotEmpty && !allIds.contains(id)) {
            allIds.add(id);
          }
          if (i + 1 < total) {
            await Future<void>.delayed(const Duration(seconds: 5));
          }
        }

        if (allIds.length != total) {
          if (mounted) {
            setState(() => _status = (_strings?.sendFailedRetry ?? 'Image sending failed. Please try again. Make sure WiFi is connected to your frame, or delete the device and resend.'));
          }
          return;
        }

        await SlideshowPlaylistStore.instance.save(
          paired: activePaired,
          imageIds: allIds,
          intervalMinutes: _playlistIntervalMinutes,
          albumId: widget.albumId,
        );

        try {
          final playlistMsgid = await SlideshowRemoteApi(baseUrl: ApiConfig.baseUrl).publish(
            bearerToken: authToken,
            pairingToken: pairingToken,
            macSlug: frameBleMacSlug(activePaired),
            imageIds: allIds,
            intervalMinutes: _playlistIntervalMinutes,
            skipPlay: true,
            source: 'playlist',
          );
          // Track the ONE playlist push job so the banner shows the frame's
          // first-render ACK progression (0.30 -> 0.65 -> 1.00) and auto-
          // dismisses; the rest of the playlist cycles on the frame.
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
        } on SlideshowPublishException catch (e) {
          AppDiagLog.verbose('[Playlist] VPS publish failed ${e.statusCode}: ${e.body}');
          if (mounted) {
            setState(() => _status = (_strings?.slideshowPublishStatus(e.statusCode, e.body) ?? 'Slideshow publish returned ${e.statusCode}. Playlist will not auto-advance. ${e.body}'));
          }
        } catch (e) {
          AppDiagLog.verbose('[Playlist] VPS publish: $e');
          if (mounted) {
            setState(() => _status = ErrorSanitizer.getUserFriendlyMessage(e));
          }
        }

        // Multi-target fan-out: images are already uploaded server-side; commit
        // the SAME playlist to every extra selected frame, isolated per frame.
        for (final extra in _extraTargets(activePaired)) {
          try {
            final extraMsgid = await SlideshowRemoteApi(baseUrl: ApiConfig.baseUrl).publish(
              bearerToken: authToken,
              pairingToken: extra.resolvedPairingToken,
              macSlug: frameBleMacSlug(extra),
              imageIds: allIds,
              intervalMinutes: _playlistIntervalMinutes,
              skipPlay: true,
              source: 'playlist',
            );
            if (extraMsgid != null && extraMsgid.isNotEmpty) {
              UploadQueueController.instance.trackPush(
                mac: FrameCloudCastService.instance.uploadDeviceId(extra),
                msgid: extraMsgid,
                pairingToken: extra.resolvedPairingToken,
                userAuthToken: authToken,
              );
            }
          } catch (e) {
            AppDiagLog.verbose('[Playlist] extra frame publish failed: $e');
          }
        }

        final albumId = widget.albumId?.trim();
        if (albumId != null && albumId.isNotEmpty) {
          try {
            await UserPlaylistRemoteApi(bearerToken: authToken).updatePlaylistPhotos(
              playlistId: albumId,
              photoIds: allIds,
            );
          } catch (e) {
            AppDiagLog.verbose('[Playlist] cloud sync: $e');
          }
        }

        if (mounted) {
          await _finishSuccessfulSend(
            s.slideshowBatchDone(allIds.length),
            sentJpeg: _previewBytes,
          );
        }
        return;
      }

      AppDiagLog.verbose('[Editor] input bytes=${widget.imageBytes.length}');
      final compressed = await _compressImage(_currentBytes);
      _previewBytes = await compute(isolateFastPreviewJpeg, _previewArgs()) ?? compressed;
      final edits = jsonEncode(_buildEditsJson());

      AppDiagLog.verbose('[Editor] preview bytes available=${_previewBytes != null}');

      final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
      final httpName = 'photo_$ts.jpg';

      unawaited(
        _saveCloudCopyIfConfigured(
          app: app,
          composeArgs: _composeArgs(),
          filename: 'photo_$ts.jpg',
        ),
      );
      final cast = await FrameCloudCastService.instance.castPhoto(
        api: _api,
        paired: activePaired,
        jpegBytes: _previewBytes ?? compressed,
        filename: httpName,
        slideshowStyle: _slideshow.apiValue,
        displaySeconds: widget.displaySeconds,
        strings: s,
        userAuthToken: authToken,
        syncSlideshowAfterSuccess: false,
        editsJson: edits,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _appendCastLog(p);
            _status = _userFacingCastStatus(p, s);
            if (p.phase == CastPhase.success) {
              _castProgress = 1;
              _castProgressIndeterminate = false;
            } else if (p.isTerminal) {
              _castProgress = null;
              _castProgressIndeterminate = false;
            } else {
              _castProgress = p.showIndeterminate ? null : p.progress;
              _castProgressIndeterminate =
                  p.showIndeterminate || p.progress == null;
            }
          });
        },
      );
      if (!mounted) return;
      if (cast.ok) {
        // Multi-target fan-out: send the same edited photo to each extra frame,
        // isolated so one failure never rolls back the primary success.
        for (final extra in _extraTargets(activePaired)) {
          try {
            await FrameCloudCastService.instance.castPhoto(
              api: _api,
              paired: extra,
              jpegBytes: _previewBytes ?? compressed,
              filename: 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg',
              slideshowStyle: _slideshow.apiValue,
              displaySeconds: widget.displaySeconds,
              strings: s,
              userAuthToken: authToken,
              syncSlideshowAfterSuccess: false,
              editsJson: edits,
              onProgress: (_) {},
            );
          } catch (e) {
            AppDiagLog.verbose('[Editor] extra frame send failed: $e');
          }
        }
        await _finishSuccessfulSend(cast.message, sentJpeg: _previewBytes);
        return;
      }
      setState(() {
        _status = cast.message;
        _sendSucceeded = false;
      });
    } on FrameApiException catch (e) {
      if (!mounted) return;
      AppDiagLog.verbose('[Editor] FrameApiException: $e');
      setState(() => _status = (_strings?.sendFailedRetry ?? 'Image sending failed. Please try again. Make sure WiFi is connected to your frame, or delete the device and resend.'));
    } on SocketException catch (e) {
      if (!mounted) return;
      AppDiagLog.verbose('[Editor] SocketException: $e');
      setState(
        () => _status = (_strings?.sendFailedRetry ?? 'Image sending failed. Please try again. Make sure WiFi is connected to your frame, or delete the device and resend.'),
      );
    } on TimeoutException catch (e) {
      if (!mounted) return;
      AppDiagLog.verbose('[Editor] TimeoutException: $e');
      setState(() => _status = (_strings?.sendFailedRetry ?? 'Image sending failed. Please try again. Make sure WiFi is connected to your frame, or delete the device and resend.'));
    } catch (e) {
      if (mounted) {
        AppDiagLog.verbose('[Editor] send error: $e');
        setState(
          () => _status = (_strings?.sendFailedRetry ?? 'Image sending failed. Please try again. Make sure WiFi is connected to your frame, or delete the device and resend.'),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _castProgress = null;
          _castProgressIndeterminate = false;
          _sendCurrent = 0;
          _sendTotal = 0;
        });
      }
    }
  }

  Future<void> _exportForSdCard() async {
    if (_decoded == null) return;
    setState(() {
      _uploading = true;
      _status = null;
    });
    try {
      final s = AppStrings.of(context);
      final result = await _ensureProcessed();
      if (result == null) {
        if (!mounted) return;
        setState(() => _status = s.processingFailed);
        return;
      }
      final name = 'myframe_${DateTime.now().millisecondsSinceEpoch}.bin';
      final disposition = await shareBinForPhysicalSd(
        binBytes: result.binPayload,
        filename: name,
        saveDialogTitle: s.sdExportSaveDialogTitle,
      );
      if (!mounted) return;
      switch (disposition) {
        case SdBinExportDisposition.savedWithPicker:
          await UsageMetricsStore.instance.markSdDetectedNow();
          setState(() => _status = s.sdExportSavedHint);
          break;
        case SdBinExportDisposition.openedShareSheet:
          await UsageMetricsStore.instance.markSdDetectedNow();
          setState(() => _status = s.shareSheetSdHint);
          break;
        case SdBinExportDisposition.cancelled:
          setState(() => _status = s.sdExportCancelledHint);
          break;
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _status = AppDiagLog.userFacingStatus(
            '$e',
            fallback: _strings?.exportFailed ?? 'Export failed. Try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final cs = Theme.of(context).colorScheme;
    final primary = cs.primary;
    final debugOn = AppSettingsScope.of(context).debugModeEnabled;
    if (_decodeFailed) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          leading: IconButton(
            tooltip: s.backTooltip,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(
              Theme.of(context).platform == TargetPlatform.iOS ||
                      Theme.of(context).platform == TargetPlatform.macOS
                  ? CupertinoIcons.back
                  : Icons.arrow_back,
              size: 22,
            ),
          ),
          title: Text(s.editTitle),
          leadingWidth: 44,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.broken_image_outlined, size: 48, color: Color(0xFF9E9E9E)),
                const SizedBox(height: 16),
                Text(
                  s.decodeError,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  s.decodeErrorHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(s.backTooltip),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final keyboardOpen = viewInsets.bottom > 0;

    // return DebugSlogOverlay(
    //   child: PopScope(
    return PopScope(
        canPop: true,
        child: Scaffold(
          resizeToAvoidBottomInset: true,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          appBar: AppBar(
            centerTitle: true,
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            title: Text(
              _isPlaylist
                  ? '${s.editTitle} (${_playlistIndex + 1}/${_perStates?.length ?? 1})'
                  : widget.queueTotal > 1
                      ? '${s.editTitle} (${widget.queueIndex}/${widget.queueTotal})'
                      : s.editTitle,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Color(0xFF0A0A0A),
              ),
            ),
            automaticallyImplyLeading: false,
            leadingWidth: 44,
            leading: IconButton(
              tooltip: s.backTooltip,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              onPressed: () => Navigator.of(context).maybePop(),
              icon: Icon(
                Theme.of(context).platform == TargetPlatform.iOS ||
                        Theme.of(context).platform == TargetPlatform.macOS
                    ? CupertinoIcons.back
                    : Icons.arrow_back,
                size: 22,
                color: const Color(0xFF0A0A0A),
              ),
            ),
            actions: [
              if (debugOn &&
                  (_castLogLines.isNotEmpty ||
                      (_status?.trim().isNotEmpty ?? false)))
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  onPressed: _copyCastDiagnostics,
                  child: const Icon(CupertinoIcons.doc_on_doc, size: 22, color: Color(0xFF0A0A0A)),
                ),
              CupertinoButton(
                padding: const EdgeInsets.only(right: 12),
                onPressed: _decoded == null
                    ? null
                    : () {
                        setState(() {
                          _quarterTurns = (_quarterTurns + 1) % 4;
                          _invalidateProcessCache();
                        });
                      },
                child: const Icon(CupertinoIcons.refresh, size: 22, color: Color(0xFF0A0A0A)),
              ),
            ],
            bottom: DeviceStore.instance.pairedFrames.length > 1
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(56),
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      alignment: Alignment.centerLeft,
                      child: FrameTargetSelector(
                        frames: DeviceStore.instance.pairedFrames
                            .where((f) => f.canUploadToServer)
                            .toList(),
                        selectedIds: _targetIds.isEmpty
                            ? {
                                if (_paired?.deviceId != null) _paired!.deviceId,
                              }
                            : _targetIds,
                        onToggle: (id) {
                          setState(() {
                            final activeId = _paired?.deviceId;
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
                    ),
                  )
                : null,
          ),
          body: _decoded == null
              ? Center(child: Text(_status ?? s.noImage))
              : Column(
                  children: [

                    if (_isPlaylist && _perStates != null && _perStates!.length > 1)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              height: 160,
                              child: PageView.builder(
                                key: ValueKey('editor-playlist-${_perStates!.length}'),
                                controller: _pageController,
                                onPageChanged: _onPageChanged,
                                itemCount: _perStates!.length,
                                itemBuilder: (context, index) {
                                  return _buildPreviewStage(cs, keyboardOpen);
                                },
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: List.generate(_perStates!.length, (i) {
                                return Container(
                                  width: 6,
                                  height: 6,
                                  margin: const EdgeInsets.symmetric(horizontal: 3),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: i == _playlistIndex
                                        ? _kEditorRed
                                        : Colors.grey.shade300,
                                  ),
                                );
                              }),
                            ),
                          ],
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final screenH = MediaQuery.sizeOf(context).height;
                            final maxH = keyboardOpen
                                ? math.min(160.0, screenH * 0.20)
                                : screenH * 0.40;
                            final height = maxH.clamp(140.0, 400.0);
                            return Center(
                              child: SizedBox(
                                width: height * 3 / 4,
                                height: height,
                                child: _buildPreviewStage(cs, keyboardOpen),
                              ),
                            );
                          },
                        ),
                      ),
                    Expanded(
                      child: _buildToolSection(context, s, cs, primary, keyboardOpen),
                    ),
                    if (!keyboardOpen) _buildBottomBar(context, s, cs, primary, debugOn),
                  ],
                ),
        ),
      );
  }

  String _slideshowChoiceLabel(SlideshowStyle e, AppStrings s) {
    return switch (e) {
      SlideshowStyle.fade => s.styleFade,
      SlideshowStyle.kenBurns => s.styleKenBurns,
      SlideshowStyle.grid => s.styleGrid,
      SlideshowStyle.random => s.styleRandom,
    };
  }

  // ─── Tool tab state ──────────────────────────────────────────────
  String _activeTool = 'filters';
  bool _adjustmentsExpanded = false;
  bool _einkPreviewOn = true;
  final TransformationController _previewTransform = TransformationController();

  // ─── Crop state ───────────────────────────────────────────────────
  String _cropAspect = '3:4';
  double _cropZoom = 100;
  bool _flipH = false;
  bool _flipV = false;
  double _cropPanX = 0;
  double _cropPanY = 0;

  double get _cropAspectRatioValue {
    switch (_cropAspect) {
      case 'free':
      case '3:4':
        return 3 / 4;
      case '1:1':
        return 1;
      case '4:3':
        return 4 / 3;
      case '16:9':
        return 16 / 9;
      case '9:16':
        return 9 / 16;
      case 'original':
        final img = _decoded;
        if (img == null || img.height == 0) return 3 / 4;
        return img.width / img.height;
      default:
        return 3 / 4;
    }
  }

  FrameProcessOnlyArgs _previewArgs() {
    return FrameProcessOnlyArgs(
      imageBytes: _currentBytes,
      quarterTurns: _quarterTurns,
      brightness: 1.0 + (_brightness / 100) * 0.35,
      contrast: 1.0 + (_contrast / 100) * 0.45,
      saturation: 1.0 + (_saturation / 100) * 0.45,
      filterIndex: _filter.index,
      overlay: _currentOverlay,
      locationText: _overlayLocationValue,
      flipH: _flipH,
      flipV: _flipV,
      cropAspect: _cropAspectRatioValue,
      cropZoom: (_cropZoom / 100).clamp(1.0, 3.0),
      cropPanX: _cropPanX,
      cropPanY: _cropPanY,
    );
  }

  ComposeUploadIsolateArgs _composeArgs() {
    return ComposeUploadIsolateArgs(
      imageBytes: widget.imageBytes,
      quarterTurns: _quarterTurns,
      brightness: 1.0 + (_brightness / 100) * 0.35,
      contrast: 1.0 + (_contrast / 100) * 0.45,
      saturation: 1.0 + (_saturation / 100) * 0.45,
      filterIndex: _filter.index,
      overlay: _currentOverlay,
      locationText: _overlayLocationValue,
      flipH: _flipH,
      flipV: _flipV,
      cropAspect: _cropAspectRatioValue,
      cropZoom: (_cropZoom / 100).clamp(1.0, 3.0),
      cropPanX: _cropPanX,
      cropPanY: _cropPanY,
    );
  }

  ComposeUploadIsolateArgs _composeArgsForIndex(int index) {
    if (_perStates == null || index >= _perStates!.length) return _composeArgs();
    final s = _perStates![index];
    final ovr = SendOverlayOptions(
      showDate: s.oDate,
      showLocation: s.oLocation && !s.oWeather,
      showGreeting: s.oGreeting,
      showWeather: s.oWeather,
      customText: '',
      greetingCustom: widget.overlay.greetingCustom,
      centerText: s.overlayText,
      centerTextColor: const [0xFF000000, 0xFFFFFFFF, 0xFFFFFF00, 0xFFFF0000, 0xFF0000FF, 0xFF00FF00][s.textColor.clamp(0, 5)],
      centerTextSize: s.textSize,
      centerSticker: s.selectedSticker ?? '',
      stickerAlignX: (s.stickerAlignX + 1) / 2,
      stickerAlignY: (s.stickerAlignY + 1) / 2,
      stickerSize: s.stickerSize,
      weatherText: s.weatherLine,
      borderStyle: s.borderStyle,
    );
    final paired = _paired;
    final locationTxt = paired?.frameName?.trim() ?? _strings?.frameDefaultDisplayName ?? '';
    return ComposeUploadIsolateArgs(
      imageBytes: s.originalBytes,
      quarterTurns: s.quarterTurns,
      brightness: 1.0 + (s.brightness / 100) * 0.35,
      contrast: 1.0 + (s.contrast / 100) * 0.45,
      saturation: 1.0 + (s.saturation / 100) * 0.45,
      filterIndex: s.filter.index,
      overlay: ovr,
      locationText: locationTxt,
      flipH: s.flipH,
      flipV: s.flipV,
      cropAspect: _cropAspectRatioValue,
      cropZoom: (s.cropZoom / 100).clamp(1.0, 3.0),
      cropPanX: s.cropPanX,
      cropPanY: s.cropPanY,
    );
  }

  // ─── Text state ───────────────────────────────────────────────────
  final _textController = TextEditingController();
  double _textSize = 24;
  int _textColor = 1; // white
  bool _textBold = false;
  double _textRotation = 0;

  // ─── Weather state ────────────────────────────────────────────────
  bool _oWeather = false;
  final _weatherTempController = TextEditingController();

  // ─── Sticker state ────────────────────────────────────────────────
  String? _selectedSticker;
  double _stickerRotation = 0;
  double _stickerAlignX = 0.35; // slightly right of center (-1..1)
  double _stickerAlignY = -0.15;
  double _stickerSize = 28;

  // ─── Drag performance state ───────────────────────────────────────
  bool _isDragging = false;
  bool _touchMovePending = false;

  // ─── Border state ─────────────────────────────────────────────────
  String _borderStyle = 'none';

  String _filterLabel(FrameImageFilter f, AppStrings s) {
    return switch (f) {
      FrameImageFilter.none => s.filterOriginal,
      FrameImageFilter.grayscale => s.filterGrayscale,
      FrameImageFilter.sepia => s.filterSepia,
      FrameImageFilter.warm => s.filterWarm,
      FrameImageFilter.cool => s.filterCool,
      FrameImageFilter.contrast => s.contrastLabel,
      FrameImageFilter.vivid => s.vividLabel,
      FrameImageFilter.vintage => s.vintageLabel,
    };
  }

  List<ColorFilter?> get _filterPreviewMatrices => [
        null, // none
        const ColorFilter.matrix(<double>[
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        const ColorFilter.matrix(<double>[
          0.393, 0.769, 0.189, 0, 0,
          0.349, 0.686, 0.168, 0, 0,
          0.272, 0.534, 0.131, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        const ColorFilter.matrix(<double>[
          1.1, 0.05, 0, 0, 8,
          0.05, 1.05, 0, 0, 4,
          0, 0, 0.9, 0, -6,
          0, 0, 0, 1, 0,
        ]),
        const ColorFilter.matrix(<double>[
          0.9, 0, 0.05, 0, -6,
          0, 1.02, 0.05, 0, 2,
          0.05, 0.05, 1.15, 0, 10,
          0, 0, 0, 1, 0,
        ]),
        const ColorFilter.matrix(<double>[
          1.25, 0, 0, 0, -20,
          0, 1.25, 0, 0, -20,
          0, 0, 1.25, 0, -20,
          0, 0, 0, 1, 0,
        ]),
        const ColorFilter.matrix(<double>[
          1.15, -0.05, -0.05, 0, 0,
          -0.05, 1.2, -0.05, 0, 0,
          -0.05, -0.05, 1.25, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        const ColorFilter.matrix(<double>[
          0.5, 0.4, 0.1, 0, 10,
          0.3, 0.5, 0.1, 0, 5,
          0.2, 0.3, 0.3, 0, 0,
          0, 0, 0, 1, 0,
        ]),
      ];

  Widget _editorSectionTitle(String title, ColorScheme cs) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 18,
          decoration: BoxDecoration(
            color: cs.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              color: cs.onSurface,
            ),
          ),
        ),
      ],
    );
  }

  void _clearEditorOverlays() {
    setState(() {
      _oDate = false;
      _oLocation = false;
      _oGreeting = false;
      _oWeather = false;
      _overlayText.clear();
      _textController.clear();
      _selectedSticker = null;
      _borderStyle = 'none';
      _invalidateProcessCache();
    });
  }

  void _clearText() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _overlayText.clear();
      _textController.clear();
      _invalidateProcessCache();
    });
  }

  void _clearStickers() {
    setState(() {
      _selectedSticker = null;
      _invalidateProcessCache();
    });
  }

  BoxDecoration _previewDecoration(ColorScheme cs) {
    switch (_borderStyle) {
      case 'thinBlack':
        return BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.black, width: 2),
        );
      case 'thickWhite':
        return BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white, width: 10),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
        );
      case 'polaroid':
        return BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(4),
          border: const Border(
            top: BorderSide(color: Colors.white, width: 10),
            left: BorderSide(color: Colors.white, width: 10),
            right: BorderSide(color: Colors.white, width: 10),
            bottom: BorderSide(color: Colors.white, width: 28),
          ),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10)],
        );
      case 'film':
        return BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.black, width: 12),
        );
      case 'rounded':
        return BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: cs.outlineVariant),
        );
      case 'double':
        return BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.black87, width: 4),
          boxShadow: const [
            BoxShadow(color: Colors.white, spreadRadius: 3),
            BoxShadow(color: Colors.black26, blurRadius: 6),
          ],
        );
      default:
        return BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.outlineVariant),
    );
  }
}

  Widget _safeMemoryImage(
    Uint8List bytes, {
    BoxFit fit = BoxFit.cover,
    double? width,
    double? height,
    FilterQuality filterQuality = FilterQuality.low,
  }) {
    if (bytes.isEmpty) {
      return ColoredBox(
        color: const Color(0xFFF3F4F6),
        child: Center(
          child: Text(
            AppStrings.of(context).decodeError,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13),
          ),
        ),
      );
    }
    return Image.memory(
      bytes,
      fit: fit,
      width: width,
      height: height,
      gaplessPlayback: true,
      filterQuality: filterQuality,
      errorBuilder: (_, __, ___) => ColoredBox(
        color: const Color(0xFFF3F4F6),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              AppStrings.of(context).decodeError,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }

  Widget _filteredImage() {
    // During drag: skip all pixel-level filter/grade — just raw image for 60fps.
    if (_isDragging) {
      return _safeMemoryImage(
        _currentBytes,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
      );
    }
    final idx = _filter.index.clamp(0, _filterPreviewMatrices.length - 1);
    final matrix = _filterPreviewMatrices[idx];
    final b = 1.0 + (_brightness / 100) * 0.35;
    final c = 1.0 + (_contrast / 100) * 0.45;
    final t = (1.0 - c) * 128.0;
    final grade = ColorFilter.matrix(<double>[
      c, 0, 0, 0, t + (b - 1) * 40,
      0, c, 0, 0, t + (b - 1) * 40,
      0, 0, c, 0, t + (b - 1) * 40,
      0, 0, 0, 1, 0,
    ]);
    Widget img = _safeMemoryImage(
      _currentBytes,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
    );
    img = ColorFiltered(colorFilter: grade, child: img);
    if (matrix != null) {
      img = ColorFiltered(colorFilter: matrix, child: img);
    }
    return img;
  }

  Widget _buildLiveOverlayStack() {
    const palette = [
      Colors.black,
      Colors.white,
      Colors.yellow,
      Colors.red,
      Colors.blue,
      Colors.green,
    ];
    final textColor = (_textColor >= 0 && _textColor < palette.length)
        ? palette[_textColor]
        : Colors.white;
    final now = DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        // Match baked arial24 on ~800px frame work image (~3% of width).
        final barFont = (w * 0.032).clamp(9.0, 13.0);
        final stickerPx = (w * 0.085 * (_stickerSize / 28)).clamp(14.0, 48.0);
        final barLines = <Widget>[];
        if (_oWeather && _weatherLine.trim().isNotEmpty) {
          barLines.add(
            Text(
              _weatherLine,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: barFont,
                height: 1.15,
              ),
            ),
          );
        }
        if (_oDate) {
          barLines.add(
            Text(
              dateStr,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: barFont,
                height: 1.15,
              ),
            ),
          );
        }
        final draft = _overlayText.text.trim();
        if (draft.isNotEmpty) {
          // Bar text matches E-ink bake (fixed arial24) — ignore large UI size slider.
          barLines.add(
            Text(
              draft,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: textColor,
                fontWeight: _textBold ? FontWeight.w800 : FontWeight.w600,
                fontSize: barFont,
                height: 1.15,
              ),
            ),
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            if (_selectedSticker != null)
              Align(
                alignment: Alignment(_stickerAlignX, _stickerAlignY),
                child: Transform.rotate(
                  angle: _stickerRotation * math.pi / 180,
                  child: _selectedSticker == '♥'
                      ? Icon(
                          Icons.favorite,
                          color: const Color(0xFFE5252A),
                          size: stickerPx,
                        )
                      : Text(
                          _selectedSticker!,
                          style: TextStyle(fontSize: stickerPx, height: 1),
                        ),
                ),
              ),
            if (barLines.isNotEmpty)
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: double.infinity,
                  color: Colors.black.withValues(alpha: 120 / 255),
                  padding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: (w * 0.025).clamp(6.0, 12.0),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < barLines.length; i++)
                        Padding(
                          padding: EdgeInsets.only(top: i == 0 ? 0 : 2),
                          child: barLines[i],
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildPreviewStage(ColorScheme cs, bool keyboardOpen) {
    final zoom = (_cropZoom / 100).clamp(1.0, 3.0);
    final aspect = _cropAspectRatioValue;
    return Container(
      decoration: _previewDecoration(cs),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.white),
          Center(
            child: AspectRatio(
              aspectRatio: aspect,
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    GestureDetector(
                      onPanStart: keyboardOpen
                          ? null
                          : (_) => setState(() => _isDragging = true),
                      onPanEnd: keyboardOpen
                          ? null
                          : (_) {
                              setState(() => _isDragging = false);
                              _invalidateProcessCache();
                            },
                      onPanUpdate: keyboardOpen
                          ? null
                          : (d) {
                              if (_touchMovePending) return;
                              _touchMovePending = true;
                              Future.delayed(const Duration(milliseconds: 16), () {
                                _touchMovePending = false;
                              });
                              if (_activeTool == 'crop') {
                                setState(() {
                                  _cropPanX = (_cropPanX + d.delta.dx / 90).clamp(-1.0, 1.0);
                                  _cropPanY = (_cropPanY + d.delta.dy / 90).clamp(-1.0, 1.0);
                                });
                              } else if (_activeTool == 'stickers' && _selectedSticker != null) {
                                setState(() {
                                  _stickerAlignX = (_stickerAlignX + d.delta.dx / 120).clamp(-0.85, 0.85);
                                  _stickerAlignY = (_stickerAlignY + d.delta.dy / 120).clamp(-0.85, 0.85);
                                });
                              }
                            },
                      child: RepaintBoundary(
                        child: Transform(
                        alignment: Alignment.center,
                        transform: () {
                          final m = Matrix4.identity();
                          m.translateByDouble(_cropPanX * 40.0, _cropPanY * 40.0, 0, 1);
                          m.rotateZ(_quarterTurns * math.pi / 2);
                          m.scaleByDouble(
                            _flipH ? -zoom : zoom,
                            _flipV ? -zoom : zoom,
                            1,
                            1,
                          );
                          return m;
                        }(),
                        child: _filteredImage(),
                        ),
                      ),
                    ),
                    if (_isDragging)
                      Positioned.fill(
                        child: ColoredBox(color: Colors.black.withValues(alpha: 0.35)),
                      ),
                    // On the photo bounds so weather/date/text match E-ink Preview.
                    IgnorePointer(child: _buildLiveOverlayStack()),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _adjustmentSlider({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
            Text('${value.toInt()}'),
          ],
        ),
        Slider(
          min: -100,
          max: 100,
          value: value.clamp(-100.0, 100.0),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildToolSection(
    BuildContext context,
    AppStrings s,
    ColorScheme cs,
    Color primary,
    bool keyboardOpen,
  ) {
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _toolTab(s.filterLabel, 'filters', Icons.filter, cs),
              _toolTab(s.dateLabel, 'date', Icons.date_range, cs),
              _toolTab(s.textLabel, 'text', Icons.text_fields, cs),
              _toolTab(s.borderLabel, 'border', Icons.border_style, cs),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _buildActiveToolPanel(s, cs, primary),
          ),
        ),
      ],
    );
  }

  Widget _toolTab(String label, String tool, IconData icon, ColorScheme cs) {
    final active = _activeTool == tool;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: () => setState(() => _activeTool = tool),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: active ? _kEditorRed : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: active ? Colors.white : const Color(0xFF4B5563)),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: active ? Colors.white : const Color(0xFF111827),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveToolPanel(AppStrings s, ColorScheme cs, Color primary) {
    switch (_activeTool) {
      case 'date':
        return _buildDatePanel(s, cs);
      case 'text':
        return _buildTextPanel(s, cs, primary);
      case 'border':
        return _buildBorderPanel(s, cs);
      default:
        return _buildFilterPanel(s, cs, primary);
    }
  }

  Widget _buildFilterPanel(AppStrings s, ColorScheme cs, Color primary) {
    const presetFilters = [
      FrameImageFilter.none,
      FrameImageFilter.contrast,
      FrameImageFilter.cool,
      FrameImageFilter.vivid,
      FrameImageFilter.grayscale,
    ];
    final presetLabels = [s.originalLabel, s.contrastLabel, s.coolLabel, s.vividLabel, s.bwLabel];
    final matrices = _filterPreviewMatrices;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 108,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: presetFilters.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final f = presetFilters[index];
              final sel = _filter == f;
              final matrix = matrices[f.index];
              Widget thumb = _safeMemoryImage(
                _currentBytes,
                fit: BoxFit.cover,
              );
              if (matrix != null) {
                thumb = ColorFiltered(colorFilter: matrix, child: thumb);
              }
              return GestureDetector(
                onTap: () {
                  setState(() {
                    _filter = f;
                    _invalidateProcessCache();
                  });
                },
                child: SizedBox(
                  width: 76,
                  child: Column(
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: sel ? _kEditorRed : cs.outlineVariant,
                              width: sel ? 2.5 : 1,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: thumb,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        presetLabels[index],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: sel ? _kEditorRed : cs.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        InkWell(
          onTap: () => setState(() => _adjustmentsExpanded = !_adjustmentsExpanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Text(
                  s.adjustmentsLabel,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: cs.onSurface,
                  ),
                ),
                const Spacer(),
                Icon(
                  _adjustmentsExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  size: 20,
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (_adjustmentsExpanded) ...[
          const SizedBox(height: 4),
          _adjustmentSlider(
            label: s.brightnessLabel,
            value: _brightness,
            onChanged: (v) {
              setState(() {
                _brightness = v;
                _invalidateProcessCache();
              });
            },
          ),
          _adjustmentSlider(
            label: s.contrastLabel,
            value: _contrast,
            onChanged: (v) {
              setState(() {
                _contrast = v;
                _invalidateProcessCache();
              });
            },
          ),
          _adjustmentSlider(
            label: s.saturationLabel,
            value: _saturation,
            onChanged: (v) {
              setState(() {
                _saturation = v;
                _invalidateProcessCache();
              });
            },
          ),
        ],
      ],
    );
  }

  Widget _buildCropPanel(AppStrings s, ColorScheme cs, Color primary) {
    final aspects = [
      (key: 'free', label: s.cropFree),
      (key: 'original', label: s.cropOriginal),
      (key: '1:1', label: '1:1'),
      (key: '3:4', label: '3:4'),
      (key: '4:3', label: '4:3'),
      (key: '16:9', label: '16:9'),
      (key: '9:16', label: '9:16'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: aspects.map((a) {
              final key = a.key;
              final sel = _cropAspect == key;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Material(
                  color: sel ? _kEditorRed : const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      setState(() {
                        _cropAspect = key;
                        _cropPanX = 0;
                        _cropPanY = 0;
                        _invalidateProcessCache();
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Text(
                        a.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: sel ? Colors.white : const Color(0xFF111827),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _iconAction(Icons.rotate_left, s.cropLeft90, () {
                setState(() {
                  _quarterTurns = (_quarterTurns + 3) % 4;
                  _invalidateProcessCache();
                });
              }),
              _iconAction(Icons.rotate_right, s.cropRight90, () {
                setState(() {
                  _quarterTurns = (_quarterTurns + 1) % 4;
                  _invalidateProcessCache();
                });
              }),
              _iconAction(Icons.flip, s.cropFlipH, () {
                setState(() {
                  _flipH = !_flipH;
                  _invalidateProcessCache();
                });
              }),
              _iconAction(Icons.swap_vert, s.cropFlipV, () {
                setState(() {
                  _flipV = !_flipV;
                  _invalidateProcessCache();
                });
              }),
              _iconAction(Icons.restart_alt, s.cropReset, _resetCropState),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(s.zoomLabel, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            Expanded(
              child: Slider(
                value: _cropZoom,
                min: 100,
                max: 300,
                activeColor: _kEditorRed,
                onChanged: (v) {
                  setState(() => _cropZoom = v);
                  _invalidateProcessCache();
                },
                onChangeEnd: (_) => _invalidateProcessCache(),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                '${_cropZoom.toInt()}%',
                textAlign: TextAlign.end,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
        Text(
          s.cropDragHint,
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildWeatherPanel(AppStrings s, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          value: _oWeather,
          onChanged: (v) => _onWeatherToggled(v),
          title: Text(s.showWeatherLabel),
          contentPadding: EdgeInsets.zero,
          dense: true,
          activeTrackColor: _kEditorRed,
        ),
        if (_weatherLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(minHeight: 2, color: _kEditorRed),
          ),
        if (_weatherLine.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _weatherLine,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
        TextFormField(
          controller: _weatherTempController,
          decoration: InputDecoration(
            labelText: s.weatherOverrideTemp,
            isDense: true,
          ),
          keyboardType: TextInputType.number,
          onChanged: (v) {
            if (!_oWeather) return;
            final t = v.trim();
            if (t.isNotEmpty) {
              setState(() {
                _weatherLine = '☀ $t°C';
                _invalidateProcessCache();
              });
            } else {
              unawaited(_loadRealWeather());
            }
          },
        ),
        const SizedBox(height: 6),
        Text(
          s.weatherPermissionHint,
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  Future<void> _onWeatherToggled(bool enabled) async {
    final s = AppStrings.of(context);
    if (!enabled) {
      setState(() {
        _oWeather = false;
        _weatherLoading = false;
        _invalidateProcessCache();
      });
      return;
    }

    setState(() {
      _oWeather = true;
      _weatherLoading = true;
    });

    final ok = await WeatherService.instance.ensureLocationPermission();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _oWeather = false;
        _weatherLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(s.locationPermissionNeeded),
        ),
      );
      return;
    }

    await _loadRealWeather();
  }

  Future<void> _loadRealWeather() async {
    final s = AppStrings.of(context);
    setState(() => _weatherLoading = true);
    final snap = await WeatherService.instance.fetchCurrent(force: true);
    if (!mounted) return;
    if (snap == null) {
      setState(() {
        _weatherLoading = false;
        _weatherLine = _weatherTempController.text.trim().isEmpty
            ? '☀ --°C'
            : '☀ ${_weatherTempController.text.trim()}°C';
        _invalidateProcessCache();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(s.weatherLoadFailed),
        ),
      );
      return;
    }
    setState(() {
      _weatherLoading = false;
      _weatherLine = snap.line;
      _weatherTempController.text = '${snap.tempC}';
      _invalidateProcessCache();
    });
  }

  Widget _buildDatePanel(AppStrings s, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          value: _oDate,
          onChanged: (v) {
            setState(() {
              _oDate = v;
              _invalidateProcessCache();
            });
          },
          title: Text(s.dateLabel),
          contentPadding: EdgeInsets.zero,
          dense: true,
          activeTrackColor: _kEditorRed,
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Text(
            s.dateHelperText,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _buildTextPanel(AppStrings s, ColorScheme cs, Color primary) {
    const palette = [
      Colors.black,
      Colors.white,
      Colors.yellow,
      Colors.red,
      Colors.blue,
      Colors.green,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                maxLength: 240,
                minLines: 1,
                maxLines: 3,
                style: const TextStyle(fontSize: 15),
                decoration: InputDecoration(
                  hintText: s.happyBirthdayHint,
                  isDense: true,
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _kEditorRed,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              onPressed: () {
                final draft = _textController.text.trim();
                if (draft.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      behavior: SnackBarBehavior.floating,
                      content: Text(s.typeSomethingFirst),
                    ),
                  );
                  return;
                }
                FocusManager.instance.primaryFocus?.unfocus();
                setState(() {
                  _overlayText.text = draft;
                  _textController.text = draft;
                  _invalidateProcessCache();
                });
              },
              child: Text(s.addText, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
        Row(
          children: [
            Text('${_textSize.toInt()}px', style: const TextStyle(fontSize: 12)),
            Expanded(
              child: Slider(
                value: _textSize,
                min: 12,
                max: 120,
                activeColor: _kEditorRed,
                onChanged: (v) {
                  setState(() => _textSize = v);
                  _invalidateProcessCache();
                },
                onChangeEnd: (_) => _invalidateProcessCache(),
              ),
            ),
          ],
        ),
        Row(
          children: [
            ...List.generate(6, (i) {
              return GestureDetector(
                onTap: () {
                  setState(() => _textColor = i);
                  _invalidateProcessCache();
                },
                child: Container(
                  width: 28,
                  height: 28,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: palette[i],
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _textColor == i ? _kEditorRed : const Color(0xFFDADDE5),
                      width: _textColor == i ? 2.5 : 1,
                    ),
                  ),
                ),
              );
            }),
            const Spacer(),
            GestureDetector(
              onTap: _clearText,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  s.clearAction,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: _kEditorRed,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStickerPanel(AppStrings s, ColorScheme cs) {
    const stickers = ['♥', '★', '→', '◖', '●', '▲', '✚', '☀'];
    final labels = [s.stickerHeart, s.stickerStar, s.stickerArrow, s.stickerBubble, s.stickerCircle, s.stickerTriangle, s.stickerHoliday, s.stickerSun];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(8, (i) {
            final selected = _selectedSticker == stickers[i];
            return GestureDetector(
              onTap: () {
                setState(() {
                  _selectedSticker = stickers[i];
                  // Default slightly right of center.
                  if (_stickerAlignX.abs() < 0.05 && _stickerAlignY.abs() < 0.05) {
                    _stickerAlignX = 0.35;
                    _stickerAlignY = -0.15;
                  }
                  _invalidateProcessCache();
                });
              },
              child: Container(
                width: 72,
                height: 56,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: selected ? Border.all(color: _kEditorRed, width: 2) : null,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    stickers[i] == '♥'
                        ? const Icon(Icons.favorite, color: Color(0xFFE5252A), size: 22)
                        : Text(stickers[i], style: const TextStyle(fontSize: 20)),
                    Text(labels[i], style: const TextStyle(fontSize: 9)),
                  ],
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(s.sizeLabel, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            Expanded(
              child: Slider(
                value: _stickerSize,
                min: 16,
                max: 64,
                activeColor: _kEditorRed,
                onChanged: (v) {
                  setState(() => _stickerSize = v);
                  _invalidateProcessCache();
                },
              ),
            ),
          ],
        ),
        Row(
          children: [
            GestureDetector(
              onTap: _clearStickers,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  s.borderNone,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: _kEditorRed,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _iconAction(Icons.rotate_left, '', () {
              setState(() => _stickerRotation -= 15);
              _invalidateProcessCache();
            }),
            _iconAction(Icons.rotate_right, '', () {
              setState(() => _stickerRotation += 15);
              _invalidateProcessCache();
            }),
            _iconAction(Icons.restart_alt, s.cropReset, () {
              setState(() {
                _stickerAlignX = 0.35;
                _stickerAlignY = -0.15;
                _stickerRotation = 0;
                _stickerSize = 28;
                _invalidateProcessCache();
              });
            }),
          ],
        ),
        Text(
          s.stickerDragHint,
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildBorderPanel(AppStrings s, ColorScheme cs) {
    final borders = [s.borderNone, s.borderThinBlack, s.borderThickWhite, s.borderPolaroid, s.borderFilmStrip, s.borderRounded, s.borderDouble];
    const keys = ['none', 'thinBlack', 'thickWhite', 'polaroid', 'film', 'rounded', 'double'];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(7, (i) {
        final selected = _borderStyle == keys[i];
        return GestureDetector(
          onTap: () => setState(() {
            _borderStyle = keys[i];
            _invalidateProcessCache();
          }),
          child: Container(
            width: 88,
            height: 44,
            decoration: BoxDecoration(
              color: selected ? _kEditorRed : cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                borders[i],
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : cs.onSurface,
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _iconAction(IconData icon, String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              if (label.isNotEmpty) ...[
                const SizedBox(width: 2),
                Text(label, style: const TextStyle(fontSize: 11)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Show six-color e-ink preview in a fullscreen dialog.
  Future<void> _preview() async {
    if (_decoded == null) return;
    final bytes = await compute(isolateFrameEinkPreviewJpeg, _previewArgs());
    if (!mounted || bytes == null) return;
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black87,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => SizedBox(
                    height: 180,
                    child: Center(child: Text(_strings?.decodeError ?? 'Could not decode image')),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, bottom: 12),
              child: Text(
                _strings?.previewHint ?? 'Preview uses black, white, yellow, red, blue, and green only.',
                style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                textAlign: TextAlign.center,
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(_strings?.closeLabel ?? 'Close', style: const TextStyle(color: Colors.white)),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _resetCropState() {
    setState(() {
      _cropAspect = '3:4';
      _cropZoom = 100;
      _flipH = false;
      _flipV = false;
      _cropPanX = 0;
      _cropPanY = 0;
      _quarterTurns = 0;
      _previewTransform.value = Matrix4.identity();
      _invalidateProcessCache();
    });
  }

  Widget _buildBottomBar(
    BuildContext context,
    AppStrings s,
    ColorScheme cs,
    Color primary,
    bool debugOn,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_uploading) ...[
                if (_castProgressIndeterminate || _castProgress != null)
                  LinearProgressIndicator(
                    value: _castProgressIndeterminate ? null : _castProgress,
                    minHeight: 3,
                    color: _kEditorRed,
                  ),
                if (_status != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 6),
                    child: Text(
                      _status!,
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ] else if (_paired != null && !_paired!.canUploadToServer)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    s.pairingNeedsApiUrl,
                    style: TextStyle(fontSize: 11, color: cs.error),
                  ),
                )
              else if (_frameOnline == false)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    s.frameOfflineLabel,
                    style: TextStyle(fontSize: 11, color: cs.error),
                  ),
                ),
              if (_isPlaylist && !_uploading) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 4,
                    children: [
                      Text(s.intervalPrefix, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                      ...[2, 5, 10, 30, 60].map((m) {
                        final sel = _playlistIntervalMinutes == m;
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: ChoiceChip(
                            label: Text(
                              m < 60 ? '${m}m' : '1h',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: sel ? Colors.white : cs.onSurface,
                              ),
                            ),
                            selected: sel,
                            selectedColor: _kEditorRed,
                            visualDensity: VisualDensity.compact,
                            onSelected: (v) {
                              if (v) setState(() => _playlistIntervalMinutes = m);
                            },
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ],
              Row(
                children: [
                  Expanded(
                    flex: 5,
                    child: SizedBox(
                      height: 54,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _kEditorRed,
                          side: const BorderSide(color: _kEditorRed),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: _uploading ? null : _showFastRealPreview,
                        child: Text(
                          s.einkPreviewLabel,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 6,
                    child: ProgressActionButton(
                      height: 54,
                      borderRadius: BorderRadius.circular(14),
                      backgroundColor: _kEditorRed,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor:
                          _kEditorRed.withValues(alpha: 0.55),
                      label: _isPlaylist
                          ? s.sendPlaylistLabel(_perStates?.length ?? 0)
                          : s.sendLabel,
                      isLoading: _uploading,
                      statusMessage: (_uploading && _sendTotal > 1)
                          ? s.progressSendingPhotos
                          : (_status?.trim().isNotEmpty == true
                              ? _status!
                                  .replaceAll(RegExp(r'[.…]+$'), '')
                                  .trim()
                              : s.progressSendingPhotos),
                      currentStep: (_uploading &&
                              _sendTotal > 1 &&
                              _sendCurrent > 0)
                          ? _sendCurrent
                          : null,
                      totalSteps:
                          (_uploading && _sendTotal > 1) ? _sendTotal : null,
                      progress: _uploading
                          ? (_castProgressIndeterminate
                              ? null
                              : (_castProgress ??
                                  (_sendTotal > 0 && _sendCurrent > 0
                                      ? (_sendCurrent / _sendTotal)
                                          .clamp(0.05, 1.0)
                                      : null)))
                          : null,
                      onPressed: (_uploading || _frameOnline == false)
                          ? null
                          : () {
                              HapticFeedback.lightImpact();
                              if (!mounted) return;
                              setState(() => _uploading = true);
                              unawaited(_send());
                            },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens immediately (uses warm cache when ready); refreshes bake in background.
  void _showFastRealPreview() {
    final args = _previewArgs();
    final cached = _previewBytes;
    showDialog<void>(
      context: context,
      builder: (ctx) => _FastEinkPreviewDialog(
        initialBytes: cached,
        fallbackBytes: widget.imageBytes,
        load: () => compute(isolateFastPreviewJpeg, args),
      ),
    );
  }
}

class _AnimatedCheckmark extends StatefulWidget {
  final double size;
  final Color color;
  const _AnimatedCheckmark({required this.size, this.color = _kEditorRed});

  @override
  State<_AnimatedCheckmark> createState() => _AnimatedCheckmarkState();
}

class _AnimatedCheckmarkState extends State<_AnimatedCheckmark>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scaleAnim;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _scaleAnim = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0, 0.5, curve: Curves.elasticOut),
    );
    _pulseAnim = Tween<double>(begin: 1, end: 1.08).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.6, 1.0, curve: Curves.easeInOut),
      ),
    );
    _ctrl.repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final scale = _ctrl.value < 0.5
            ? _scaleAnim.value
            : _pulseAnim.value;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              gradient: SweepGradient(
                colors: [
                  widget.color,
                  widget.color.withValues(alpha: 0.85),
                  widget.color.withValues(alpha: 0.7),
                  widget.color,
                ],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.35),
                  blurRadius: widget.size * 0.3,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(
              Icons.check_rounded,
              color: Colors.white,
              size: widget.size * 0.55,
            ),
          ),
        );
      },
    );
  }
}

/// Brand-red frosted "Pushing to Frame" confirmation. Compact (~56px animated
/// red check), soft neutral glass, an animated status line, a "View in Gallery"
/// primary action, and auto-dismiss after ~1.5s. Dismissing hands off to the
/// editor which routes to the Gallery tab.
class _PushingBackgroundDialog extends StatefulWidget {
  const _PushingBackgroundDialog({
    required this.frameName,
    required this.strings,
  });

  final String frameName;
  final AppStrings? strings;

  @override
  State<_PushingBackgroundDialog> createState() => _PushingBackgroundDialogState();
}

class _PushingBackgroundDialogState extends State<_PushingBackgroundDialog> {
  Timer? _autoDismiss;

  @override
  void initState() {
    super.initState();
    _autoDismiss = Timer(const Duration(milliseconds: 1500), _dismiss);
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    super.dispose();
  }

  void _dismiss() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings ?? AppStrings.current;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopScope(
      canPop: false,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(
                width: 300,
                padding: const EdgeInsets.fromLTRB(24, 26, 24, 20),
                decoration: BoxDecoration(
                  color: (isDark ? cs.surface : Colors.white)
                      .withValues(alpha: isDark ? 0.78 : 0.92),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: cs.outlineVariant.withValues(alpha: 0.4),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.12),
                      blurRadius: 32,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _AnimatedCheckmark(size: 56, color: AppTheme.primaryRed),
                    const SizedBox(height: 14),
                    Text(
                      s.pushingToFrameTitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      s.pushInBackgroundSubtitle(widget.frameName),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: _dismiss,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primaryRed,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      icon: const Icon(Icons.photo_library_outlined, size: 20),
                      label: Text(
                        s.viewInGalleryLabel,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FastEinkPreviewDialog extends StatefulWidget {
  const _FastEinkPreviewDialog({
    required this.initialBytes,
    required this.fallbackBytes,
    required this.load,
  });

  final Uint8List? initialBytes;
  final Uint8List fallbackBytes;
  final Future<Uint8List?> Function() load;

  @override
  State<_FastEinkPreviewDialog> createState() => _FastEinkPreviewDialogState();
}

class _FastEinkPreviewDialogState extends State<_FastEinkPreviewDialog> {
  Uint8List? _bytes;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _bytes = widget.initialBytes;
    if (_bytes == null) {
      _loading = true;
    }
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final next = await widget.load();
    if (!mounted) return;
    if (next == null) {
      setState(() {
        _bytes ??= widget.fallbackBytes;
        _loading = false;
      });
      return;
    }
    setState(() {
      _bytes = next;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _bytes != null
                    ? Image.memory(
                        _bytes!,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => SizedBox(
                          height: 180,
                          child: Center(child: Text(s.decodeError)),
                        ),
                      )
                    : const SizedBox(
                        height: 220,
                        child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
                      ),
              ),
            ),
            if (_loading && _bytes != null)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                s.previewOfEditedPhoto,
                style: const TextStyle(fontSize: 12, color: Colors.black54),
                textAlign: TextAlign.center,
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(s.closeLabel),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _CastActivityLog extends StatelessWidget {
  const _CastActivityLog({required this.lines, required this.onCopy});

  final List<String> lines;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mono = TextStyle(
      fontSize: 10,
      fontFamily: 'monospace',
      color: cs.onSurface,
      height: 1.35,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Cast activity',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Copy log',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: onCopy,
                icon: Icon(Icons.copy_outlined, size: 18, color: cs.primary),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(lines.join('\n'), style: mono),
        ],
      ),
    );
  }
}

/// Cast targets (device_id / API) — shown while uploading for troubleshooting.
class _CastDebugTargetsPanel extends StatelessWidget {
  const _CastDebugTargetsPanel({required this.paired});

  final PairedFrame paired;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final uploadId = FrameCloudCastService.instance.uploadDeviceId(paired);
    final lines = <String>[
      'Paired deviceId (stored): ${paired.deviceId}',
      'bleRemoteId: ${paired.bleRemoteId ?? '—'}',
      'Upload device_id (same as Android): $uploadId',
      'API base URL: ${paired.resolvedApiBaseUrl ?? '—'}',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Frame cast',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          for (final line in lines)
            Text(
              line,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: cs.onSurface,
                height: 1.35,
              ),
            ),
        ],
      ),
    );
  }
}
