import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../services/device_store.dart';
import '../services/frame_api_client.dart';
import '../services/sleep_mode_store.dart';

/// Sleep Mode & Power Management.
///
/// Toggles Sleep Mode and the automatic sleep/wake schedule, persists the
/// preference locally, and relays the strict firmware `wifi_sleep` payload
/// to the paired frame via the server. Album playback uses the `play` flow.
class SleepSettingsScreen extends StatefulWidget {
  const SleepSettingsScreen({super.key, this.frame});
  final PairedFrame? frame;

  @override
  State<SleepSettingsScreen> createState() => _SleepSettingsScreenState();
}

class _SleepSettingsScreenState extends State<SleepSettingsScreen> {
  final _red = const Color(0xFFE53935);

  late bool _enabled;
  late TimeOfDay _start;
  late TimeOfDay _end;
  var _frameConnected = false;
  var _loaded = false;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final store = SleepModeStore.forFrame(widget.frame ?? DeviceStore.instance.cached);
    await store.resolveForUi();
    await DeviceStore.instance.load();
    if (!mounted) return;
    final connected = DeviceStore.instance.pairedFrames
        .any((f) => f.deviceId.trim().isNotEmpty);
    setState(() {
      _enabled = store.enabled;
      _start = store.startTime;
      _end = store.endTime;
      _frameConnected = connected;
      _loaded = true;
    });
  }

  String _formatTime(TimeOfDay t) {
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final p = t.period == DayPeriod.am ? 'AM' : 'PM';
    return '$h:${t.minute.toString().padLeft(2, '0')} $p';
  }

  Future<void> _pickTime(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _start : _end,
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _start = picked;
      } else {
        _end = picked;
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final s = AppStrings.of(context);
    final store = SleepModeStore.forFrame(widget.frame ?? DeviceStore.instance.cached);
    await store.setEnabled(_enabled);
    await store.setSchedule(start: _start, end: _end);
    final pushed = await store.pushConfigToFrame();

    // Disabling sleep → the backend immediately clears the sleep lock and the
    // frame wakes + republishes telemetry. Invalidate the status cache and pull
    // fresh telemetry at 500ms + 2000ms so "In Sleep Mode" -> "Online" and the
    // battery / SD-card numbers update without an app restart or 30s delay.
    if (!_enabled) {
      final paired = widget.frame ?? DeviceStore.instance.cached;
      if (paired != null) {
        final mac = DeviceStore.macForPairedFrame(paired) ?? paired.deviceId;
        FrameApiClient().invalidateStatusCache(mac);
        for (final delay in [const Duration(milliseconds: 500), const Duration(seconds: 2)]) {
          unawaited(() async {
            await Future<void>.delayed(delay);
            if (!mounted) return;
            final api = FrameApiClient();
            await api.fetchFrameStatus(
              mac: mac,
              pairingToken: paired.resolvedPairingToken,
              force: true,
            );
            api.invalidateStatusCache(mac, notify: true);
            api.close();
          }());
        }
      }
    }

    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(pushed || !_frameConnected ? s.sleepSaved : s.saveFailed),
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
        title: Text(s.sleepMode, style: TextStyle(fontWeight: FontWeight.bold, color: cs.onSurface)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                Card(
                  margin: EdgeInsets.zero,
                  child: SwitchListTile.adaptive(
                    value: _enabled,
                    activeTrackColor: _red,
                    title: Text(s.sleepModeEnabled),
                    subtitle: Text(s.sleepModeHint),
                    onChanged: (v) => setState(() => _enabled = v),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      ListTile(
                        title: Text(s.sleepStartTime),
                        trailing: Text(
                          _formatTime(_start),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        onTap: _enabled ? () => _pickTime(true) : null,
                        enabled: _enabled,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        title: Text(s.wakeUpTime),
                        trailing: Text(
                          _formatTime(_end),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        onTap: _enabled ? () => _pickTime(false) : null,
                        enabled: _enabled,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (!_frameConnected)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      s.noFramePaired,
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                    ),
                  ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: _red,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _saving ? null : () => unawaited(_save()),
                  child: Text(_saving ? '…' : s.save),
                ),
              ],
            ),
    );
  }
}
