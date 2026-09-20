import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../screens/family_screen.dart';
import '../screens/gallery_screen.dart';
import '../screens/home_screen.dart';
import '../screens/send_screen.dart';
import '../screens/settings_screen.dart';
import '../services/account_sync_service.dart';
import '../services/app_diag_log.dart';
import '../services/device_store.dart';
import '../services/external_share_cast_service.dart';
import '../services/external_share_inbox.dart';
import '../services/fcm_service.dart';
import '../services/share_extension_cache.dart';
import '../services/share_incoming_service.dart';
import '../services/personal_gallery_store.dart';
import '../services/upload_queue_controller.dart';
import '../services/sync_pipeline.dart';
import '../settings/app_settings.dart';
import 'shell_navigation.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => MainShellState();
}

class MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _index = 0;
  final ValueNotifier<int> sendGalleryPickNonce = ValueNotifier<int>(0);
  final ValueNotifier<List<String>> sendSharedPathsNonce =
      ValueNotifier<List<String>>(const []);
  bool _shareSheetOpen = false;
  bool _nativeConsuming = false;
  Timer? _nativeTimer;
  final Set<String> _trackedNative = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ShellNavigation.registerHost(
      _setIndex,
      openSendGalleryPick: openSendGalleryPicker,
    );
    ShareIncomingService.instance.revision.addListener(
      _onShareIncomingRevision,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumeSharedPaths();
      _consumePendingNativeShare();
      _nativeTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _consumePendingNativeShare(),
      );
      _startSyncPipeline();
      _syncFcmTokenIfSignedIn();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startSyncPipeline();
      // Native iOS Share Extension hand-off: reads any pending share the
      // extension wrote to the App Group and routes it through the normal
      // local-ingestion pipeline (persist → trackPush → banner).
      unawaited(_consumePendingNativeShare());
      _nativeTimer ??= Timer.periodic(
        const Duration(seconds: 2),
        (_) => _consumePendingNativeShare(),
      );
      // Soft tick — not replaceFrames pull (that re-imported ghosts).
      unawaited(
        SyncPipeline.instance.tick(
          forceFrames: true,
          forceGallery: true,
          forceAlbums: true,
        ),
      );
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _nativeTimer?.cancel();
      _nativeTimer = null;
      SyncPipeline.instance.stop();
      AccountSyncService.instance.stopPeriodicSync();
    }
  }

  /// iOS-only: pick up external shares the native Share Extension uploaded
  /// silently in its own process and recorded in the App Group. On the next
  /// launch/resume we:
  ///   1. persist the shared images to the correct local gallery folder
  ///      (single → Personal tab, 2+ → "My Playlist" on the Playlists tab),
  ///   2. attach UploadQueueController tracking for each recorded
  ///      {mac, msgid} so the in-app progress banner renders the live (or just
  ///      finished) frame ACK progress in the Gallery.
  /// Nothing here opens the app — the extension completed silently.
  Future<void> _consumePendingNativeShare() async {
    if (!Platform.isIOS) return;
    if (!ShareExtensionCache.instance.isSupported) return;
    if (_nativeConsuming) return;
    _nativeConsuming = true;
    try {
      final pendingList = await ShareExtensionCache.instance
          .consumePendingExternalShares();
      if (pendingList.isEmpty) return;
      AppDiagLog.verbose(
        '[MainShell] pending native shares=${pendingList.length}',
      );
      for (final pending in pendingList) {
        await _ingestPendingShare(pending);
        if (pending.completed) {
          await ShareExtensionCache.instance.acknowledgePendingShare(
            pending.id,
            paths: pending.paths,
          );
          await _removeStagedShareFiles(pending.paths);
        }
      }
      // Land on the Gallery sub-tab matching the share: Playlists (1) for a
      // multi-photo playlist share, Personal (0) for a single photo. Never
      // leave the user on Personal after a playlist share.
      if (mounted) {
        final isPlaylist = pendingList.any((p) => p.isPlaylist);
        ShellNavigation.goToGallery(subTab: isPlaylist ? 1 : 0);
      }
    } catch (e) {
      AppDiagLog.verbose('[MainShell] consume pending native share: $e');
    } finally {
      _nativeConsuming = false;
    }
  }

  /// Best-effort cleanup of the Share Extension's staged JPEGs in the App Group
  /// container after they have been durable-copied into the app gallery.
  Future<void> _removeStagedShareFiles(List<String> paths) async {
    for (final path in paths) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (e) {
        AppDiagLog.verbose('[MainShell] staged file cleanup skipped: $e');
      }
    }
  }

  /// Persists one deferred external share into the local gallery database and
  /// attaches progress-banner tracking for the pushes the extension fired.
  Future<void> _ingestPendingShare(PendingExternalShare pending) async {
    if (!mounted) return;
    final app = AppSettingsScope.of(context);
    final s = AppStrings.of(context);
    await ExternalShareInbox.instance.persist(
      pending.paths,
      sessionId: pending.id,
      playlistName: s.myPlaylistName,
    );
    // A playlist share must NEVER appear in the Personal feed — self-heal any
    // leaked entries from earlier ingestion ordering.
    if (pending.isPlaylist || pending.paths.length > 1) {
      await PersonalGalleryStore.instance.removePaths(pending.paths);
    }
    final queue = UploadQueueController.instance;
    if (pending.pushes.isEmpty) {
      if (_trackedNative.add(pending.id)) {
        queue.beginShare(pending.id, s.sharedUploadLabel(pending.paths.length));
      }
      queue.updateShare(
        pending.id,
        pending.progress,
        s.sharedUploadLabel(pending.paths.length),
      );
      if (pending.completed || pending.failed) {
        queue.finishShare(pending.id, failed: pending.failed);
      }
    }
    for (final push in pending.pushes) {
      if (!_trackedNative.add('${push.mac}:${push.msgid}')) continue;
      queue.trackPush(
        mac: push.mac,
        msgid: push.msgid,
        userAuthToken: app.authToken,
        notifyOnCompletion: !pending.isPlaylist,
        treatTimeoutAsSuccess: pending.isPlaylist,
      );
    }
  }

  void _startSyncPipeline() {
    if (!mounted) return;
    final app = AppSettingsScope.of(context);
    if (!app.hasAuthenticatedSession) {
      SyncPipeline.instance.stop();
      AccountSyncService.instance.stopPeriodicSync();
      return;
    }
    // Single pipeline: 10s tick + event hooks. Stop legacy 2‑min-only poll.
    AccountSyncService.instance.stopPeriodicSync();
    SyncPipeline.instance.start(appSettings: app);
  }

  void _syncFcmTokenIfSignedIn() {
    if (!mounted) return;
    final app = AppSettingsScope.of(context);
    if (!app.hasAuthenticatedSession) return;
    unawaited(FcmService.instance.syncTokenWithAuth(app));
  }

  @override
  void dispose() {
    _nativeTimer?.cancel();
    SyncPipeline.instance.stop();
    AccountSyncService.instance.stopPeriodicSync();
    WidgetsBinding.instance.removeObserver(this);
    ShareIncomingService.instance.revision.removeListener(
      _onShareIncomingRevision,
    );
    ShellNavigation.unregisterHost();
    sendGalleryPickNonce.dispose();
    sendSharedPathsNonce.dispose();
    super.dispose();
  }

  void _onShareIncomingRevision() {
    if (!mounted) return;
    _consumeSharedPaths();
  }

  Future<void> _consumeSharedPaths() async {
    if (_shareSheetOpen || !mounted) return;
    _shareSheetOpen =
        true; // Before ANY await: cold and hot deliveries can race.
    try {
      while (mounted && ShareIncomingService.instance.hasPending) {
        final items = ShareIncomingService.instance.takePendingItems();
        if (items.isEmpty) break;
        if (!mounted) break;
        final app = AppSettingsScope.of(context);
        final s = AppStrings.of(context);
        final raw = items.map((e) => e.path).toList();
        final session = items.first.sessionId.isNotEmpty
            ? items.first.sessionId
            : ExternalShareInbox.keyFor(raw);
        final label = s.sharedUploadLabel(raw.length);
        final queue = UploadQueueController.instance;
        queue.beginShare(session, label);
        try {
          final paths = await ExternalShareInbox.instance.persist(
            raw,
            sessionId: session,
            playlistName: s.myPlaylistName,
          );
          if (paths.length > 1) {
            await PersonalGalleryStore.instance.removePaths(paths);
          }
          await DeviceStore.instance.load();
          final selected = await ShareExtensionCache.instance.consumeAutoSend();
          final frames = selected.isEmpty
              ? [
                  if (DeviceStore.instance.cached != null)
                    DeviceStore.instance.cached!,
                ]
              : DeviceStore.instance.pairedFrames
                    .where((f) => selected.contains(f.deviceId))
                    .toList();
          if (frames.isEmpty) {
            queue.finishShare(
              session,
              failed: true,
              label: s.connectFrameFirst,
            );
            continue;
          }
          final summary = await ExternalShareCastService.instance.castToFrames(
            paths: paths,
            frames: frames,
            authToken: app.authToken,
            strings: s,
            sessionId: session,
            locallyPersisted: true,
            onProgress: (progress, _) =>
                queue.updateShare(session, progress, label),
          );
          queue.finishShare(
            session,
            queued: summary.queued,
            failed: !summary.queued && summary.sent == 0,
            label: summary.queued ? s.shareSheetQueuedOffline : null,
          );
        } catch (e) {
          queue.finishShare(session, failed: true);
          AppDiagLog.verbose('[MainShell] external share failed: $e');
        } finally {
          ShareIncomingService.instance.completeBatch(session);
        }
      }
    } finally {
      _shareSheetOpen = false;
    }
  }

  /// Legacy path: jump to Send tab with shared paths (album / sequential editor).
  void openSendWithSharedPaths(List<String> paths) {
    if (paths.isEmpty) return;
    _setIndex(2);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      sendSharedPathsNonce.value = List<String>.from(paths);
    });
  }

  void openSendGalleryPicker() {
    _setIndex(2);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      sendGalleryPickNonce.value++;
    });
  }

  void _setIndex(int i) {
    if (i < 0 || i >= 5) return;
    final prev = _index;
    if (prev == 2 && i != 2) {
      ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
    }
    setState(() => _index = i);
    if (ShellNavigation.activeTab.value != i) {
      ShellNavigation.activeTab.value = i;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final cs = Theme.of(context).colorScheme;
    final app = AppSettingsScope.of(context);
    final primary = cs.primary;
    final barColor = cs.surface;
    final comfort = app.comfortMode;
    final barHeight = comfort ? 72.0 : 64.0;
    final iconSize = comfort ? 28.0 : 24.0;
    final labelSize = comfort ? 11.0 : 10.0;

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(
              bottom: ShellNavigation.contentBottomOverlap(context),
            ),
            child: IndexedStack(
              index: _index,
              children: [
                const HomeScreen(),
                const GalleryScreen(),
                SendScreen(
                  galleryPickNonce: sendGalleryPickNonce,
                  sharedPathsNonce: sendSharedPathsNonce,
                ),
                const FamilyScreen(),
                const SettingsScreen(),
              ],
            ),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: Tooltip(
        message: s.navSend,
        child: SizedBox(
          width: 68,
          height: 68,
          child: Material(
            shape: const CircleBorder(),
            elevation: 6,
            shadowColor: primary.withValues(alpha: 0.45),
            color: primary,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: openSendGalleryPicker,
              child: Icon(Icons.send_rounded, color: cs.onPrimary, size: 30),
            ),
          ),
        ),
      ),
      bottomNavigationBar: Container(
        color: barColor,
        child: SafeArea(
          top: false,
          child: BottomAppBar(
            clipBehavior: Clip.antiAlias,
            color: barColor,
            surfaceTintColor: Colors.transparent,
            shadowColor: cs.brightness == Brightness.dark
                ? Colors.black54
                : Colors.black12,
            elevation: 8,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            height: barHeight,
            shape: const CircularNotchedRectangle(),
            notchMargin: 8,
            child: Row(
              children: [
                _DockItem(
                  icon: Icons.home_outlined,
                  selIcon: Icons.home_rounded,
                  label: s.navMyFrames,
                  selected: _index == 0,
                  primary: primary,
                  iconSize: iconSize,
                  labelSize: labelSize,
                  onTap: () => _setIndex(0),
                ),
                _DockItem(
                  icon: Icons.arrow_circle_up_outlined,
                  selIcon: Icons.arrow_circle_up_rounded,
                  label: s.navGallery,
                  selected: _index == 1,
                  primary: primary,
                  iconSize: iconSize,
                  labelSize: labelSize,
                  onTap: () => _setIndex(1),
                ),
                SizedBox(width: comfort ? 88 : 80),
                _DockItem(
                  icon: Icons.groups_outlined,
                  selIcon: Icons.groups_rounded,
                  label: s.navFamily,
                  selected: _index == 3,
                  primary: primary,
                  iconSize: iconSize,
                  labelSize: labelSize,
                  onTap: () => _setIndex(3),
                ),
                _DockItem(
                  icon: Icons.settings_outlined,
                  selIcon: Icons.settings_rounded,
                  label: s.navSettings,
                  selected: _index == 4,
                  primary: primary,
                  iconSize: iconSize,
                  labelSize: labelSize,
                  onTap: () => _setIndex(4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.icon,
    required this.selIcon,
    required this.label,
    required this.selected,
    required this.primary,
    required this.onTap,
    this.iconSize = 24,
    this.labelSize = 10,
  });

  final IconData icon;
  final IconData selIcon;
  final String label;
  final bool selected;
  final Color primary;
  final VoidCallback onTap;
  final double iconSize;
  final double labelSize;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final col = selected ? primary : cs.onSurfaceVariant;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(selected ? selIcon : icon, color: col, size: iconSize),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: labelSize,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                  color: col,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
