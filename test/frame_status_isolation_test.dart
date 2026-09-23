import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:myframe/services/device_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myframe/services/frame_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('non-active frame never uses the global active MAC', () async {
    SharedPreferences.setMockInitialValues({});
    await DeviceStore.instance.savePairedFrameMac('D0CF13E0361A');
    const messi = PairedFrame(deviceId: 'D0CF13F0161E');
    expect(DeviceStore.macForPairedFrame(messi), 'D0CF13F0161E');
    expect(messi.resolvedFrameTargetId, 'D0CF13F0161E');
    expect(DeviceStore.statusMacCandidates(messi), ['D0CF13F0161E']);
    expect(messi.resolvedFrameUploadTargets, ['D0CF13F0161E']);
  });
  test('cached online status expires while retaining last known telemetry', () {
    final status = FrameStatus.fromJson({
      'device_id': 'AABBCCDDEE01', 'online': true, 'status': 'online',
      'last_seen_ms': DateTime.now().millisecondsSinceEpoch - 120001,
      'online_grace_ms': 120000, 'battery': 87, 'wifi': 'Remela',
    });
    expect(status.isEffectivelyOnline, isFalse);
    expect(status.battery, 87);
    expect(status.wifiSsid, 'Remela');
  });
  test('concurrent device requests and cache preserve independent readings', () async {
    final api = FrameApiClient(httpClient: MockClient((request) async {
      final mac = request.url.pathSegments[2];
      final messi = mac == 'AABBCCDDEE01';
      await Future<void>.delayed(Duration(milliseconds: messi ? 20 : 1));
      return http.Response(jsonEncode({
        'ok': true, 'device_id': mac, 'online': !messi,
        'status': messi ? 'offline' : 'online',
        'battery': messi ? 87 : 10, 'wifi': messi ? 'Remela' : 'TP-Link_B970',
        'last_seen_ms': DateTime.now().millisecondsSinceEpoch - (messi ? 180000 : 1000),
        'online_grace_ms': 120000,
      }), 200);
    }));
    final results = await Future.wait([
      api.fetchFrameStatus(mac: 'AA:BB:CC:DD:EE:01', force: true),
      api.fetchFrameStatus(mac: 'AA:BB:CC:DD:EE:02', force: true),
    ]);
    expect(results[0]!.battery, 87);
    expect(results[0]!.isEffectivelyOnline, isFalse);
    expect(results[1]!.battery, 10);
    expect(results[1]!.isEffectivelyOnline, isTrue);
    expect((await api.fetchFrameStatus(mac: 'AABBCCDDEE01'))!.wifiSsid, 'Remela');
    api.close();
  });
}
