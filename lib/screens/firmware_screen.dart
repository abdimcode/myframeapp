import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../services/device_store.dart';
import '../services/frame_api_client.dart';

/// OTA Firmware Update.
///
/// Shows the paired frame(s), the current vs latest firmware version, release
/// notes, and an "Install update" button that triggers the backend OTA MQTT
/// pipeline (offline guard + confirmation dialog).
class FirmwareScreen extends StatefulWidget {
  const FirmwareScreen({super.key, this.frame});
  final PairedFrame? frame;

  @override
  State<FirmwareScreen> createState() => _FirmwareScreenState();
}

class _FirmwareScreenState extends State<FirmwareScreen> {
  final _red = const Color(0xFFE53935);

  List<PairedFrame> _frames = [];
  PairedFrame? _selected;
  FirmwareInfo? _info;
  var _loading = false;
  var _updating = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    await DeviceStore.instance.load();
    final frames = DeviceStore.instance.pairedFrames;
    if (!mounted) return;
    setState(() {
      _frames = frames;
      _selected = widget.frame ?? DeviceStore.instance.cached ?? (frames.isNotEmpty ? frames.first : null);
    });
    await _refresh();
  }

  String? _macOf(PairedFrame f) => DeviceStore.macForPairedFrame(f);

  String _frameLabel(PairedFrame f) {
    final name = f.frameName;
    if (name != null && name.trim().isNotEmpty) return name.trim();
    final mac = _macOf(f);
    if (mac != null && mac.isNotEmpty) return mac;
    return f.deviceId;
  }

  /// User-facing release notes for the current app locale. Prefers the
  /// server's localized changelog bullets; falls back to the raw releaseNotes
  /// string (split on newlines) when the server didn't return arrays.
  List<String> _releaseNotesFor(FirmwareInfo info, AppStrings s) {
    final bullets = s.locale == AppLocale.zh
        ? (info.changelogZh.isNotEmpty ? info.changelogZh : info.changelogEn)
        : (info.changelogEn.isNotEmpty ? info.changelogEn : info.changelogZh);
    if (bullets.isNotEmpty) return bullets;
    final raw = info.releaseNotes;
    if (raw == null || raw.trim().isEmpty) return const [];
    return raw
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  Future<void> _refresh() async {
    final f = _selected;
    if (f == null) return;
    final mac = _macOf(f);
    if (mac == null || mac.isEmpty) return;
    setState(() {
      _loading = true;
      _info = null;
    });
    final api = FrameApiClient();
    try {
      final info = await api.fetchFirmware(mac: mac, pairingToken: f.pairingToken);
      if (mounted && _selected?.deviceId == f.deviceId) {
        setState(() {
          _info = info;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && _selected?.deviceId == f.deviceId) setState(() => _loading = false);
    } finally {
      api.close();
    }
  }

  Future<void> _onDeviceSelected(PairedFrame f) async {
    setState(() => _selected = f);
    await _refresh();
  }

  void _showOffline(AppStrings s) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.firmwareUpdateTitle),
        content: Text(s.firmwareFrameOffline),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.okLabel)),
        ],
      ),
    );
  }

  Future<void> _triggerUpdate() async {
    final s = AppStrings.of(context);
    final f = _selected;
    final info = _info;
    if (f == null || info == null) return;
    final mac = _macOf(f);
    if (mac == null || mac.isEmpty) return;

    if (!info.frameOnline) {
      _showOffline(s);
      return;
    }

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.firmwareUpdateTitle),
        content: Text(
          '${s.firmwareUpdateAvailable}\n\n'
          '${_frameLabel(f)}  ${info.currentLabel} → ${info.latestLabel}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.firmwareInstallUpdate),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _updating = true);
    final api = FrameApiClient();
    final ok = await api.triggerFirmwareUpdate(mac: mac, pairingToken: f.pairingToken);
    api.close();
    if (!mounted) return;
    setState(() => _updating = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? s.firmwareUpdating : s.firmwareUpdateFailed)),
    );
    if (ok) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final cs = Theme.of(context).colorScheme;
    final info = _info;
    final hasUpdate = info?.hasUpdate ?? false;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          s.firmwareUpdateTitle,
          style: TextStyle(fontWeight: FontWeight.bold, color: cs.onSurface),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _frames.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(s.firmwareNoDevice, textAlign: TextAlign.center),
              ),
            )
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                if (_frames.length > 1) ...[
                  _devicePicker(s),
                  const SizedBox(height: 12),
                ],
                if (_selected != null)
                  Card(
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      leading: Icon(
                        info == null
                            ? Icons.devices_other
                            : info.frameOnline
                                ? Icons.wifi
                                : Icons.wifi_off,
                        color: info == null
                            ? cs.onSurfaceVariant
                            : info.frameOnline
                                ? Colors.green
                                : _red,
                      ),
                      title: Text(_frameLabel(_selected!)),
                      subtitle: Text(
                        info == null
                            ? s.firmwareCurrentVersion
                            : info.frameOnline
                                ? s.firmwareCurrentVersion
                                : s.firmwareFrameOffline,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_loading)
                          const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
                        else if (info == null)
                          Text(s.firmwareUpdateFailed)
                        else ...[
                          _versionRow(s.firmwareCurrentVersion, info.currentLabel, cs),
                          const Divider(height: 24),
                          _versionRow(s.firmwareLatestVersion, info.latestLabel, cs),
                          const SizedBox(height: 16),
                          if (_releaseNotesFor(info, s).isNotEmpty) ...[
                            Text(
                              s.firmwareUpdateSub,
                              style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurface),
                            ),
                            const SizedBox(height: 8),
                            ..._releaseNotesFor(info, s).map(
                              (line) => Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('•  ',
                                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                                    Expanded(
                                      child: Text(
                                        line,
                                        style: TextStyle(
                                            color: cs.onSurfaceVariant, fontSize: 13, height: 1.4),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (hasUpdate)
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: _red,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _updating ? null : () => unawaited(_triggerUpdate()),
                    child: Text(
                      _updating
                          ? '…'
                          : '${s.firmwareInstallUpdate} (${info?.latestLabel ?? ''})',
                    ),
                  )
                else if (!_loading)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '${s.firmwareUpToDate} (${info?.latestLabel ?? ''})',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _devicePicker(AppStrings s) {
    return Card(
      margin: EdgeInsets.zero,
      child: DropdownButtonFormField<PairedFrame>(
        initialValue: _selected,
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          border: InputBorder.none,
        ),
        items: _frames
            .map((f) => DropdownMenuItem<PairedFrame>(
                  value: f,
                  child: Text(_frameLabel(f)),
                ))
            .toList(),
        onChanged: (f) {
          if (f != null) unawaited(_onDeviceSelected(f));
        },
      ),
    );
  }

  Widget _versionRow(String label, String value, ColorScheme cs) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: cs.onSurfaceVariant)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    );
  }
}
