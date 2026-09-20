import 'dart:async';

import 'package:flutter/foundation.dart';

import '../l10n/app_strings.dart';
import 'app_diag_log.dart';
import 'auth_session_manager.dart';
import 'frame_api_client.dart';
import 'notification_service.dart';

/// Live state of a single async image-push job, mirrored from the server's
/// push queue.
enum PushJobStage {
  queued,
  uploading,
  downloading,
  refreshing,
  completed,
  failed,
}

/// A push reported by [UploadQueueController]. [progress] is 0..1.
class PushJobView {
  const PushJobView({
    required this.stage,
    required this.progress,
    required this.msgid,
    this.status,
    this.label,
  });

  final PushJobStage stage;
  final double progress;
  final String msgid;
  final String? status;
  final String? label;

  /// Banner label for the current stage (client-localized by the widget).
  String get stageKey {
    switch (stage) {
      case PushJobStage.queued:
        return 'queued';
      case PushJobStage.uploading:
        return 'uploading';
      case PushJobStage.downloading:
        return 'downloading';
      case PushJobStage.refreshing:
        return 'refreshing';
      case PushJobStage.completed:
        return 'completed';
      case PushJobStage.failed:
        return 'failed';
    }
  }
}

/// Singleton controller that polls the backend push queue for the active frame
/// and exposes a [PushJobView] to the UI. Screens mount [PushProgressBanner]
/// (in the widget tree) which listens to this notifier.
///
/// When a photo/playlist is pushed, call [trackPush] with the returned msgid so
/// the selected frame's progress is observed and the banner auto-dismisses 3s
/// after the hardware confirms `play_ack` (status `completed`).
class UploadQueueController extends ChangeNotifier {
  UploadQueueController._();
  static final UploadQueueController instance = UploadQueueController._();

  static const _pollInterval = Duration(milliseconds: 1500);
  static const _completedHold = Duration(seconds: 3);
  // ~480 polls * 1.5s ≈ 12 min. Playlists must download EVERY image before the
  // frame can ACK the first render (~40-80s per .bin on the real frame, so a
  // 5-photo playlist can take several minutes); the backend keeps those jobs
  // alive while the frame heartbeats, so the banner must outlast a single
  // image's 180s timeout rather than giving up early.
  static const _maxAttempts = 480;

  PushJobView? _currentJob;
  Timer? _pollTimer;
  Timer? _dismissTimer;
  String? _activeMac;
  String? _pairingToken;
  String? _userAuthToken;
  int _attempts = 0;
  bool _disposed = false;
  bool _treatTimeoutAsSuccess = false;

  /// The msgid for which a "Frame updated" notification has already fired, so
  /// the notification is emitted exactly once per job (never on repeat polls).
  String? _notifiedMsgid;
  bool _notifyOnCompletion = true;

  PushJobView? get currentJob => _currentJob;

  void beginShare(String sessionId, String label) {
    cancelTracking();
    _currentJob = PushJobView(
      stage: PushJobStage.uploading,
      progress: 0,
      msgid: sessionId,
      label: label,
    );
    notifyListeners();
  }

  void updateShare(String sessionId, double progress, String label) {
    if (_currentJob?.msgid != sessionId) return;
    _currentJob = PushJobView(
      stage: PushJobStage.uploading,
      progress: progress.clamp(0, .95),
      msgid: sessionId,
      label: label,
    );
    notifyListeners();
  }

  void finishShare(
    String sessionId, {
    bool failed = false,
    bool queued = false,
    String? label,
  }) {
    if (_currentJob?.msgid != sessionId) return;
    _currentJob = PushJobView(
      stage: failed
          ? PushJobStage.failed
          : queued
          ? PushJobStage.queued
          : PushJobStage.completed,
      progress: failed || queued ? (_currentJob?.progress ?? 0) : 1,
      msgid: sessionId,
      label: label,
    );
    notifyListeners();
    _dismissTimer?.cancel();
    _dismissTimer = Timer(_completedHold, () {
      if (_currentJob?.msgid == sessionId) cancelTracking();
    });
  }

  /// Start observing a push job. Polls every 1.5s until the job reaches a
  /// terminal state, then auto-dismisses the banner after [completedHold].
  void trackPush({
    required String mac,
    required String msgid,
    String? pairingToken,
    String? userAuthToken,
    bool notifyOnCompletion = true,
    /// Playlist/slideshow jobs can legitimately take minutes on e-ink hardware
    /// (download + flash + refresh per image). When true, a server-side
    /// `timeout_failed` is treated as "dispatch accepted, ACK is background"
    /// and the banner clears quietly instead of flashing a red "Push failed".
    bool treatTimeoutAsSuccess = false,
  }) {
    cancelTracking();
    _notifyOnCompletion = notifyOnCompletion;
    _treatTimeoutAsSuccess = treatTimeoutAsSuccess;
    _activeMac = mac;
    _pairingToken = pairingToken;
    _userAuthToken = userAuthToken;
    _attempts = 0;
    _notifiedMsgid = null;
    _currentJob = PushJobView(
      stage: PushJobStage.queued,
      progress: 0,
      msgid: msgid,
      status: 'queued',
    );
    notifyListeners();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
    // Fire one poll immediately.
    unawaited(_poll());
  }

  /// Register a push job for an already-uploaded image (from a cast/upload) and
  /// start tracking its hardware progression. Non-blocking: fire-and-forget.
  ///
  /// [imgUrl] is the frame-facing media URL (e.g. `.../frame-media/xxx.bin`).
  /// The server enqueues the job (FIFO per MAC) and returns a msgid to poll.
  Future<void> registerPushAfterUpload({
    required String mac,
    required String mediaUrl,
    String? pairingToken,
    String? userAuthToken,
  }) async {
    final api = FrameApiClient();
    try {
      final res = await api.pushToFrame(
        deviceId: mac,
        type: 'single',
        imgs: [
          {'imgid': mediaUrl.split('/').last, 'imgurl': mediaUrl},
        ],
        pairingToken: pairingToken,
        userAuthToken: userAuthToken,
      );
      final msgid = (res['msgid'] as String?) ?? '';
      if (msgid.isNotEmpty) {
        trackPush(
          mac: mac,
          msgid: msgid,
          pairingToken: pairingToken,
          userAuthToken: userAuthToken,
        );
      }
    } catch (_) {
      // Non-blocking: a failed push registration just means no banner.
    } finally {
      api.close();
    }
  }

  /// Stop polling and clear the banner (e.g. user left the screen).
  void cancelTracking() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _dismissTimer?.cancel();
    _dismissTimer = null;
    if (_currentJob != null) {
      _currentJob = null;
      _activeMac = null;
      _pairingToken = null;
      _userAuthToken = null;
      _attempts = 0;
      notifyListeners();
    }
  }

  Future<void> _poll() async {
    final mac = _activeMac;
    final job = _currentJob;
    if (mac == null ||
        job == null ||
        job.stage == PushJobStage.completed ||
        job.stage == PushJobStage.failed) {
      return;
    }
    _attempts++;
    if (_attempts > _maxAttempts) {
      if (_treatTimeoutAsSuccess) {
        // Playlist dispatch was accepted (HTTP 200); ACK polling is background.
        _clearWithCompleted();
        return;
      }
      _setFailed(
        PushJobView(
          stage: PushJobStage.failed,
          progress: job.progress,
          msgid: job.msgid,
          status: 'timeout_failed',
        ),
      );
      return;
    }

    final api = FrameApiClient();
    // Push-status is a capability poll, not an auth/session probe. Keep the
    // global 401 handler suppressed for this request: a stale status token
    // must never log the user out or show "Session expired". Preserve any
    // suppression that was already active (e.g. from the pairing flow).
    final auth = AuthSessionManager.instance;
    final wasSuppressed = auth.isSuppressed;
    auth.suppressUnauthorizedHandling(true);
    try {
      final res = await api.fetchPushStatus(
        deviceId: mac,
        msgid: job.msgid,
        pairingToken: _pairingToken,
        userAuthToken: _userAuthToken,
      );
      if (_disposed || mac != _activeMac || _currentJob?.msgid != job.msgid) {
        return;
      }
      if (res == null) {
        // Transient poll failure — keep waiting, don't mark failed yet.
        _setJob(job);
        return;
      }
      final status = (res['status'] as String?) ?? 'queued';
      double progress = ((res['progress'] as num?)?.toDouble() ?? 0).clamp(
        0.0,
        1.0,
      );
      final next = _mapStatus(status, progress, job.msgid);
      if (next.stage == PushJobStage.completed) {
        _setJob(next);
        // 🔔 ONLY trigger the "Frame updated" notification here — the job has
        // reached 100% because the hardware sent `play_ack` (status completed).
        // Never fire from upload/dispatch, which happens before the frame
        // actually displays the image. Guarded so it fires exactly once.
        if (_notifyOnCompletion && _notifiedMsgid != job.msgid) {
          _notifiedMsgid = job.msgid;
          unawaited(_notifyCompletedHome());
        }
        _dismissTimer?.cancel();
        _dismissTimer = Timer(_completedHold, _clearWithCompleted);
        _pollTimer?.cancel();
        _pollTimer = null;
        return;
      }
      if (next.stage == PushJobStage.failed) {
        if (_treatTimeoutAsSuccess) {
          _clearWithCompleted();
          return;
        }
        _setJob(next);
        _pollTimer?.cancel();
        _pollTimer = null;
        return;
      }
      _setJob(next);
    } catch (_) {
      if (_disposed || mac != _activeMac || _currentJob?.msgid != job.msgid) {
        return;
      }
      _setJob(job);
    } finally {
      // Restore the caller's suppression state (do not force-disable).
      auth.suppressUnauthorizedHandling(wasSuppressed);
      api.close();
    }
  }

  PushJobView _mapStatus(String status, double progress, String msgid) {
    switch (status) {
      case 'completed':
        return PushJobView(
          stage: PushJobStage.completed,
          progress: 1.0,
          msgid: msgid,
          status: status,
        );
      case 'downloaded':
        // Image reached the device; E-Ink is now refreshing (can take 60-120s).
        return PushJobView(
          stage: PushJobStage.refreshing,
          progress: progress.clamp(0.65, 0.95),
          msgid: msgid,
          status: status,
        );
      case 'dispatched':
        // Server published `play` — frame is downloading the image over HTTP.
        return PushJobView(
          stage: PushJobStage.downloading,
          progress: progress.clamp(0.3, 0.6),
          msgid: msgid,
          status: status,
        );
      case 'timeout_failed':
      case 'failed':
        return PushJobView(
          stage: PushJobStage.failed,
          progress: progress,
          msgid: msgid,
          status: status,
        );
      case 'queued':
      default:
        return PushJobView(
          stage: PushJobStage.queued,
          progress: 0,
          msgid: msgid,
          status: status,
        );
    }
  }

  void _clearWithCompleted() {
    if (_disposed) return;
    _currentJob = null;
    _activeMac = null;
    _pairingToken = null;
    _userAuthToken = null;
    _notifiedMsgid = null;
    _dismissTimer = null;
    notifyListeners();
  }

  /// Fire the "Frame updated" heads-up once, post-hardware-ACK. Uses the local
  /// NotificationService (high-priority Android channel + iOS foreground
  /// banner). Permission is requested at app start via [requestPermission]
  /// and FCM's [syncTokenWithAuth]; the notification is best-effort.
  Future<void> _notifyCompletedHome() async {
    try {
      await NotificationService.instance.requestPermission();
      final strings = AppStrings.current;
      await NotificationService.instance.showFrameUpdatedNotification(
        title: strings.frameUpdatedNotificationTitle,
        body: strings.frameUpdatedNotificationBody,
      );
    } catch (e) {
      AppDiagLog.verbose('[UploadQueue] completion notification failed: $e');
    }
  }

  void _setFailed(PushJobView job) {
    if (_disposed) return;
    _currentJob = job;
    _pollTimer?.cancel();
    _pollTimer = null;
    notifyListeners();
  }

  void _setJob(PushJobView job) {
    if (_disposed) return;
    // Avoid a re-render if nothing changed.
    final prev = _currentJob;
    if (prev != null &&
        prev.stage == job.stage &&
        (prev.progress - job.progress).abs() < 0.001 &&
        prev.status == job.status) {
      return;
    }
    _currentJob = job;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _dismissTimer?.cancel();
    super.dispose();
  }
}
