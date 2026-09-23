import 'device_store.dart';
import 'device_settings_store.dart';

class OtaUpdateStore {
  OtaUpdateStore._(this.frame);
  final PairedFrame? frame;
  static OtaUpdateStore get instance => forFrame(DeviceStore.instance.cached);
  static final Map<String, OtaUpdateStore> _stores = {};
  static OtaUpdateStore forFrame(PairedFrame? f) => _stores.putIfAbsent(
    f == null ? '' : (DeviceStore.macForPairedFrame(f) ?? f.deviceId),
    () => OtaUpdateStore._(f),
  );
  bool enabled = false;
  Future<void> resolveForUi() async {
    if (frame == null) return;
    final cfg = await DeviceSettingsStore.instance.load(frame!);
    enabled = (cfg['ota'] as Map)['autoCheck'] == true;
  }

  Future<void> setEnabled(bool value) async {
    if (frame == null) return;
    await DeviceSettingsStore.instance.save(frame!, {
      'ota': {'autoCheck': value},
    });
    enabled = value;
  }
}
