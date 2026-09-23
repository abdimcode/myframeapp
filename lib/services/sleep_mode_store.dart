import 'package:flutter/material.dart';
import 'device_store.dart';
import 'device_settings_store.dart';

/// Each settings screen captures one frame-specific store instance.
class SleepModeStore {
  SleepModeStore._(this.frame);
  final PairedFrame? frame;
  static SleepModeStore get instance => forFrame(DeviceStore.instance.cached);
  static final Map<String, SleepModeStore> _stores = {};
  static SleepModeStore forFrame(PairedFrame? frame) => _stores.putIfAbsent(
    frame == null
        ? ''
        : (DeviceStore.macForPairedFrame(frame) ?? frame.deviceId),
    () => SleepModeStore._(frame),
  );
  static const defaultStart = TimeOfDay(hour: 23, minute: 0);
  static const defaultEnd = TimeOfDay(hour: 7, minute: 0);
  bool enabled = false;
  bool userPreferenceSet = false;
  TimeOfDay startTime = defaultStart;
  TimeOfDay endTime = defaultEnd;
  int? _timezoneOffset;
  bool _loaded = false;
  Future<void> ensureLoaded() async {
    if (!_loaded) await reload();
  }

  Future<void> resolveForUi() => reload();
  Future<void> reload() async {
    if (frame == null) return;
    final cfg = await DeviceSettingsStore.instance.load(frame!);
    final sleep = cfg['sleepMode'] as Map;
    enabled = sleep['enabled'] == true;
    startTime = _parse('${sleep['beginTime']}', defaultStart);
    endTime = _parse('${sleep['endTime']}', defaultEnd);
    _timezoneOffset = (sleep['timezoneOffsetMinutes'] as num?)?.toInt();
    _loaded = true;
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    userPreferenceSet = true;
  }

  Future<void> setSchedule({TimeOfDay? start, TimeOfDay? end}) async {
    startTime = start ?? startTime;
    endTime = end ?? endTime;
    userPreferenceSet = true;
  }

  Future<bool> pushConfigToFrame() async {
    final target = frame;
    if (target == null) return false;
    final patch = {
      'sleepMode': {
        'enabled': enabled,
        'mode': enabled ? 2 : 0,
        'beginTime': _hhmm(startTime),
        'endTime': _hhmm(endTime),
        'timezoneOffsetMinutes':
            _timezoneOffset ?? DateTime.now().timeZoneOffset.inMinutes,
      },
    };
    try {
      await DeviceSettingsStore.instance.save(target, patch);
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _hhmm(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  static TimeOfDay _parse(String text, TimeOfDay fallback) {
    final p = text.split(':');
    if (p.length != 2) return fallback;
    final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
    return h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59
        ? fallback
        : TimeOfDay(hour: h, minute: m);
  }
}
