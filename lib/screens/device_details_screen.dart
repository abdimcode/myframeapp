import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../services/device_store.dart';
import '../services/frame_api_client.dart';
import '../services/frame_forget_service.dart';
import '../widgets/text_input_bottom_sheet.dart';

class DeviceDetailsScreen extends StatefulWidget {
  const DeviceDetailsScreen({super.key, this.frame});

  final PairedFrame? frame;

  @override
  State<DeviceDetailsScreen> createState() => _DeviceDetailsScreenState();
}

class _DeviceDetailsScreenState extends State<DeviceDetailsScreen>
    with WidgetsBindingObserver {
  PairedFrame? _paired;
  FrameStatus? _status;
  Timer? _pollTimer;
  final FrameApiClient _api = FrameApiClient();
  var _savingName = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FrameApiClient.frameStatusRevision.addListener(_onFrameStatusRevision);
    _load();
    _startPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FrameApiClient.frameStatusRevision.removeListener(_onFrameStatusRevision);
    _pollTimer?.cancel();
    _api.close();
    super.dispose();
  }

  /// A frame status changed (e.g. sleep toggled OFF) — force-refresh telemetry
  /// immediately so battery / SD-card / RSSI + "In Sleep Mode" -> "Online" show
  /// instantly.
  void _onFrameStatusRevision() {
    if (!mounted) return;
    unawaited(_fetch(force: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _fetch();
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) => _fetch());
  }

  Future<void> _load() async {
    await DeviceStore.instance.load();
    if (mounted) {
      setState(() => _paired = widget.frame ?? DeviceStore.instance.cached);
      await _fetch();
    }
  }

  Future<void> _fetch({bool force = false}) async {
    final p = _paired;
    if (p == null) return;
    final mac = _resolveMac;
    if (mac == null || mac.length != 12) return;
    try {
      final st = await _api.fetchFrameStatus(
        mac: mac,
        timeout: const Duration(seconds: 5),
        force: force,
        pairingToken: p.resolvedPairingToken,
      );
      if (mounted && st != null && identical(p, _paired)) {
        setState(() => _status = st);
      }
    } catch (_) {}
  }

  String? get _resolveMac {
    final p = _paired;
    if (p == null) return null;
    return DeviceStore.macForPairedFrame(p);
  }

  String get _deviceName => _paired?.frameName?.trim().isNotEmpty == true
      ? _paired!.frameName!
      : (_paired?.listDisplayTitle(AppStrings(AppLocale.en)) ?? 'MyFrame');

  String get _macAddress {
    final hex = (_resolveMac ?? '').toUpperCase();
    if (hex.length == 12) {
      return '${hex.substring(0, 2)}:${hex.substring(2, 4)}:${hex.substring(4, 6)}:${hex.substring(6, 8)}:${hex.substring(8, 10)}:${hex.substring(10, 12)}';
    }
    final p = _paired;
    if (p == null) return '--';
    final rawHex =
        p.deviceId.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    if (rawHex.length >= 12) {
      final s = rawHex.substring(rawHex.length - 12);
      return '${s.substring(0, 2)}:${s.substring(2, 4)}:${s.substring(4, 6)}:${s.substring(6, 8)}:${s.substring(8, 10)}:${s.substring(10, 12)}';
    }
    return '--';
  }

  String get _wifiSsid {
    final p = _paired;
    final st = _status;
    // Preserve this frame's last known network even while it is offline.
    if (st != null) {
      if (st.wifiSsid.trim().isNotEmpty) {
        return st.wifiSsid;
      }
    }
    if (p?.wifiSsid?.trim().isNotEmpty == true && p!.isWifiProvisioned) {
      return p.wifiSsid!;
    }
    return '--';
  }

  String _lastSeen(AppStrings s) {
    final st = _status;
    if (st == null) return '--';
    final ms = st.lastSeenMs;
    if (ms == null || ms <= 0) return '--';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return s.justNow;
    if (diff.inMinutes < 60) return s.minutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return s.hoursAgo(diff.inHours);
    if (diff.inDays < 7) return s.daysAgo(diff.inDays);
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  PairedFrame? _frameAfterRename(String deviceId) {
    for (final f in DeviceStore.instance.pairedFrames) {
      if (f.deviceId == deviceId) return f;
    }
    return DeviceStore.instance.cached;
  }

  Future<void> _editFrameName() async {
    final p = _paired;
    if (p == null || _savingName) return;
    final s = AppStrings.of(context);
    final next = await TextInputBottomSheet.show(
      context,
      title: s.frameNameLabel,
      label: s.frameNameLabel,
      confirmLabel: s.saveLabel,
      initialText: p.frameName?.trim() ?? '',
    );
    if (next == null || !mounted) return;
    final clean = next.trim();
    if (clean.isEmpty || clean == (p.frameName?.trim() ?? '')) return;
    setState(() => _savingName = true);
    try {
      await DeviceStore.instance.updateFrameDisplayName(
        clean,
        deviceId: p.deviceId,
      );
      await DeviceStore.instance.load();
      if (!mounted) return;
      setState(() => _paired = _frameAfterRename(p.deviceId));
    } finally {
      if (mounted) setState(() => _savingName = false);
    }
  }

  Future<void> _confirmDelete() async {
    final p = _paired;
    if (p == null) return;
    final s = AppStrings.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteDevice),
        content: Text(s.deleteDeviceConfirm(_deviceName)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(s.cancel)),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.deleteButton,
                style: const TextStyle(color: Color(0xFFE53935))),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    // Same path as Home "Remove" — account unbind + local wipe (owner/family-owner).
    // Show a blocking loader while the backend unbind + local wipe complete so
    // the user cannot re-open the deleted device during the unbind window.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Dialog(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
                SizedBox(width: 16),
                Flexible(child: Text('Removing device…')),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      await FrameForgetService.instance.forgetFrame(p.deviceId);
    } finally {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(); // close loader
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  static const _red = Color(0xFFE53935);

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final p = _paired;
    final st = _status;
    final isOnline = st?.isEffectivelyOnline ?? false;
    final battery = st?.battery ?? 100;
    final storageRatio = st?.storageFraction ?? 0;
    // Dynamic firmware version reported by the frame (no hardcoded fallback).
    final fw = st?.firmwareVersion;
    final firmware = (fw == null || fw.isEmpty)
        ? '--'
        : (fw.startsWith('v') ? fw : 'v$fw');

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          s.deviceDetails,
          style: tt.titleMedium?.copyWith(
            color: cs.onSurface,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        centerTitle: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: cs.onSurface, size: 28),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            tooltip: s.frameNameLabel,
            onPressed: p == null || _savingName ? null : _editFrameName,
            icon: _savingName
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.edit_outlined, color: cs.onSurfaceVariant),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _heroCard(_deviceName, _macAddress, isOnline, s, st),
              const SizedBox(height: 16),
              if (st?.isNetworkSleeping == true) ...[
                _powerSavingBanner(s),
                const SizedBox(height: 16),
              ],
              _sectionHeader(s.statusSection),
              _card(
                child: Column(
                  children: [
                    _statusRow(
                      icon: Icons.battery_std_outlined,
                      label: s.batteryLabel,
                      child: Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: battery / 100.0,
                                minHeight: 6,
                                backgroundColor: cs.surfaceContainerHighest,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                    Color(0xFF4CAF50)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '$battery%',
                            style: tt.bodyMedium?.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: cs.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _statusRow(
                      icon: Icons.sd_storage_outlined,
                      label: s.storageLabel,
                      child: Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: storageRatio,
                                minHeight: 6,
                                backgroundColor: cs.surfaceContainerHighest,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                    Color(0xFF4CAF50)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                            Text(
                              _storageText(),
                              style: tt.bodySmall?.copyWith(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: cs.onSurface,
                              ),
                            ),
                          ],
                        ),
                      ),
                    // Live SD-card + charging + Wi-Fi signal (accurate telemetry).
                    if (_status?.sdCardMounted != null ||
                        _status?.isCharging != null ||
                        _status?.wifiRssi != null) ...[
                      const SizedBox(height: 12),
                      _statusRow(
                        icon: Icons.wifi,
                        label: s.networkSignalLabel,
                        child: Text(
                          _wifiSignalText(),
                          style: tt.bodySmall?.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                      if (_status?.isCharging != null) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              (_status!.isCharging == true)
                                  ? Icons.battery_charging_full
                                  : Icons.battery_std,
                              size: 16,
                              color: (_status!.isCharging == true)
                                  ? const Color(0xFF4CAF50)
                                  : cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              (_status!.isCharging == true)
                                  ? s.chargingState
                                  : s.dischargingState,
                              style: tt.bodySmall?.copyWith(
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (_status?.sdCardMounted == false) ...[
                        const SizedBox(height: 8),
                        Text(
                          s.sdCardNotMounted,
                          style: tt.bodySmall?.copyWith(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _sectionHeader(s.deviceInfoSection),
              _card(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _infoTile(
                      s.frameNameLabel,
                      _deviceName,
                      onTap: p == null || _savingName ? null : _editFrameName,
                    ),
                    Divider(
                        height: 1,
                        indent: 16,
                        endIndent: 16,
                        color: cs.outlineVariant),
                    _infoTile(s.macLabel, _macAddress),
                    Divider(
                        height: 1,
                        indent: 16,
                        endIndent: 16,
                        color: cs.outlineVariant),
                    _infoTile(s.firmwareVersionLabel, firmware),
                    Divider(
                        height: 1,
                        indent: 16,
                        endIndent: 16,
                        color: cs.outlineVariant),
                    _infoTile(s.networkNameLabel, _wifiSsid),
                    Divider(
                        height: 1,
                        indent: 16,
                        endIndent: 16,
                        color: cs.outlineVariant),
                    _infoTile(s.lastSeenLabel, _lastSeen(s)),
                    Divider(
                        height: 1,
                        indent: 16,
                        endIndent: 16,
                        color: cs.outlineVariant),
                    _infoTile(s.wifiSignalLabel,
                        isOnline ? s.connected : s.disconnected),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              Center(
                child: SizedBox(
                  width: 220,
                  height: 44,
                  child: OutlinedButton(
                    onPressed: p == null ? null : _confirmDelete,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: _red, width: 1.2),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(
                      s.deleteDevice,
                      style: const TextStyle(
                          color: _red,
                          fontWeight: FontWeight.bold,
                          fontSize: 15),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _heroCard(String name, String mac, bool online, AppStrings s, FrameStatus? status) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final sleeping = status?.sleeping == true || status?.isNetworkSleeping == true;
    // Sleep is a distinct state: show a moon "In Sleep Mode" (purple/amber)
    // badge instead of Online or the grey Offline dot.
    final badgeColor = sleeping
        ? const Color(0xFF7B1FA2) // deep purple
        : (online ? const Color(0xFF4CAF50) : cs.onSurfaceVariant);
    final badgeText = sleeping ? s.frameSleepModeLabel : (online ? s.onlineStatus : s.offlineStatus);
    final wakeText = _sleepWakeLabel(s);

    return _card(
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: _red,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.cast, color: Colors.white, size: 32),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  name,
                  textAlign: TextAlign.center,
                  style: tt.titleLarge?.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: cs.onSurface,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed:
                    _paired == null || _savingName ? null : _editFrameName,
                icon: Icon(Icons.edit_outlined,
                    size: 18, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            mac,
            style: tt.bodyMedium?.copyWith(
              fontSize: 13,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                sleeping ? Icons.bedtime : Icons.circle,
                size: sleeping ? 16 : 8,
                color: badgeColor,
              ),
              const SizedBox(width: 6),
              Text(
                badgeText,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: badgeColor,
                ),
              ),
            ],
          ),
          if (sleeping && wakeText != null) ...[
            const SizedBox(height: 2),
            Text(
              wakeText,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Local 12-hour "Scheduled wake-up at …" string from the sleep window.
  String? _sleepWakeLabel(AppStrings s) {
    final end = _status?.sleepEnd;
    if (end == null || end.isEmpty) return null;
    final parts = end.split(':');
    if (parts.isEmpty) return null;
    var h = int.tryParse(parts[0]) ?? 0;
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final ampm = h >= 12 ? 'PM' : 'AM';
    h = h % 12;
    if (h == 0) h = 12;
    return s.frameSleepWakeScheduledAt('${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')} $ampm');
  }

  Widget _powerSavingBanner(AppStrings s) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.bedtime_outlined, size: 20, color: cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              s.powerSavingPlayback,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child, EdgeInsetsGeometry? padding}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: child,
    );
  }

  Widget _sectionHeader(String title) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
      ),
    );
  }

  Widget _statusRow({
    required IconData icon,
    required String label,
    required Widget child,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, color: _red, size: 20),
        const SizedBox(width: 8),
        SizedBox(
          width: 56,
          child: Text(label,
              style: TextStyle(fontSize: 14, color: cs.onSurface)),
        ),
        const SizedBox(width: 16),
        Expanded(child: child),
      ],
    );
  }

  Widget _infoTile(String title, String value, {VoidCallback? onTap}) {
    final cs = Theme.of(context).colorScheme;
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: TextStyle(fontSize: 14, color: cs.onSurface)),
          Flexible(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    value,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 14,
                      color: cs.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (onTap != null) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.edit_outlined,
                      size: 16, color: cs.onSurfaceVariant),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }

  String _storageText() {
    final st = _status;
    // Prefer live SD-card capacity when present, else fall back to storage fields.
    if (st != null && st.sdCardMounted == true && st.sdCardFreeMb != null) {
      final used = (st.sdCardTotalMb ?? 0) - (st.sdCardFreeMb ?? 0);
      final usedGb = (used / 1024).toStringAsFixed(1);
      final totalGb = ((st.sdCardTotalMb ?? 0) / 1024).toStringAsFixed(1);
      return '$usedGb / $totalGb GB';
    }
    return '${st?.storageUsedFormatted ?? '0.0 GB'} / ${st?.storageTotalFormatted ?? '32.0 GB'}';
  }

  String _wifiSignalText() {
    final rssi = _status?.wifiRssi;
    if (rssi == null) return '--';
    String strength = rssi >= -55 ? 'Strong' : (rssi >= -70 ? 'Good' : (rssi >= -85 ? 'Fair' : 'Weak'));
    return '$rssi dBm · $strength';
  }
}
