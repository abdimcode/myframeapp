import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:myframe/services/device_settings_store.dart';
import 'package:myframe/services/device_store.dart';
import 'package:myframe/services/sleep_mode_store.dart';
import 'package:myframe/services/ota_update_store.dart';
import 'package:myframe/services/frame_settings_store.dart';
import 'package:myframe/services/frame_ble_mac_slug.dart';
import 'package:myframe/models/frame_playback_profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'sleep, OTA and playback save only to selected device; offline cache survives',
    () async {
      SharedPreferences.setMockInitialValues({
        'settings_auth_token': 'owner',
        'settings_auth_user_id': 'owner',
      });
      const a = PairedFrame(deviceId: 'D0CF13E0361A');
      const b = PairedFrame(deviceId: 'D0CF13F0161E');
      await DeviceStore.instance.savePairedFrameMac(a.deviceId);
      expect(frameBleMacSlug(b), b.deviceId);
      final records = <String, Map<String, dynamic>>{
        a.deviceId: DeviceSettingsStore.defaults(),
        b.deviceId: DeviceSettingsStore.defaults(),
      };
      final puts = <String>[];
      var disconnected = false;
      await http.runWithClient(
        () async {
          final sa = SleepModeStore.forFrame(a),
              sb = SleepModeStore.forFrame(b);
          await Future.wait([sa.resolveForUi(), sb.resolveForUi()]);
          await sa.setEnabled(true);
          await sa.setSchedule(
            start: const TimeOfDay(hour: 23, minute: 0),
            end: const TimeOfDay(hour: 7, minute: 0),
          );
          expect(await sa.pushConfigToFrame(), true);
          expect(sb.enabled, false);
          expect(records[b.deviceId]!['sleepMode']['enabled'], false);
          await OtaUpdateStore.forFrame(a).setEnabled(true);
          expect(records[b.deviceId]!['ota']['autoCheck'], false);
          await FrameSettingsStore.instance.pushProfileToFrame(
            paired: b,
            profile: const FramePlaybackProfile(
              intervalMinutes: 5,
              playbackMode: 'random',
              idle: 0,
            ),
          );
          expect(
            records[a.deviceId]!['playbackProfile']['intervalMinutes'],
            10,
          );
          expect(records[b.deviceId]!['playbackProfile']['idle'], 0);
          expect(puts, [a.deviceId, a.deviceId, b.deviceId]);
          disconnected = true;
          final cached = await DeviceSettingsStore.instance.load(b);
          expect(cached['playbackProfile']['intervalMinutes'], 5);
          expect(cached['sleepMode']['enabled'], false);
        },
        () => MockClient((request) async {
          if (disconnected) throw http.ClientException('offline');
          expect(request.headers['authorization'], 'Bearer owner');
          final mac = request.url.pathSegments[2];
          if (request.method == 'PUT') {
            puts.add(mac);
            records[mac]!.addAll(
              jsonDecode(request.body) as Map<String, dynamic>,
            );
          }
          return http.Response(
            jsonEncode({'ok': true, 'mac': mac, ...records[mac]!}),
            200,
          );
        }),
      );
    },
  );
}
