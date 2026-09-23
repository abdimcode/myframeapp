import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/api_config.dart';
import 'api_client.dart';
import 'device_store.dart';
import 'local_storage_service.dart';

/// Server-backed settings, cached independently by account and frame MAC.
class DeviceSettingsStore {
  DeviceSettingsStore._();
  static final instance = DeviceSettingsStore._();
  static Map<String, dynamic> defaults() => {
    'online': false,
    'sleepMode': {
      'enabled': false,
      'mode': 0,
      'beginTime': '23:00',
      'endTime': '07:00',
    },
    'playbackProfile': {
      'intervalMinutes': 10,
      'strategy': 1,
      'idle': 1,
      'durationHours': 6,
    },
    'ota': {'autoCheck': false},
  };
  Future<String> _key(String mac) =>
      LocalStorageService.instance.scopedKey('device_settings_v1_$mac');
  Future<Map<String, dynamic>> load(PairedFrame frame) async {
    final mac = DeviceStore.macForPairedFrame(frame);
    if (mac == null) return defaults();
    final prefs = await SharedPreferences.getInstance();
    final key = await _key(mac);
    Map<String, dynamic> cached = defaults();
    try {
      final raw = prefs.getString(key);
      if (raw != null) cached = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {}
    try {
      return await _request(mac, null);
    } catch (_) {
      return cached;
    }
  }

  Future<Map<String, dynamic>> save(
    PairedFrame frame,
    Map<String, dynamic> patch,
  ) => _request(DeviceStore.macForPairedFrame(frame)!, patch);
  Future<Map<String, dynamic>> _request(
    String mac,
    Map<String, dynamic>? patch,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = await _key(mac);
    final api = ApiClient(bearerToken: prefs.getString('settings_auth_token'));
    try {
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/device/$mac/settings');
      final res =
          await (patch == null ? api.get(uri) : api.put(uri, body: patch))
              .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        throw StateError('Settings request failed (${res.statusCode})');
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['ok'] != true ||
          data['sleepMode'] is! Map ||
          data['playbackProfile'] is! Map ||
          data['ota'] is! Map) {
        throw StateError('Invalid settings response');
      }
      await prefs.setString(key, jsonEncode(data));
      return data;
    } finally {
      api.close();
    }
  }
}
