import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../utils/platform_share.dart';

import '../config/api_config.dart';
import '../config/vps_defaults.dart';
import '../l10n/app_strings.dart';
import '../services/ble_frame_device_transport.dart';
import '../services/ble_display_name.dart';
import '../models/pairing_nav_result.dart';
import '../services/device_store.dart';
import '../services/frame_forget_service.dart';
import '../services/app_release_guard.dart';
import '../services/frame_ble_mac_slug.dart';
import '../services/frame_mac_util.dart';
import '../services/slideshow_remote_api.dart';
import '../navigation/pairing_flow_nav.dart';
import '../services/device_transport.dart' show FrameConnectionState;
import '../services/family_group_store.dart';
import '../services/share_service.dart';
import '../services/frame_api_client.dart';
import '../services/account_sync_service.dart';
import '../services/sync_pipeline.dart';
import '../services/usage_metrics_store.dart';
import '../settings/app_settings.dart';
import '../widgets/shell_navigation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/share_extension_cache.dart';
import 'device_discovery_screen.dart';
import 'device_details_screen.dart';

/// My Frames — paired list, add (+), share, frame detail (spec redesign).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final GlobalKey _addKey = GlobalKey();
  UsageMetrics? _metrics;
  OverlayEntry? _coachEntry;
  bool _checkingFrameStatus = false;
  Timer? _pollTimer;
  Map<String, FrameStatus> _frameStatuses = {};
  final FrameApiClient _apiClient = FrameApiClient();
  var _familyFramesRefreshing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DeviceStore.instance.revision.addListener(_onDeviceStoreRevision);
    FrameApiClient.frameStatusRevision.addListener(_onFrameStatusRevision);
    ShellNavigation.activeTab.addListener(_onShellTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _startPolling();
      unawaited(_syncFamilyFramesIfSignedIn());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DeviceStore.instance.revision.removeListener(_onDeviceStoreRevision);
    FrameApiClient.frameStatusRevision.removeListener(_onFrameStatusRevision);
    ShellNavigation.activeTab.removeListener(_onShellTabChanged);
    _removeCoach();
    _pollTimer?.cancel();
    _apiClient.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        ShellNavigation.activeTab.value == 0) {
      unawaited(_syncFamilyFramesIfSignedIn());
    }
  }

  void _onShellTabChanged() {
    if (!mounted) return;
    if (ShellNavigation.activeTab.value == 0) {
      unawaited(_syncFamilyFramesIfSignedIn());
    }
  }

  /// Invitees inherit owner frames via GET /api/frames — refresh when Home is shown.
  Future<void> _syncFamilyFramesIfSignedIn() async {
    if (!mounted || _familyFramesRefreshing) return;
    final app = AppSettingsScope.of(context);
    final tok = app.authToken.trim();
    if (tok.isEmpty) return;
    _familyFramesRefreshing = true;
    try {
      await DeviceStore.instance.syncServerFrames(bearerToken: tok);
      // Also merge profile bound_frames (clears stale Remove bans for invitees).
      await AccountSyncService.instance.syncAccountState(
        force: true,
        authTokenOverride: tok,
        replaceFrames: true,
        pruneMissingFrames: false,
      );
      if (mounted) await _load();
    } catch (_) {
      /* keep local */
    } finally {
      _familyFramesRefreshing = false;
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshAllFrameStatuses();
    });
  }

  void _onDeviceStoreRevision() {
    if (!mounted) return;
    unawaited(_load());
  }

  /// A frame's live status changed (e.g. sleep toggled OFF) — refresh frame
  /// status + telemetry immediately so "In Sleep Mode" -> "Online".
  void _onFrameStatusRevision() {
    if (!mounted) return;
    unawaited(_load());
  }

  void _removeCoach() {
    _coachEntry?.remove();
    _coachEntry = null;
  }

  Future<void> _onPullToRefresh() async {
    final app = AppSettingsScope.of(context);
    try {
      if (app.hasAuthenticatedSession) {
        await SyncPipeline.instance
            .pullToRefresh()
            .timeout(const Duration(seconds: 40));
      }
      await _load().timeout(const Duration(seconds: 20));
    } catch (_) {
      // Always end the RefreshIndicator even if network/status probes stall.
      if (mounted) await DeviceStore.instance.load();
    }
  }

  Future<void> _load() async {
    await DeviceStore.instance.load();
    await DeviceStore.instance.dedupeRelatedFrames();
    if (!mounted) return;
    final app = AppSettingsScope.of(context);
    await FamilyGroupStore.instance.ensureLoaded(ownerDisplayName: () {
      final name = app.profileName.trim();
      if (name.isNotEmpty) return name;
      final mail = app.accountEmail.trim();
      if (mail.isNotEmpty) return mail.split('@').first;
      return AppStrings.of(context).youLabel;
    });
    await UsageMetricsStore.instance.ensureInitialized();
    final metrics = await UsageMetricsStore.instance.load();
    if (!mounted) return;
    setState(() => _metrics = metrics);
    await _refreshAllFrameStatuses();
    _maybeShowCoachmark(app);
  }

  Future<void> _refreshAllFrameStatuses() async {
    final frames = DeviceStore.instance.pairedFrames;
    if (frames.isEmpty) {
      if (mounted) setState(() {
        _frameStatuses = {};
      });
      return;
    }
    setState(() => _checkingFrameStatus = true);
    final updated = Map<String, FrameStatus>.from(_frameStatuses);

    Future<void> probeOne(PairedFrame f) async {
      final mac = DeviceStore.macForPairedFrame(f) ?? FrameMacUtil.normalizeSlug(f.deviceId);
      if (mac == null || mac.isEmpty) return;
      try {
        final status = await _apiClient
            .fetchFrameStatus(mac: mac, timeout: const Duration(seconds: 4));
        if (status != null) {
          updated[f.deviceId] = status;
        }
      } catch (_) {}
    }

    try {
      await Future.wait(frames.map(probeOne))
          .timeout(const Duration(seconds: 12));
    } catch (_) {}

    if (mounted) setState(() {
      _frameStatuses = updated;
      _checkingFrameStatus = false;
    });

    final onlineIds = updated.entries
        .where((e) => e.value.isEffectivelyOnline)
        .map((e) => e.key)
        .toList();
    ShareExtensionCache.onlineDeviceIds.clear();
    ShareExtensionCache.onlineDeviceIds.addAll(onlineIds);
    unawaited(ShareExtensionCache.instance.syncFrames());
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ShareExtensionOnlineDeviceIds', jsonEncode(onlineIds));
    } catch (_) {}
  }

  String? _macForFrame(PairedFrame f) => DeviceStore.macForPairedFrame(f);

  void _maybeShowCoachmark(AppSettings app) {
    if (!app.pendingHomeAddFrameCoachmark) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _addKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) return;
      final target = box.localToGlobal(Offset.zero);
      final s = AppStrings.of(context);
      final cs = Theme.of(context).colorScheme;
      _coachEntry?.remove();
      _coachEntry = OverlayEntry(
        builder: (ctx) => Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  await app.clearHomeAddFrameCoachmark();
                  _removeCoach();
                },
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              top: target.dy + box.size.height + 6,
              child: Material(
                elevation: 10,
                borderRadius: BorderRadius.circular(14),
                color: cs.surface,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(s.coachAddFrameTitle, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 6),
                      Text(s.coachAddFrameBody, style: TextStyle(color: cs.onSurfaceVariant, height: 1.35)),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          onPressed: () async {
                            await app.clearHomeAddFrameCoachmark();
                            _removeCoach();
                          },
                          child: Text(s.coachGotIt),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
      Overlay.of(context).insert(_coachEntry!);
    });
  }

  Future<void> _shareInvite(AppStrings _) async {
    if (!mounted) return;
    final app = AppSettingsScope.of(context);
    await FamilyGroupStore.instance.ensureLoaded(ownerDisplayName: () {
      final name = app.profileName.trim();
      if (name.isNotEmpty) return name;
      final mail = app.accountEmail.trim();
      if (mail.isNotEmpty) return mail.split('@').first;
      return AppStrings.of(context).youLabel;
    });
    if (!mounted) return;
    final g = FamilyGroupStore.instance;
    final s = AppStrings.of(context);
    final url = ShareService.withShareLang(
      'https://${VpsDefaults.hostnameInk}/join?code=${Uri.encodeComponent(g.inviteCode)}',
      s,
    );
    await platformShareText(
      context,
      text: ShareService.familyInviteShareBody(
        strings: s,
        familyName: g.familyName,
        inviteCode: g.inviteCode,
        webUrl: url,
      ),
      subject: ShareService.familyInviteSubject(s, g.familyName),
    );
  }

  bool _frameLikelyOnline(PairedFrame f) {
    final st = _frameStatuses[f.deviceId];
    if (st != null) return st.isEffectivelyOnline;
    final active = DeviceStore.instance.cached;
    if (BleFrameDeviceTransport.instance.connectionUi.value ==
            FrameConnectionState.connected &&
        active != null &&
        active.deviceId.trim() == f.deviceId.trim()) {
      return true;
    }
    // After BluFi Wi‑Fi success the firmware turns BLE off by design. Treat a
    // freshly provisioned frame as online until status API proves otherwise.
    if (f.isWifiProvisioned) {
      final at = f.wifiProvisionedAtMs;
      if (at != null) {
        final ageMs = DateTime.now().millisecondsSinceEpoch - at;
        if (ageMs >= 0 && ageMs < const Duration(minutes: 15).inMilliseconds) {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _stopFramePlayback(AppStrings s, PairedFrame f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.stopPlaybackLabel),
        content: Text(s.stopPlaybackConfirmBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(s.cancel)),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.stopPlaybackLabel),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final macSlug = frameBleMacSlug(f);
    final token = AppSettingsScope.of(context).authToken.trim();
    final stopped = await SlideshowRemoteApi(baseUrl: ApiConfig.baseUrl)
        .stopPlaylist(
      bearerToken: token.isEmpty ? null : token,
      macSlug: macSlug,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(stopped ? s.stopPlaybackSent : s.sendFailedRetry),
      ),
    );
  }

  Future<void> _confirmRemoveFrame(AppStrings s, PairedFrame f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.removePairingTitle),
        content: Text(s.removePairingBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.remove)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await FrameForgetService.instance.forgetFrame(f.deviceId);
    if (!mounted) return;
    await _load();
    // Stop Home's family-frame sync from flashing the deleted card.
    if (mounted) setState(() {});
  }

  void _showOfflineDialog() {
    final s = AppStrings.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.frameOfflineReconnectTitle),
        content: Text(s.frameOfflineReconnectBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.gotItLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.myFramesTitle, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: cs.onSurface)),
            const SizedBox(height: 2),
            Text(s.myFramesSubtitle, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          ],
        ),
        actions: [
          IconButton(
            key: _addKey,
            tooltip: s.pairBluetoothFrame,
            icon: Icon(Icons.add_circle_outline, color: cs.primary, size: 28),
            onPressed: () async {
              await AppSettingsScope.of(context).clearHomeAddFrameCoachmark();
              _removeCoach();
              final result = await SafeNav.push<PairingNavResult>(
                context,
                MaterialPageRoute<PairingNavResult>(
                  builder: (_) => const DeviceDiscoveryScreen(),
                ),
              );
              await _load();
              PairingFlowNav.onComplete(result);
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(
        listenable: BleFrameDeviceTransport.instance.connectionUi,
        builder: (context, _) {
          final frames = DeviceStore.instance.pairedFrames;
          final activeId = DeviceStore.instance.cached?.deviceId.trim();
          bool isOnline(PairedFrame f) {
            final st = _frameStatuses[f.deviceId];
            if (st != null) return st.isEffectivelyOnline;
            return _frameLikelyOnline(f);
          }

          final total = frames.length;
          var onlineC = 0;
          for (final f in frames) {
            if (isOnline(f)) onlineC++;
          }
          final offlineC = total - onlineC;

          final active = DeviceStore.instance.cached;
          // Only warn when status API explicitly says offline — not on unknown
          // / sticky-miss right after BLE drops post Wi‑Fi.
          final activeStatus =
              active == null ? null : _frameStatuses[active.deviceId];
          final showOfflineBanner = active != null &&
              activeStatus != null &&
              !activeStatus.isEffectivelyOnline &&
              !_checkingFrameStatus &&
              onlineC == 0;

          return RefreshIndicator(
            color: const Color(0xFFE5252A),
            displacement: 48,
            onRefresh: _onPullToRefresh,
            child: ListView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              if (showOfflineBanner) ...[
                GestureDetector(
                  onTap: _showOfflineDialog,
                  child: Card(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.orange.shade900.withOpacity(0.35)
                        : Colors.orange.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              s.frameOfflineLabel,
                              style: TextStyle(fontWeight: FontWeight.w800, color: cs.onSurface),
                            ),
                          ),
                          Icon(Icons.chevron_right, color: Colors.orange.shade300),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(
                        Theme.of(context).brightness == Brightness.dark ? 0.28 : 0.04,
                      ),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      total == 1 ? '1 ${s.statusFrame}' : '$total ${s.statusFrames}',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: cs.onSurface),
                    ),
                    Row(
                      children: [
                        Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFF4CAF50), shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Text('$onlineC ${s.statusOnline}', style: TextStyle(fontSize: 13, color: cs.onSurface)),
                        const SizedBox(width: 12),
                        Text('·', style: TextStyle(color: cs.outline)),
                        const SizedBox(width: 12),
                        Container(width: 8, height: 8, decoration: BoxDecoration(color: cs.onSurfaceVariant, shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Text('$offlineC ${s.statusOffline}', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (frames.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.notPaired, style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text(s.scanDeviceBody, style: TextStyle(color: cs.onSurfaceVariant, height: 1.4)),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          onPressed: () async {
                            final result = await SafeNav.push<PairingNavResult>(
                              context,
                              MaterialPageRoute<PairingNavResult>(
                                builder: (_) => const DeviceDiscoveryScreen(),
                              ),
                            );
                            await _load();
                            PairingFlowNav.onComplete(result);
                          },
                          icon: const Icon(Icons.bluetooth_searching),
                          label: Text(s.pairBluetoothFrame),
                        ),
                      ],
                    ),
                  ),
                )
              else
                ...frames.map((PairedFrame f) {
                  final online = isOnline(f);
                  final isActive = activeId != null && activeId == f.deviceId.trim();
                  final titleText = f.listDisplayTitle(s);
                  final noCustomName = f.frameName == null || f.frameName!.trim().isEmpty;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: cs.outlineVariant),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () async {
                          await DeviceStore.instance.setActiveFrameDeviceId(f.deviceId);
                          if (!mounted) return;
                          await Navigator.push<void>(
                            context,
                            MaterialPageRoute<void>(builder: (_) => DeviceDetailsScreen(frame: f)),
                          );
                          await _load();
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: cs.primary.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(Icons.crop_original, color: cs.primary, size: 28),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            titleText,
                                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: cs.onSurface),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (isActive) ...[
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: cs.primary.withOpacity(0.12),
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            child: Text(s.activeFrameLabel, style: TextStyle(color: cs.primary, fontSize: 11, fontWeight: FontWeight.bold)),
                                          ),
                                        ],
                                      ],
                                    ),
                                    if (noCustomName) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        BleDisplayName.fallbackTitle(f.bleRemoteId ?? f.deviceId),
                                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, fontFamily: 'monospace'),
                                      ),
                                    ],
                                                    const SizedBox(height: 6),
                                    _FrameStatusLine(
                                      status: _frameStatuses[f.deviceId],
                                      online: online,
                                      strings: s,
                                      colorScheme: cs,
                                    ),
                                    if (_metrics?.lastPhotoAt != null) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        s.lastPhotoDynamic(_relative(_metrics!.lastPhotoAt!, s)),
                                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                                      ),
                                    ],
                                    const SizedBox(height: 8),
                                    _FrameMetricsRow(status: _frameStatuses[f.deviceId]),
                                  ],
                                ),
                              ),
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: s.shareToFamily,
                                    onPressed: () => unawaited(_shareInvite(s)),
                                    icon: Icon(Icons.ios_share, color: cs.primary, size: 20),
                                  ),
                                  PopupMenuButton<String>(
                                    tooltip: s.remove,
                                    onSelected: (value) {
                                      if (value == 'stop') {
                                        unawaited(_stopFramePlayback(s, f));
                                      } else if (value == 'remove') {
                                        unawaited(_confirmRemoveFrame(s, f));
                                      }
                                    },
                                    icon: Icon(Icons.more_horiz, color: cs.onSurfaceVariant, size: 20),
                                    itemBuilder: (ctx) => [
                                      PopupMenuItem<String>(
                                        value: 'stop',
                                        child: Text(s.stopPlaybackLabel),
                                      ),
                                      PopupMenuItem<String>(
                                        value: 'remove',
                                        child: Text(s.remove),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
            ],
          ),
          );
        },
      ),
    );
  }

  String _relative(DateTime ts, AppStrings s) {
    final d = DateTime.now().difference(ts);
    if (d.inSeconds < 45) return s.justNow;
    if (d.inMinutes < 60) return s.minutesAgo(d.inMinutes);
    if (d.inHours < 48) return s.hoursAgo(d.inHours);
    return s.daysAgo(d.inDays);
  }
}

class _FrameStatusLine extends StatelessWidget {
  const _FrameStatusLine({
    this.status,
    required this.online,
    required this.strings,
    required this.colorScheme,
  });

  final FrameStatus? status;
  final bool online;
  final AppStrings strings;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final sleeping = status?.sleeping == true || status?.isNetworkSleeping == true;
    final wakeEnd = status?.sleepEnd;
    if (sleeping) {
      final label = strings.frameSleepModeLabel;
      final wake = wakeEnd == null || wakeEnd.isEmpty
          ? label
          : '$label · ${_wakeLabel(strings, wakeEnd)}';
      return Row(
        children: [
          const Icon(Icons.bedtime, size: 14, color: Color(0xFF7B1FA2)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              wake,
              style: TextStyle(fontSize: 12.5, color: const Color(0xFF7B1FA2)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }
    return Text(
      '${strings.frameModelDefault} · ${online ? strings.statusOnline : strings.statusOffline}',
      style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
    );
  }

  String _wakeLabel(AppStrings s, String end) {
    final parts = end.split(':');
    var h = int.tryParse(parts.isEmpty ? '' : parts[0]) ?? 0;
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final ampm = h >= 12 ? 'PM' : 'AM';
    h = h % 12;
    if (h == 0) h = 12;
    return s.frameSleepWakeScheduledAt('${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')} $ampm');
  }
}

class _FrameMetricsRow extends StatelessWidget {
  const _FrameMetricsRow({this.status});

  final FrameStatus? status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = status;
    if (st == null) return const SizedBox.shrink();

    return Column(
      children: [
        Row(
          children: [
            Icon(Icons.battery_std_outlined, size: 16, color: const Color(0xFF4CAF50)),
            const SizedBox(width: 8),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: st.batteryFraction,
                  minHeight: 6,
                  backgroundColor: cs.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    st.battery > 20 ? const Color(0xFF4CAF50) : Colors.redAccent,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text('${st.battery}%', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(Icons.sd_storage, size: 16, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: st.storageFraction,
                  minHeight: 6,
                  backgroundColor: cs.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text('${st.storageUsedFormatted} / ${st.storageTotalFormatted}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ],
        ),
      ],
    );
  }
}
