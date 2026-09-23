import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/frame_playback_profile.dart';
import 'device_store.dart';
import 'device_settings_store.dart';
import 'frame_ble_mac_slug.dart';
import 'local_storage_service.dart';

/// Playback defaults belong to one frame, never the account-wide profile.
class FrameSettingsStore {
  FrameSettingsStore._();
  static final instance = FrameSettingsStore._();
  static const globalDisplaySecondsKey = 'global_display_seconds';
  static const globalPlaybackModeKey = 'global_playback_mode';
  static const globalDurationTypeKey = 'global_duration_type';
  Future<FramePlaybackProfile> load(PairedFrame? paired) async {
    if (paired == null) return const FramePlaybackProfile();
    final cfg = await DeviceSettingsStore.instance.load(paired);
    return FramePlaybackProfile.fromJson(
      Map<String, dynamic>.from(cfg['playbackProfile'] as Map),
    );
  }

  Future<void> save(PairedFrame? paired, FramePlaybackProfile profile) async {
    if (paired == null) return;
    final key = await LocalStorageService.instance.scopedKey(
      'frame_playback_profile_${frameBleMacSlug(paired)}',
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(profile.toJson()));
  }

  Future<void> pushProfileToFrame({
    required PairedFrame paired,
    required FramePlaybackProfile profile,
    String? userAuthToken,
  }) async {
    await DeviceSettingsStore.instance.save(paired, {
      'playbackProfile': {
        'intervalMinutes': profile.intervalMinutes,
        'strategy': profile.strategy,
        'idle': profile.idle,
        'durationHours': profile.durationHours,
      },
    });
    await save(paired, profile);
  }
}
