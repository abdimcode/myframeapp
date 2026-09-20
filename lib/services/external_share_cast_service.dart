import 'dart:async';

import '../config/api_config.dart';
import '../l10n/app_strings.dart';
import '../models/frame_playback_profile.dart';
import 'app_diag_log.dart';
import 'device_store.dart';
import 'external_share_queue.dart';
import 'external_share_inbox.dart';
import 'local_storage_service.dart';
import 'frame_ble_mac_slug.dart';
import 'frame_cloud_cast_service.dart';
import 'frame_api_client.dart';
import 'frame_settings_store.dart';
import 'frame_online_guard.dart';
import 'gallery_image_normalizer.dart';
import 'network_link.dart';
import 'send_albums_store.dart';
import 'slideshow_playlist_store.dart';
import 'slideshow_remote_api.dart';
import 'sync_pipeline.dart';
import '../widgets/shell_navigation.dart';
import 'upload_queue_controller.dart';

/// External sharing → app (gallery / share sheet) upload orchestrator.
///
/// External payloads bypass the internal playlist/album configuration UI and
/// are uploaded immediately, **inheriting the target frame's active Frame
/// Profile** (interval / playback order / duration) instead of hardcoding a
/// fixed interval. When the device is offline or a frame is unreachable, the
/// normalized payload is persisted to the [ExternalShareQueue] and retried
/// automatically once connectivity returns.
class ExternalShareCastService {
  ExternalShareCastService._();
  static final ExternalShareCastService instance = ExternalShareCastService._();

  final Map<String, Future<ExternalShareCastSummary>> _sessions = {};

  Future<ExternalShareCastSummary> castToFrames({
    required List<String> paths,
    required List<PairedFrame> frames,
    required String authToken,
    required AppStrings strings,
    void Function(double progress, String status)? onProgress,
    String? sessionId,
    bool locallyPersisted = false,
  }) async {
    final session = sessionId ?? ExternalShareInbox.keyFor(paths);
    final user = await LocalStorageService.instance.currentUserId();
    final targets = frames.map((f) => f.deviceId).toSet().toList()..sort();
    final key = '$user:$session:${targets.join(',')}';
    return _sessions.putIfAbsent(
      key,
      () => _castToFrames(
        paths: paths,
        frames: frames.where((f) => targets.remove(f.deviceId)).toList(),
        authToken: authToken,
        strings: strings,
        onProgress: onProgress,
        sessionId: session,
        locallyPersisted: locallyPersisted,
      ),
    );
  }

  Future<ExternalShareCastSummary> _castToFrames({
    required List<String> paths,
    required List<PairedFrame> frames,
    required String authToken,
    required AppStrings strings,
    void Function(double progress, String status)? onProgress,
    String? sessionId,
    bool locallyPersisted = false,
  }) async {
    if (frames.isEmpty || paths.isEmpty) {
      return const ExternalShareCastSummary(sent: 0, queued: false);
    }

    final session = sessionId ?? ExternalShareInbox.keyFor(paths);
    final items = locallyPersisted
        ? paths
        : await ExternalShareInbox.instance.persist(
            paths,
            sessionId: session,
            playlistName: strings.myPlaylistName,
          );
    var sent = 0;
    var queued = false;

    for (var fi = 0; fi < frames.length; fi++) {
      final frame = frames[fi];
      final profile = await FrameSettingsStore.instance.load(frame);
      if (!await hasNetworkInterface()) {
        await _enqueueForFrame(frame, items, authToken, profile, session);
        queued = true;
        continue;
      }
      // If the frame is offline (hasn't heartbeated recently), queue for
      // later delivery instead of attempting a doomed upload.
      if (!await FrameOnlineGuard.isFrameEffectivelyOnline(frame)) {
        AppDiagLog.verbose(
          '[ExternalShare] frame offline — queueing ${items.length} photos',
        );
        await _enqueueForFrame(frame, items, authToken, profile, session);
        queued = true;
        continue;
      }

      final r = await _uploadToFrame(
        frame: frame,
        items: items,
        authToken: authToken,
        strings: strings,
        profile: profile,
        sessionId: session,
        onProgress: (frac, status) {
          onProgress?.call((fi + frac) / frames.length, status);
        },
      );
      sent += r.sent;
      if (r.queued) queued = true;
    }

    return ExternalShareCastSummary(sent: sent, queued: queued);
  }

  Future<({int sent, bool queued})> _uploadToFrame({
    required PairedFrame frame,
    required List<String> items,
    required String authToken,
    required AppStrings strings,
    required FramePlaybackProfile profile,
    required String sessionId,
    void Function(double progress, String status)? onProgress,
  }) async {
    final api = FrameApiClient();
    final label = _frameLabel(frame, strings);
    final ids = <String>[];
    final pendingPaths = <String>[];
    var sentCount = 0;

    try {
      for (var i = 0; i < items.length; i++) {
        final item = await GalleryImageNormalizer.normalizeFileForUpload(
          items[i],
        );
        if (item == null) {
          throw StateError('Cannot normalize shared image ${i + 1}');
        }
        onProgress?.call(
          (i + 0.35) / items.length,
          strings.shareSheetSendingTo(label),
        );

        final cast = await FrameCloudCastService.instance.castPhoto(
          api: api,
          paired: frame,
          jpegBytes: item.bytes,
          filename: 'share_${DateTime.now().millisecondsSinceEpoch}_$i.jpg',
          slideshowStyle: 'classic',
          displaySeconds: profile.intervalSeconds,
          strings: strings,
          userAuthToken: authToken.trim().isEmpty ? null : authToken.trim(),
          syncSlideshowAfterSuccess: false,
          skipPlay: items.length > 1,
          editsJson: null,
          // Source isolation: multi-photo external-share payloads must NOT bleed
          // into the user's Personal Album grid. Single-photo shares remain
          // directCast (default). Backend uses source=playlist to exclude these
          // from GET /api/user/gallery.
          source: items.length > 1
              ? UploadSource.playlist
              : UploadSource.directCast,
          // Multi-image external shares: ONE strategy_bin playlist job (tracked
          // after publish) powers the banner — never N per-photo single plays.
          registerPushProgress: items.length == 1,
          onProgress: (p) {
            onProgress?.call(
              (i + (p.progress ?? 0.5)) / items.length,
              p.message,
            );
          },
        );

        if (cast.ok) {
          final id = cast.slideshowImageId?.trim();
          if (items.length > 1 && (id == null || id.isEmpty)) {
            throw StateError('Upload returned no playlist image ID');
          }
          sentCount++;
          if (id != null && id.isNotEmpty) ids.add(id);
          continue;
        }

        // Offline / frame unreachable → keep the failed + remaining photos for
        // the persistent background queue instead of dropping them.
        for (var j = i; j < items.length; j++) {
          pendingPaths.add(items[j]);
        }
        AppDiagLog.verbose(
          '[ExternalShare] upload stopped at $i: ${cast.message}',
        );
        break;
      }

      // Local Playlist persistence: multi-photo external shares MUST create/
      // append a real Playlist album (Playlists tab), never the Personal feed.
      if (items.length > 1) {
        await _persistSharedToPlaylist(items, strings);
        // Keep the user on the Playlists tab after a multi-photo share.
        ShellNavigation.goToGallery(subTab: 1);
      }

      if (items.length > 1 &&
          ids.length == items.length &&
          pendingPaths.isEmpty) {
        await _publishExternal(frame, ids, authToken, profile);
        unawaited(
          SlideshowPlaylistStore.instance.save(
            paired: frame,
            imageIds: ids,
            intervalMinutes: profile.intervalMinutes,
          ),
        );
      }

      var queued = false;
      if (pendingPaths.isNotEmpty) {
        await _enqueueForFrame(
          frame,
          items,
          authToken,
          profile,
          sessionId,
          uploadedIds: ids,
        );
        queued = true;
      }
      return (sent: sentCount, queued: queued);
    } finally {
      api.close();
    }
  }

  Future<void> _publishExternal(
    PairedFrame frame,
    List<String> imageIds,
    String authToken,
    FramePlaybackProfile profile,
  ) async {
    try {
      // Multi-image external share = a playlist dispatch. immediatePlay defaults
      // true so photo[0] renders immediately; source tagged 'playlist' for the
      // backend isolation filter.
      final playlistMsgid = await SlideshowRemoteApi(baseUrl: ApiConfig.baseUrl)
          .publish(
            bearerToken: authToken.trim().isEmpty ? null : authToken.trim(),
            pairingToken: frame.resolvedPairingToken,
            macSlug: frameBleMacSlug(frame),
            imageIds: imageIds,
            intervalMinutes: profile.intervalMinutes,
            strategy: profile.strategy,
            durationHours: profile.durationHours,
            skipPlay: false,
            source: 'playlist',
          );
      // Consolidate the whole external share into ONE tracked playlist job: the
      // banner (mounted on the Gallery tab) follows the frame's first-render ACK
      // for this strategy_bin command instead of queuing N per-photo `play`s.
      if (playlistMsgid != null && playlistMsgid.isNotEmpty) {
        UploadQueueController.instance.trackPush(
          mac: FrameCloudCastService.instance.uploadDeviceId(frame),
          msgid: playlistMsgid,
          pairingToken: frame.resolvedPairingToken,
          userAuthToken: authToken.trim().isEmpty ? null : authToken.trim(),
          notifyOnCompletion: false,
              treatTimeoutAsSuccess: true,
        );
      }
    } catch (e) {
      AppDiagLog.verbose('[ExternalShare] slideshow publish failed: $e');
      rethrow;
    }
  }

  Future<void> _enqueueForFrame(
    PairedFrame frame,
    List<String> durablePaths,
    String authToken,
    FramePlaybackProfile profile,
    String sessionId, {
    List<String> uploadedIds = const [],
  }) async {
    if (durablePaths.isEmpty) return;
    final targets = frame.resolvedFrameUploadTargets;
    if (targets.isEmpty) return;
    await ExternalShareQueue.instance.enqueue(
      QueuedExternalShare(
        id: '${sessionId}_${frame.deviceId}',
        uploadedIds: uploadedIds,
        paths: durablePaths,
        uploadTargets: targets,
        baseUrl: frame.resolvedApiBaseUrl,
        pairingToken: frame.resolvedPairingToken,
        authToken: authToken,
        macSlug: frameBleMacSlug(frame),
        displaySeconds: profile.intervalSeconds,
        intervalMinutes: profile.intervalMinutes,
        strategy: profile.strategy,
        durationHours: profile.durationHours,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  String _frameLabel(PairedFrame f, AppStrings s) {
    final name = f.frameName?.trim() ?? '';
    return name.isNotEmpty ? name : f.listDisplayTitle(s);
  }

  /// Creates/appends the default "My Playlist" album for a multi-photo external
  /// share so the Playlists tab shows a permanent card (independent of frame
  /// status polling / the temporary push queue).
  Future<void> _persistSharedToPlaylist(List<String> paths, AppStrings strings) async {
    if (paths.length < 2) return;
    try {
      final name = strings.myPlaylistName;
      await SendAlbumsStore.instance.load();
      SendAlbumEntry? mine;
      for (final a in SendAlbumsStore.instance.albums) {
        if (a.name.trim().toLowerCase() == name.trim().toLowerCase()) {
          mine = a;
          break;
        }
      }
      String id;
      if (mine == null) {
        await SendAlbumsStore.instance.createAlbum(name, paths);
        await SendAlbumsStore.instance.load();
        id = SendAlbumsStore.instance.albums.first.id;
      } else {
        await SendAlbumsStore.instance.addPathsToAlbum(mine.id, paths);
        id = mine.id;
      }
      unawaited(SyncPipeline.instance.onAlbumsChanged(albumId: id));
    } catch (e) {
      AppDiagLog.verbose('[ExternalShare] playlist persist failed: $e');
    }
  }
}

class ExternalShareCastSummary {

  const ExternalShareCastSummary({required this.sent, required this.queued});

  final int sent;

  /// True when some payloads were persisted for background retry.
  final bool queued;

}
