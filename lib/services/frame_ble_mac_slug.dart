import 'device_store.dart';
import 'frame_mac_util.dart';

/// Stable key for slideshow APIs — stored `pairedFrameMac` when set.
String frameBleMacSlug(PairedFrame? p) {
  if (p == null) return 'FRAME';
  final stored = DeviceStore.macForPairedFrame(p);
  if (stored != null && stored.length == 12) return stored;
  final slug = FrameMacUtil.normalizeSlug(p.resolvedFrameTargetId);
  if (slug != null) return slug;
  return p.deviceId.replaceAll(RegExp(r'[^\w\-]'), '');
}
