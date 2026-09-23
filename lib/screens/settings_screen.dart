import 'dart:async';

import 'package:flutter/material.dart';

import '../config/feature_flags.dart';
import '../l10n/app_strings.dart';
import '../services/device_store.dart';
import '../services/frame_api_client.dart';
import '../services/ota_update_store.dart';
import '../services/sleep_mode_store.dart';
import '../settings/app_settings.dart';
import 'settings_account_screen.dart';
import 'settings_language_screen.dart';
// import 'settings_appearance_screen.dart';
// import 'settings_integrations_screen.dart';
import 'settings_ai_generate_screen.dart';
import 'settings_app_preferences_screen.dart';
import 'settings_help_screen.dart';
import 'settings_log_screen.dart';
import 'settings_debug_screen.dart';
import 'device_discovery_screen.dart';

import 'playlist_screen.dart';
import 'sleep_settings_screen.dart';
import 'frame_settings_screen.dart';
import 'firmware_screen.dart';

const _red = Color(0xFFE53935);

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  PairedFrame? _selectedFrame;
  List<PairedFrame> _frames = [];
  final Map<String, FrameStatus> _statuses = {};
  bool _savingDeviceSetting = false;
  int _selectionGeneration = 0;
  var _sleepEnabled = false;
  var _autoOtaEnabled = false;
  TimeOfDay _sleepStart = SleepModeStore.defaultStart;
  TimeOfDay _sleepEnd = SleepModeStore.defaultEnd;
  var _firmwareVersion = '--';
  var _hasUpdate = false;
  var _sleepReady = false;
  var _otaReady = false;

  @override
  void initState() {
    super.initState();
    DeviceStore.instance.revision.addListener(_onFramesChanged);
    unawaited(_loadDeviceToggles());
  }

  @override
  void dispose() {
    DeviceStore.instance.revision.removeListener(_onFramesChanged);
    super.dispose();
  }

  void _onFramesChanged() {
    // Reload only the selected frame when the device list changes.
    unawaited(_loadDeviceToggles());
  }

  Future<void> _loadDeviceToggles() async {
    final generation = ++_selectionGeneration;
    await DeviceStore.instance.load();
    if (!mounted || generation != _selectionGeneration) return;
    _frames = DeviceStore.instance.pairedFrames;
    if (!_frames.any((f) => f.deviceId == _selectedFrame?.deviceId)) {
      _selectedFrame = DeviceStore.instance.cached ?? (_frames.isEmpty ? null : _frames.first);
    }
    final selected = _selectedFrame;
    setState(() { _sleepReady = false; _otaReady = false; _firmwareVersion = '--'; _hasUpdate = false; });
    if (selected == null) return;
    final sleep = SleepModeStore.forFrame(selected);
    final ota = OtaUpdateStore.forFrame(selected);
    await Future.wait([sleep.resolveForUi(), ota.resolveForUi()]);
    if (!mounted || generation != _selectionGeneration) return;
    setState(() {
      _sleepEnabled = sleep.enabled; _sleepStart = sleep.startTime; _sleepEnd = sleep.endTime;
      _autoOtaEnabled = ota.enabled; _sleepReady = true; _otaReady = true;
    });
    final api = FrameApiClient();
    try {
      await Future.wait(_frames.map((frame) async {
        final mac = DeviceStore.macForPairedFrame(frame);
        if (mac == null) return;
        final status = await api.fetchFrameStatus(mac: mac);
        if (!mounted || generation != _selectionGeneration || status == null) return;
        setState(() {
          _statuses[frame.deviceId] = status;
          if (frame.deviceId == selected.deviceId) {
            _firmwareVersion = status.firmwareVersion ?? '--'; _hasUpdate = status.hasUpdate;
          }
        });
      }));
    } finally { api.close(); }
  }

  Widget _frameSelector(AppStrings s) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: _frames.map((f) {
      final status = _statuses[f.deviceId];
      final label = status == null ? '…' : status.isEffectivelyOnline ? s.statusOnline : s.statusOffline;
      return Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(
        label: Text('${f.listDisplayTitle(s)} · $label'),
        selected: _selectedFrame?.deviceId == f.deviceId,
        onSelected: _savingDeviceSetting ? null : (_) {
          setState(() => _selectedFrame = f); unawaited(_loadDeviceToggles());
        },
      ));
    }).toList())),
    if (_selectedFrame != null && _statuses[_selectedFrame!.deviceId]?.isEffectivelyOnline == false)
      Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(
        s.locale == AppLocale.zh ? '更改将在相框重新连接后生效。' : 'Changes will apply when frame reconnects.',
        style: Theme.of(context).textTheme.bodySmall)),
    const SizedBox(height: 8),
  ]);

  String _languageSubtitle(AppSettings app, AppStrings s) {
    return switch (app.languageCode) {
      null => s.languageSystem,
      'en' => s.languageEnglish,
      'zh' => s.languageChinese,
      'es' => s.languageSpanish,
      'fr' => s.languageFrench,
      'de' => s.languageGerman,
      'ja' => s.languageJapanese,
      _ => s.languageEnglish,
    };
  }

  String _pairingSubtitle(AppStrings s) {
    return s.scanDeviceTitle;
  }

  String _formatTime(TimeOfDay t) {
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final p = t.period == DayPeriod.am ? 'AM' : 'PM';
    return '$h:${t.minute.toString().padLeft(2, '0')} $p';
  }

  String _sleepSubtitle(AppStrings s) {
    if (!_sleepEnabled) return s.disabledLabel;
    return '${_formatTime(_sleepStart)} – ${_formatTime(_sleepEnd)}';
  }

  String _otaSubtitle(AppStrings s) {
    final auto = _autoOtaEnabled ? s.otaAutoCheckOn : s.otaAutoCheckOff;
    if (_hasUpdate) return '${s.firmwareUpdateAvailable} ($_firmwareVersion · $auto)';
    return '${s.firmwareCurrentVersion} $_firmwareVersion · $auto';
  }

  Future<void> _onSleepToggle(bool value) async {
    final frame = _selectedFrame;
    if (frame == null || _savingDeviceSetting) return;
    setState(() => _savingDeviceSetting = true);
    final store = SleepModeStore.forFrame(frame);
    await store.setEnabled(value);
    final ok = await store.pushConfigToFrame();
    if (!mounted) return;
    setState(() { _savingDeviceSetting = false; if (ok) _sleepEnabled = value; });
    if (!ok) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppStrings.of(context).locale == AppLocale.zh ? '无法保存设置，请重试。' : 'Could not save settings. Please retry.')));
  }

  Future<void> _onOtaToggle(bool value) async {
    final frame = _selectedFrame;
    if (frame == null || _savingDeviceSetting) return;
    setState(() => _savingDeviceSetting = true);
    try {
      await OtaUpdateStore.forFrame(frame).setEnabled(value);
      if (mounted) setState(() => _autoOtaEnabled = value);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppStrings.of(context).locale == AppLocale.zh ? '无法保存设置，请重试。' : 'Could not save settings. Please retry.')));
    } finally { if (mounted) setState(() => _savingDeviceSetting = false); }
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final s = AppStrings.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(s.signOutConfirmTitle),
        content: Text(s.signOutConfirmBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s.cancel)),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(s.signOutLabel)),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    await AppSettingsScope.of(context).setSignedIn(value: false);
  }

  Future<void> _openSleepSettings() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(builder: (_) => SleepSettingsScreen(frame: _selectedFrame)),
    );
    if (mounted) await _loadDeviceToggles();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final app = AppSettingsScope.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(s.settingsTitle, style: TextStyle(fontWeight: FontWeight.bold, color: cs.onSurface)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _sectionHeader(s.settingsSectionAccount, cs),
          _buildGroup(cs, [
            _tile(
              context: context,
              icon: Icons.person_outline,
              title: s.account,
              subtitle: s.accountSub,
              onTap: () => Navigator.push<void>(
                context, MaterialPageRoute<void>(builder: (_) => const SettingsAccountScreen()),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          _sectionHeader(s.settingsSectionFrame, cs),
          _frameSelector(s),
          _buildGroup(cs, [
            _tile(
              context: context,
              icon: Icons.add_circle_outline,
              title: s.framePairing,
              subtitle: _pairingSubtitle(s),
              onTap: () async {
                await Navigator.push<void>(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const DeviceDiscoveryScreen(),
                  ),
                );
              },
            ),
_tile(
              context: context,
              icon: Icons.tune_rounded,
              title: s.frameProfileNavTitle,
              subtitle: s.frameProfileNavSub,
              onTap: () => Navigator.push<void>(
                context, MaterialPageRoute<void>(builder: (_) => FrameSettingsScreen(frame: _selectedFrame)),
              ),
            ),
            _divider(cs),
            _tile(
              context: context,
              icon: Icons.bedtime_outlined,
              title: s.sleepMode,
              subtitle: _sleepReady ? _sleepSubtitle(s) : '…',
              trailing: Switch.adaptive(
                value: _sleepEnabled,
                activeTrackColor: _red,
                onChanged: _sleepReady && !_savingDeviceSetting
                    ? (v) => unawaited(_onSleepToggle(v))
                    : null,
              ),
              onTap: _sleepEnabled ? _openSleepSettings : null,
            ),
            _divider(cs),
            _tile(
              context: context,
              icon: Icons.system_update_alt,
              title: s.otaFirmwareUpdate,
              subtitle: _otaReady ? _otaSubtitle(s) : '…',
              trailing: Switch.adaptive(
                value: _autoOtaEnabled,
                activeTrackColor: _red,
                onChanged: _otaReady && !_savingDeviceSetting
                    ? (v) => unawaited(_onOtaToggle(v))
                    : null,
              ),
              onTap: () => Navigator.push<void>(
                context, MaterialPageRoute<void>(builder: (_) => FirmwareScreen(frame: _selectedFrame)),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          _sectionHeader(s.settingsSectionApplication, cs),
          _buildGroup(cs, [
            _tile(
              context: context,
              icon: Icons.language,
              title: s.language,
              subtitle: _languageSubtitle(app, s),
              onTap: () => Navigator.push<void>(
                context, MaterialPageRoute<void>(builder: (_) => const SettingsLanguageScreen()),
              ),
            ),
            _tile(
              context: context,
              icon: Icons.tune,
              title: s.appPreferences,
              subtitle: s.appPreferencesSub,
              onTap: () => Navigator.push<void>(
                context, MaterialPageRoute<void>(builder: (_) => const SettingsAppPreferencesScreen()),
              ),
            ),
            if (FeatureFlags.enableAIFeatures) ...[
              _divider(cs),
              _tile(
                context: context,
                icon: Icons.auto_awesome,
                title: s.aiGenerateNavTitle,
                subtitle: s.aiGenerateSub,
                onTap: () => Navigator.push<void>(
                  context, MaterialPageRoute<void>(builder: (_) => const SettingsAiGenerateScreen()),
                ),
              ),
            ],
          ]),
          const SizedBox(height: 16),
          _sectionHeader(s.settingsSectionHelp, cs),
          _buildGroup(cs, [
            _tile(
              context: context,
              icon: Icons.help_outline,
              title: s.helpSettingsTitle,
              subtitle: s.helpSettingsSub,
              onTap: () => Navigator.push<void>(
                context, MaterialPageRoute<void>(builder: (_) => const SettingsHelpScreen()),
              ),
            ),
            _divider(cs),
            // _tile(
            //   context: context,
            //   icon: Icons.bug_report,
            //   title: 'Debug',
            //   subtitle: app.debugModeEnabled ? 'Debug mode active' : 'Enable debug features',
            //   onTap: () => Navigator.push<void>(
            //     context, MaterialPageRoute<void>(builder: (_) => const SettingsDebugScreen()),
            //   ),
            // ),
            // if (app.debugModeEnabled) ...[
            //   _divider(cs),
            //   _tile(
            //     context: context,
            //     icon: Icons.receipt_long_outlined,
            //     title: s.operationLog,
            //     subtitle: s.operationLogSub,
            //     onTap: () => Navigator.push<void>(
            //       context, MaterialPageRoute<void>(builder: (_) => const SettingsLogScreen()),
            //     ),
            //   ),
            // ],
          ]),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _confirmSignOut(context),
              icon: const Icon(Icons.logout),
              style: OutlinedButton.styleFrom(
                foregroundColor: cs.error,
                side: BorderSide(color: cs.error),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              label: Text(s.signOutLabel),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

Widget _sectionHeader(String title, ColorScheme cs) {
  return Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 6),
    child: Text(
      title,
      style: TextStyle(
        color: cs.primary,
        fontWeight: FontWeight.bold,
        fontSize: 13,
      ),
    ),
  );
}

Widget _buildGroup(ColorScheme cs, List<Widget> children) {
  return Container(
    decoration: BoxDecoration(
      color: cs.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: cs.outlineVariant, width: 0.5),
    ),
    child: Column(children: children),
  );
}

Widget _tile({
  required BuildContext context,
  required IconData icon,
  required String title,
  required String subtitle,
  Widget? trailing,
  VoidCallback? onTap,
}) {
  final cs = Theme.of(context).colorScheme;
  return ListTile(
    dense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    leading: Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: cs.primary, size: 18),
    ),
    title: Text(
      title,
      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface),
    ),
    subtitle: Text(
      subtitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
    ),
    trailing: trailing ?? Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
    onTap: onTap,
  );
}

Widget _divider(ColorScheme cs) => Divider(height: 1, indent: 48, endIndent: 12, color: cs.outlineVariant);


