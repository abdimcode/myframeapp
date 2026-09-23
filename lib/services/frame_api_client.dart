import 'playlist_image_compressor.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../config/vps_defaults.dart';
import 'api_client.dart';

class FrameStatus {
  FrameStatus({
    required this.deviceId,
    required this.online,
    this.sleeping = false,
    this.isNetworkSleeping = false,
    this.status = 'unknown',
    this.battery = 100,
    this.wifiSsid = '',
    this.storageUsedMb = 0,
    this.storageTotalMb = 32000,
    this.photoCount = 0,
    this.mqttConnected = false,
    this.lastSeenMs,
    this.onlineGraceMs = 900000,
    this.lastUploadMs,
    this.firmwareVersion,
    this.hasUpdate = false,
    this.latestVersion,
    this.provisioning = false,
    this.appPaired = false,
    this.sleepStart,
    this.sleepEnd,
    this.wifiRssi,
    this.isCharging,
    this.sdCardMounted,
    this.sdCardTotalMb,
    this.sdCardFreeMb,
    this.countryCode,
    this.timezone,
    this.timezoneOffsetMinutes,
    this.deliveryStatus,
    this.deliveryTotal,
    this.deliveryDownloaded,
    this.deliveryFailed,
    this.deliveryUpdatedAtMs,
    this.deliveryStoppedAtMs,
    this.deliveryAckMsgid,
  });

  final String deviceId;
  final bool online;
  final bool sleeping;
  /// Frame Wi-Fi is powered down inside its configured sleep/offline window.
  final bool isNetworkSleeping;
  final String status;
  final int battery;
  final String wifiSsid;
  final int storageUsedMb;
  final int storageTotalMb;
  final int photoCount;
  final bool mqttConnected;
  final int? lastSeenMs;
  final int onlineGraceMs;
  final int? lastUploadMs;
  final String? firmwareVersion;
  /// True when the backend reports an OTA firmware update is available.
  final bool hasUpdate;
  final String? latestVersion;
  final String? deliveryStatus;
  final int? deliveryTotal;
  final int? deliveryDownloaded;
  final int? deliveryFailed;
  final int? deliveryUpdatedAtMs;
  final int? deliveryStoppedAtMs;
  final String? deliveryAckMsgid;

  /// True when the backend reports the frame is provisioned but hasn't sent
  /// its first MQTT heartbeat yet (post-BluFi grace window). Clients should
  /// keep polling during this state instead of flashing "Frame not paired".
  final bool provisioning;
  /// True when the frame has a DB record (paired in the app account).
  final bool appPaired;
  /// Configured sleep window (LOCAL HH:mm) for the wake-up subtext.
  final String? sleepStart;
  final String? sleepEnd;
  /// Live Wi-Fi RSSI (dBm) reported by the device.
  final int? wifiRssi;
  /// Battery charging state reported by the device (is_charging).
  final bool? isCharging;
  /// SD card mount state + capacity reported by the device.
  final bool? sdCardMounted;
  final int? sdCardTotalMb;
  final int? sdCardFreeMb;
  final String? countryCode;
  final String? timezone;
  final int? timezoneOffsetMinutes;

  /// True when the frame confirmed the playlist/slideshow was halted.
  bool get isStopped => deliveryStatus == 'stopped';

  double get batteryFraction => (battery / 100).clamp(0.0, 1.0);
  double get storageFraction => storageTotalMb > 0
      ? (storageUsedMb / storageTotalMb).clamp(0.0, 1.0)
      : 0.0;
  String get storageUsedFormatted =>
      '${(storageUsedMb / 1024).toStringAsFixed(1)} GB';
  String get storageTotalFormatted =>
      '${(storageTotalMb / 1024).toStringAsFixed(1)} GB';

  String? get lastSeenFormatted {
    final ms = lastSeenMs;
    if (ms == null || ms <= 0) return null;
    final dt =
        DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  factory FrameStatus.fromJson(Map<String, dynamic> json) {
    final status = json['status'] as String? ?? 'unknown';
    final sleeping = json['sleeping'] == true || status == 'sleeping';
    // Prefer explicit online; a fresh heartbeat (online) or sleeping count as
    // connected for the UI. An "idle"/"offline"/"unknown" frame (heartbeat gap
    // beyond the online window) is treated as OFFLINE so a frame that lost
    // Wi-Fi no longer keeps showing "online".
    final onlineRaw = json['online'] == true;
    final reachable = json['reachable'] == true;
    final online = onlineRaw ||
        reachable ||
        status == 'online' ||
        status == 'sleeping';
    return FrameStatus(
      deviceId: json['device_id'] as String? ?? '',
      online: online && status != 'offline',
      sleeping: sleeping,
      isNetworkSleeping:
          json['isNetworkSleeping'] == true || json['is_network_sleeping'] == true,
      status: status,
      battery: json['battery'] as int? ?? 100,
      wifiSsid: json['wifi'] as String? ?? '',
      storageUsedMb: json['storage_used_mb'] as int? ?? 0,
      storageTotalMb: json['storage_total_mb'] as int? ?? 32000,
      photoCount: json['photo_count'] as int? ?? 0,
      mqttConnected: json['mqtt_connected'] == true || reachable,
      lastSeenMs: json['last_seen_ms'] as int?,
      onlineGraceMs: (json['online_grace_ms'] as num?)?.toInt() ?? 900000,
      lastUploadMs: json['last_upload_ms'] as int?,
      firmwareVersion: json['firmwareVersion'] as String?,
      hasUpdate: (json['ota'] as Map<String, dynamic>?)?['hasUpdate'] == true,
      latestVersion: (json['ota'] as Map<String, dynamic>?)?['latestVersion'] as String?,
      provisioning: json['provisioning'] == true,
      appPaired: json['app_paired'] == true,
      sleepStart: json['sleep_start'] as String?,
      sleepEnd: json['sleep_end'] as String?,
      wifiRssi: (json['wifi_rssi'] ?? json['wifi_signal_dbm']) as int?,
      isCharging: json['is_charging'] as bool?,
      sdCardMounted:
          json['sd_card']?['mounted'] as bool? ?? json['sdcard_mounted'] as bool?,
      sdCardTotalMb:
          json['sd_card']?['total_mb'] as int? ?? json['sdcard_total_mb'] as int?,
      sdCardFreeMb:
          json['sd_card']?['free_mb'] as int? ?? json['sdcard_free_mb'] as int?,
      countryCode: json['country_code'] as String?,
      timezone: json['timezone'] as String?,
      timezoneOffsetMinutes: json['timezone_offset_minutes'] as int?,
      deliveryStatus: json['delivery_status'] as String?,
      deliveryTotal: json['delivery_total'] as int?,
      deliveryDownloaded: json['delivery_downloaded'] as int?,
      deliveryFailed: json['delivery_failed'] as int?,
      deliveryUpdatedAtMs: json['delivery_updated_at_ms'] as int?,
      deliveryStoppedAtMs: json['delivery_stopped_at_ms'] as int?,
      deliveryAckMsgid: json['delivery_ack_msgid'] as String?,
    );
  }

  /// User-facing connection label key.
  bool get isEffectivelyOnline {
    if (!online && !sleeping) return false;
    final seen = lastSeenMs;
    if (seen == null || seen <= 0) return false;
    final age = DateTime.now().millisecondsSinceEpoch - seen;
    return age >= 0 && age < onlineGraceMs;
  }
}

class _CachedFrameStatus {
  _CachedFrameStatus({required this.status, required this.timestamp});
  final FrameStatus status;
  final int timestamp;
}

/// Logical context for an upload. Mirrors the backend `uploads.source`
/// field so the server can apply playlist/personal_album isolation when
/// serving the user's photo gallery.
enum UploadSource {
  /// Saved into the user's Personal Album (Personal Gallery).
  personalAlbum('personal_album'),

  /// Sent as part of a named playlist — should NOT appear in Personal.
  playlist('playlist'),

  /// Single quick cast — should NOT appear in Personal.
  directCast('direct_cast'),

  /// Uploaded by a guest via an invite link.
  guestInvite('guest_invite'),

  /// Generated by AI silent mode.
  aiGenerated('ai_generated');

  const UploadSource(this.value);
  final String value;

  String get wireName => value;

  static UploadSource fromWire(String? raw) {
    switch (raw) {
      case 'personal_album':
        return UploadSource.personalAlbum;
      case 'playlist':
        return UploadSource.playlist;
      case 'guest_invite':
        return UploadSource.guestInvite;
      case 'ai_generated':
        return UploadSource.aiGenerated;
      case 'direct_cast':
      default:
        return UploadSource.directCast;
    }
  }
}

class FrameApiClient {
  FrameApiClient({http.Client? httpClient, this.defaultTimeout = const Duration(seconds: 60)})
      : _api = ApiClient(inner: httpClient);

  /// Bumped whenever a frame's live status changes in a user-visible way (e.g.
  /// sleep toggled OFF) so the Home / Device-Detail screens can refresh their
  /// status without an app restart or a 30s poll.
  static final ValueNotifier<int> frameStatusRevision = ValueNotifier<int>(0);

  final ApiClient _api;
  final Duration defaultTimeout;

/// POST /api/frames/{MAC}/upload — multipart, matches WeChat mini app endpoint.
/// [baseUrlOverride] — e.g. LAN URL from pairing QR (`http://192.168.x.x:8080`).
Future<PhotoUploadResponse> uploadPhoto({
    required Uint8List fileBytes,
    required String filename,
    required String deviceId,
    String? baseUrlOverride,
    String? slideshowStyle,
    int? displaySeconds,
    String? transport,
    String? pairingToken,
    String? userAuthToken,
    Duration? timeout,
    bool skipPlay = false,
    String? editsJson,
    UploadSource source = UploadSource.directCast,
    String? playlistId,
    String? albumId,
    String? displayName,
  }) async {
    if (source == UploadSource.playlist) {
      // Compress playlist photos (max 1600px, <500 KB). If the compressor can't
      // decode this format (e.g. an exotic camera/HEIC variant), DO NOT abort
      // the whole playlist — upload the original bytes and let the server
      // normalize/encode them instead.
      try {
        fileBytes = await compressPlaylistImage(fileBytes);
        filename = filename.replaceFirst(RegExp(r'\.[^.]+$'), '') + '.jpg';
      } catch (e) {
        debugPrint('[Upload] playlist compress skipped (uploading original): $e');
      }
    }
    final checksum = sha256.convert(fileBytes).toString();
    final effectiveTimeout = timeout ?? defaultTimeout;
    final bases = _candidateBases(baseUrlOverride);
    Object? lastErr;
    
    // Clean MAC address (remove prefixes, keep last 12 hex chars)
    final cleanMac = deviceId.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    final macSlug = cleanMac.length >= 12 ? cleanMac.substring(cleanMac.length - 12) : cleanMac;
    
    for (final base in bases) {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final uri = Uri.parse('$base/api/frames/$macSlug/upload');
          final request = http.MultipartRequest('POST', uri)
            ..fields['mac'] = macSlug
            ..fields['device_id'] = deviceId
            ..fields['checksum'] = checksum
            ..fields['size'] = '${fileBytes.length}'
            ..fields['app_platform'] = 'flutter'
              ..fields.addAll({
                if (slideshowStyle != null && slideshowStyle.isNotEmpty) 'slideshow_style': slideshowStyle,
                if (displaySeconds != null && displaySeconds > 0)
                  'display_seconds': '$displaySeconds',
                if (transport != null && transport.isNotEmpty) 'transport': transport,
                if (skipPlay) 'skip_play': 'true',
                // Requires the matching server notification guard; see docs/playlist-notifications.md.
                if (source == UploadSource.playlist) 'silent': 'true',
                if (editsJson != null && editsJson.isNotEmpty) 'edits': editsJson,
                // Source isolation: tag the upload with its logical context
                // (personal_album | playlist | direct_cast | guest_invite |
                // ai_generated) so the backend can apply playlist/personal
                // isolation when serving the user's photo gallery.
                'source': source.wireName,
                if (playlistId != null && playlistId.isNotEmpty) 'playlist_id': playlistId,
                if (albumId != null && albumId.isNotEmpty) 'album_id': albumId,
                if (displayName != null && displayName.isNotEmpty) 'display_name': displayName,
              })
            ..files.add(
              http.MultipartFile.fromBytes(
                'photo',  // Server expects 'photo' field for /api/frames/{MAC}/upload
                fileBytes,
                filename: filename,
              ),
            );
          if (pairingToken != null && pairingToken.trim().isNotEmpty) {
            request.headers['x-pairing-token'] = pairingToken.trim();
          }
          final bearer = userAuthToken?.trim() ?? '';
          if (bearer.isNotEmpty) {
            request.headers['Authorization'] = 'Bearer $bearer';
          }

          final res = await _api.send(request).timeout(
                effectiveTimeout,
                onTimeout: () => throw TimeoutException('POST /api/photo/upload', effectiveTimeout),
              );
          final body = res.body;
          if (res.statusCode < 200 || res.statusCode >= 300) {
            throw FrameApiException(res.statusCode, body);
          }
          final json = jsonDecode(body) as Map<String, dynamic>;
          return PhotoUploadResponse.fromJson(json);
        } catch (e) {
          lastErr = e;
          final shouldRetry = _isTransient(e);
          final hasNextAttempt = attempt == 0;
          if (!shouldRetry || !hasNextAttempt) break;
          await Future<void>.delayed(Duration(milliseconds: 300 * (1 << attempt)));
        }
      }
    }
    if (lastErr is FrameApiException) throw lastErr;
    if (lastErr is TimeoutException) throw lastErr;
    if (lastErr is SocketException) throw lastErr;
    throw Exception('Upload failed after retries: $lastErr');
  }

  /// POST /api/frames/{MAC}/cast/batch — unified multi-image direct cast.
  ///
  /// After the share extension / share intent has uploaded a batch of photos,
  /// call this to trigger an immediate device-side rotation. The backend:
  ///   1. Verifies every photo_id exists in the upload store.
  ///   2. Publishes `strategy_bin` so the device fetches the manifest.
  ///   3. Immediately publishes `play` for photo_ids[0] so the device
  ///      renders the first shared image right away (no waiting on the
  ///      first interval tick).
  ///   4. Persists a transient slideshow marker (source='direct_cast') so
  ///      subsequent status polls reflect the active manifest.
  ///
  /// This endpoint is the dedicated, reliable fix for the system-share
  /// multi-image flow that previously closed before the device received
  /// its first rotation.
  Future<Map<String, dynamic>> castMultiplePhotos({
    required String deviceId,
    required List<String> photoIds,
    int? intervalMinutes,
    int? intervalSeconds,
    String intervalUnit = 'minute',
    int strategy = 1,
    int idle = 1,
    bool immediatePlay = true,
    String source = 'direct_cast',
    String? baseUrlOverride,
    String? pairingToken,
    String? userAuthToken,
    Duration? timeout,
  }) async {
    if (photoIds.isEmpty) {
      throw ArgumentError('photoIds cannot be empty');
    }
    final cleanMac = deviceId.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    final macSlug = cleanMac.length >= 12
        ? cleanMac.substring(cleanMac.length - 12)
        : cleanMac;
    final effectiveTimeout = timeout ?? defaultTimeout;
    final base = _base(baseUrlOverride);
    final uri = Uri.parse('$base/api/frames/$macSlug/cast/batch');

    // Interval unit normalisation: prefer `intervalSeconds` when provided.
    int finalIntervalMinutes = intervalMinutes ?? 10;
    String finalIntervalUnit = intervalUnit;
    if (intervalSeconds != null && intervalSeconds > 0) {
      finalIntervalMinutes = (intervalSeconds / 60).ceil();
      finalIntervalUnit = 'second';
    }
    if (finalIntervalMinutes < 1) finalIntervalMinutes = 1;

    final body = <String, dynamic>{
      'photo_ids': photoIds,
      'intervalMinutes': finalIntervalMinutes,
      'intervalUnit': finalIntervalUnit,
      'strategy': strategy,
      'idle': idle,
      'immediatePlay': immediatePlay,
      'source': source,
    };

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final bearer = userAuthToken?.trim() ?? '';
    if (bearer.isNotEmpty) headers['Authorization'] = 'Bearer $bearer';
    final pt = pairingToken?.trim() ?? '';
    if (pt.isNotEmpty) headers['x-pairing-token'] = pt;

    final res = await _api
        .post(uri, headers: headers, body: jsonEncode(body))
        .timeout(effectiveTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw FrameApiException(res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// POST `/api/v1/frames/:mac/push` — register an async image push job.
  ///
  /// Non-blocking: returns `{ msgid, status: "queued", progress }` immediately;
  /// the client polls [fetchPushStatus] to observe queued (0) -> dispatched
  /// (0.30) -> downloaded (0.65) -> completed (1.00) or timeout_failed.
  Future<Map<String, dynamic>> pushToFrame({
    required String deviceId,
    required String type,
    required List<Map<String, String>> imgs,
    String? pairingToken,
    String? userAuthToken,
    String? baseUrlOverride,
    Duration? timeout,
  }) async {
    final cleanMac = deviceId.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    final macSlug = cleanMac.length >= 12
        ? cleanMac.substring(cleanMac.length - 12)
        : cleanMac;
    final t = timeout ?? const Duration(seconds: 12);
    final base = _base(baseUrlOverride);
    final uri = Uri.parse('$base/api/v1/frames/$macSlug/push');

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final bearer = userAuthToken?.trim() ?? '';
    if (bearer.isNotEmpty) headers['Authorization'] = 'Bearer $bearer';
    final pt = pairingToken?.trim() ?? '';
    if (pt.isNotEmpty) headers['x-pairing-token'] = pt;

    final res = await _api
        .post(
          uri,
          headers: headers,
          body: jsonEncode({'type': type, 'imgs': imgs}),
        )
        .timeout(t, onTimeout: () => throw TimeoutException('POST /push', t));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw FrameApiException(res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// GET `/api/v1/frames/:mac/push-status?msgid=...` — poll a push job.
  Future<Map<String, dynamic>?> fetchPushStatus({
    required String deviceId,
    required String msgid,
    String? pairingToken,
    String? userAuthToken,
    String? baseUrlOverride,
    Duration? timeout,
  }) async {
    final cleanMac = deviceId.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    final macSlug = cleanMac.length >= 12
        ? cleanMac.substring(cleanMac.length - 12)
        : cleanMac;
    final t = timeout ?? const Duration(seconds: 8);
    final base = _base(baseUrlOverride);
    final uri = Uri.parse(
      '$base/api/v1/frames/$macSlug/push-status?msgid=${Uri.encodeComponent(msgid)}',
    );

    final headers = <String, String>{'Accept': 'application/json'};
    final bearer = userAuthToken?.trim() ?? '';
    if (bearer.isNotEmpty) headers['Authorization'] = 'Bearer $bearer';
    final pt = pairingToken?.trim() ?? '';
    if (pt.isNotEmpty) headers['x-pairing-token'] = pt;

    try {
      final res = await _api.get(uri, headers: headers).timeout(t);
      if (res.statusCode != 200) return null;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      return json['ok'] == true ? json : null;
    } catch (_) {
      return null;
    }
  }

  /// Quick reachability check before a large upload (optional).
  Future<Map<String, dynamic>> getDeviceStatus({
    String? baseUrlOverride,
    String? pairingToken,
    Duration? timeout,
  }) async {
    final t = timeout ?? const Duration(seconds: 8);
    Object? lastErr;
    for (final base in _candidateBases(baseUrlOverride)) {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final res = await _api
              .get(
                Uri.parse('$base/api/device/status'),
                headers: pairingToken != null && pairingToken.trim().isNotEmpty
                    ? {'x-pairing-token': pairingToken.trim()}
                    : null,
              )
              .timeout(t, onTimeout: () => throw TimeoutException('GET /api/device/status', t));
          if (res.statusCode != 200) {
            throw FrameApiException(res.statusCode, res.body);
          }
          return jsonDecode(res.body) as Map<String, dynamic>;
        } catch (e) {
          lastErr = e;
          if (!_isTransient(e) || attempt == 1) break;
          await Future<void>.delayed(Duration(milliseconds: 250 * (1 << attempt)));
        }
      }
    }
    if (lastErr is FrameApiException) throw lastErr;
    if (lastErr is TimeoutException) throw lastErr;
    if (lastErr is SocketException) throw lastErr;
    throw Exception('Status check failed after retries: $lastErr');
  }

  /// GET `/api/frames/:mac/status` — full device metrics (battery, storage, wifi, etc.).
  static final Map<String, _CachedFrameStatus> _statusCache = {};

  Future<FrameStatus?> fetchFrameStatus({
    required String mac,
    String? baseUrlOverride,
    String? pairingToken,
    Duration? timeout,
    bool force = false,
  }) async {
    final cleanMac = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    if (cleanMac.length < 12) return null;
    final slug = cleanMac.substring(cleanMac.length - 12);
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _statusCache[slug];
    if (!force && cached != null && (now - cached.timestamp < 30000)) {
      return cached.status;
    }
    final t = timeout ?? const Duration(seconds: 8);
    final bases = _frameStatusCandidateBases(baseUrlOverride);
    for (final base in bases) {
      try {
        final uri = Uri.parse('$base/api/frames/$slug/status');
        final res = await _api
            .get(
              uri,
              headers: pairingToken != null && pairingToken.trim().isNotEmpty
                  ? {'x-pairing-token': pairingToken.trim()}
                  : null,
            )
            .timeout(t);
        if (res.statusCode != 200) continue;
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        if (json['ok'] != true) continue;
        final status = FrameStatus.fromJson(json);
        _statusCache[slug] = _CachedFrameStatus(status: status, timestamp: now);
        return status;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Drop the cached status for [mac] so the next [fetchFrameStatus] re-queries
  /// the backend (used after a sleep toggle-off to show fresh telemetry), and
  /// notify listeners that a frame's status changed.
  void invalidateStatusCache(String mac, {bool notify = true}) {
    final cleanMac = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    if (cleanMac.length >= 12) {
      _statusCache.remove(cleanMac.substring(cleanMac.length - 12));
    }
    if (notify) frameStatusRevision.value++;
  }

  /// POST `/api/frames/:mac/sleep-config` — persist sleep mode. When `enabled`
  /// is false the backend immediately clears the sleep lock, publishes a wake +
  /// `update_config` (request_telemetry) to the frame, and responds with the
  /// fresh live status so clients can flip to "Online" instantly.
  Future<Map<String, dynamic>?> saveSleepConfig({
    required String mac,
    required bool enabled,
    required String startTime,
    required String endTime,
    int? timezoneOffsetMinutes,
    String? pairingToken,
    String? userAuthToken,
    Duration? timeout,
  }) async {
    final cleanMac = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    if (cleanMac.length < 12) return null;
    final slug = cleanMac.substring(cleanMac.length - 12);
    final t = timeout ?? const Duration(seconds: 12);
    final base = _base(null);
    final uri = Uri.parse('$base/api/frames/$slug/sleep-config');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final bearer = userAuthToken?.trim() ?? '';
    if (bearer.isNotEmpty) headers['Authorization'] = 'Bearer $bearer';
    try {
      final res = await _api
          .post(
            uri,
            headers: headers,
            body: jsonEncode({
              'enabled': enabled,
              'startTime': startTime,
              'endTime': endTime,
              'timezoneOffsetMinutes': timezoneOffsetMinutes ?? DateTime.now().timeZoneOffset.inMinutes,
            }),
          )
          .timeout(t);
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      return json['ok'] == true ? json : null;
    } catch (_) {
      return null;
    }
  }

  /// GET `/api/frames/:mac/firmware` — dynamic firmware version + OTA availability.
  Future<FirmwareInfo?> fetchFirmware({
    required String mac,
    String? pairingToken,
    Duration? timeout,
  }) async {
    final cleanMac = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    if (cleanMac.length < 12) return null;
    final slug = cleanMac.substring(cleanMac.length - 12);
    final t = timeout ?? const Duration(seconds: 8);
    for (final base in _frameStatusCandidateBases(null)) {
      try {
        final uri = Uri.parse('$base/api/frames/$slug/firmware');
        final res = await _api
            .get(
              uri,
              headers: pairingToken != null && pairingToken.trim().isNotEmpty
                  ? {'x-pairing-token': pairingToken.trim()}
                  : null,
            )
            .timeout(t);
        if (res.statusCode != 200) continue;
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        if (json['ok'] != true) continue;
        return FirmwareInfo.fromJson(json);
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// POST `/api/frames/:mac/firmware/update` — trigger an OTA firmware update.
  ///
  /// Returns `true` when the server accepted the request and published the OTA
  /// MQTT payload. Returns `false` on network error, `FRAME_OFFLINE` (409), or
  /// an already-up-to-date response.
  Future<bool> triggerFirmwareUpdate({
    required String mac,
    String? pairingToken,
    Duration? timeout,
  }) async {
    final cleanMac = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    if (cleanMac.length < 12) return false;
    final slug = cleanMac.substring(cleanMac.length - 12);
    final t = timeout ?? const Duration(seconds: 12);
    final headers = <String, String>{'Content-Type': 'application/json'};
    final tok = pairingToken ?? VpsDefaults.pairingToken;
    if (tok.trim().isNotEmpty) headers['x-pairing-token'] = tok.trim();
    for (final base in _frameStatusCandidateBases(null)) {
      try {
        final res = await _api
            .post(Uri.parse('$base/api/frames/$slug/firmware/update'),
                headers: headers)
            .timeout(t);
        if (res.statusCode == 200) {
          final json = jsonDecode(res.body) as Map<String, dynamic>;
          return json['ok'] == true;
        }
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  /// POST `/api/frames/:mac/auto-update` — persist the user's auto-update
  /// preference for this frame.
  Future<bool> toggleAutoUpdate({
    required String mac,
    required bool enabled,
    String? pairingToken,
    Duration? timeout,
  }) async {
    final cleanMac = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    if (cleanMac.length < 12) return false;
    final slug = cleanMac.substring(cleanMac.length - 12);
    final t = timeout ?? const Duration(seconds: 8);
    final headers = <String, String>{'Content-Type': 'application/json'};
    final tok = pairingToken ?? VpsDefaults.pairingToken;
    if (tok.trim().isNotEmpty) headers['x-pairing-token'] = tok.trim();
    final body = jsonEncode({'enabled': enabled});
    for (final base in _frameStatusCandidateBases(null)) {
      try {
        final res = await _api
            .post(Uri.parse('$base/api/frames/$slug/auto-update'),
                headers: headers, body: body)
            .timeout(t);
        if (res.statusCode == 200) {
          final json = jsonDecode(res.body) as Map<String, dynamic>;
          return json['ok'] == true;
        }
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  /// POST `/api/frames/:mac/mqtt-command` — relay an app-issued MQTT command
  /// (e.g. `wifi_sleep`) to the frame per the firmware protocol and
  /// return the server's send + ack result.
  Future<Map<String, dynamic>> sendFrameCommand({
    required String mac,
    required String action,
    required Map<String, dynamic> data,
    String? pairingToken,
    String? baseUrlOverride,
    Duration? timeout,
  }) async {
    final cleanMac = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    final slug = cleanMac.length >= 12
        ? cleanMac.substring(cleanMac.length - 12)
        : cleanMac;
    final t = timeout ?? const Duration(seconds: 10);
    final headers = <String, String>{'Content-Type': 'application/json'};
    final tok = pairingToken ?? VpsDefaults.pairingToken;
    if (tok.trim().isNotEmpty) headers['x-pairing-token'] = tok.trim();
    final body = jsonEncode({
      'action': action,
      'msgid': DateTime.now().millisecondsSinceEpoch.toString(),
      'data': data,
    });
    for (final base in _frameStatusCandidateBases(baseUrlOverride)) {
      try {
        final res = await _api
            .post(Uri.parse('$base/api/frames/$slug/mqtt-command'),
                headers: headers, body: body)
            .timeout(t);
        if (res.statusCode == 200) {
          return jsonDecode(res.body) as Map<String, dynamic>;
        }
      } catch (_) {}
    }
    return {'ok': false, 'sent': false, 'error': 'relay_unreachable'};
  }

  /// GET `/api/frames/:mac/status` — MQTT/display confirmation (works when
  /// `delivery-status` never flips `delivered_to_frame` on iOS uploads).
  Future<FrameCastStatusResponse> getFrameCastStatus({
    required String mac,
    String? baseUrlOverride,
    Duration? timeout,
  }) async {
    final cleanMac = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    if (cleanMac.length < 12) {
      throw ArgumentError('Frame MAC must be 12 hex digits');
    }
    final slug = cleanMac.substring(cleanMac.length - 12);
    final t = timeout ?? const Duration(seconds: 8);
    Object? lastErr;
    for (final base in _frameStatusCandidateBases(baseUrlOverride)) {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final uri = Uri.parse('$base/api/frames/$slug/status');
          final res = await _api
              .get(uri)
              .timeout(t, onTimeout: () => throw TimeoutException('GET /api/frames/$slug/status', t));
          if (res.statusCode != 200) {
            throw FrameApiException(res.statusCode, res.body);
          }
          return FrameCastStatusResponse.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
        } catch (e) {
          lastErr = e;
          if (!_isTransient(e) || attempt == 1) break;
          await Future<void>.delayed(Duration(milliseconds: 250 * (1 << attempt)));
        }
      }
    }
    if (lastErr is FrameApiException) throw lastErr;
    if (lastErr is TimeoutException) throw lastErr;
    if (lastErr is SocketException) throw lastErr;
    throw Exception('Frame status failed after retries: $lastErr');
  }

  Future<DeliveryStatusResponse> getDeliveryStatus({
    required String checksumSha256,
    required String deviceId,
    String? baseUrlOverride,
    String? pairingToken,
    Duration? timeout,
  }) async {
    final t = timeout ?? const Duration(seconds: 8);
    Object? lastErr;
    for (final base in _candidateBases(baseUrlOverride)) {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final uri = Uri.parse('$base/api/photo/delivery-status')
              .replace(queryParameters: {'checksum': checksumSha256, 'device_id': deviceId});
          final res = await _api
              .get(
                uri,
                headers: pairingToken != null && pairingToken.trim().isNotEmpty
                    ? {'x-pairing-token': pairingToken.trim()}
                    : null,
              )
              .timeout(t, onTimeout: () => throw TimeoutException('GET /api/photo/delivery-status', t));
          if (res.statusCode != 200) {
            throw FrameApiException(res.statusCode, res.body);
          }
          return DeliveryStatusResponse.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
        } catch (e) {
          lastErr = e;
          if (!_isTransient(e) || attempt == 1) break;
          await Future<void>.delayed(Duration(milliseconds: 250 * (1 << attempt)));
        }
      }
    }
    if (lastErr is FrameApiException) throw lastErr;
    if (lastErr is TimeoutException) throw lastErr;
    if (lastErr is SocketException) throw lastErr;
    throw Exception('Delivery status failed after retries: $lastErr');
  }

  /// HTTP republish fallback — re-publishes MQTT play command when delivery fails.
  /// Endpoint: POST /api/device/send
  /// Used when MQTT publish failed or frame did not confirm delivery.
  Future<RepublishResponse> republishFramePlay({
    required String deviceId,
    required String imageUrl,
    String? baseUrlOverride,
    String? pairingToken,
    Duration? timeout,
  }) async {
    final t = timeout ?? const Duration(seconds: 12);
    Object? lastErr;
    for (final base in _candidateBases(baseUrlOverride)) {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final uri = Uri.parse('$base/api/device/send');
          final res = await _api
              .post(
                uri,
                headers: {
                  'content-type': 'application/json',
                  'accept': 'application/json',
                  if (pairingToken != null && pairingToken.trim().isNotEmpty)
                    'x-pairing-token': pairingToken.trim(),
                },
                body: jsonEncode({
                  'device_id': deviceId,
                  'image_url': imageUrl,
                }),
              )
              .timeout(t, onTimeout: () => throw TimeoutException('POST /api/device/send', t));
          if (res.statusCode < 200 || res.statusCode >= 300) {
            throw FrameApiException(res.statusCode, res.body);
          }
          final json = jsonDecode(res.body) as Map<String, dynamic>;
          return RepublishResponse.fromJson(json);
        } catch (e) {
          lastErr = e;
          if (!_isTransient(e) || attempt == 1) break;
          await Future<void>.delayed(Duration(milliseconds: 300 * (1 << attempt)));
        }
      }
    }
    if (lastErr is FrameApiException) throw lastErr;
    if (lastErr is TimeoutException) throw lastErr;
    if (lastErr is SocketException) throw lastErr;
    throw Exception('Republish failed after retries: $lastErr');
  }

  /// GET `/api/frames` — frames accessible to the authenticated user (own + family).
  static DateTime? _lastFetchFramesTime;
  static List<Map<String, dynamic>> _lastFetchFramesResult = const [];

  Future<List<Map<String, dynamic>>> fetchFrames({
    String? baseUrlOverride,
    String? bearerToken,
    Duration? timeout,
    bool force = false,
  }) async {
    final now = DateTime.now();
    if (!force &&
        _lastFetchFramesTime != null &&
        now.difference(_lastFetchFramesTime!) < const Duration(seconds: 10)) {
      return _lastFetchFramesResult;
    }
    final t = timeout ?? const Duration(seconds: 10);
    final base = _base(baseUrlOverride);
    try {
      final uri = Uri.parse('$base/api/frames');
      final headers = <String, String>{
        'accept': 'application/json',
      };
      final tok = bearerToken?.trim() ?? '';
      if (tok.isNotEmpty) {
        headers['Authorization'] = 'Bearer $tok';
      }
      final res = await _api.get(uri, headers: headers).timeout(t);
      if (res.statusCode != 200) return [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (json['ok'] != true) return [];
      final raw = json['frames'] as List<dynamic>?;
      if (raw == null) return [];
      final result = raw.cast<Map<String, dynamic>>();
      _lastFetchFramesTime = now;
      _lastFetchFramesResult = result;
      return result;
    } catch (_) {
      return [];
    }
  }

  /// DELETE `/api/frames/{mac}` — unbind frame from user account server-side.
  Future<bool> deleteFrame({
    required String mac,
    String? baseUrlOverride,
    String? pairingToken,
    Duration? timeout,
  }) async {
    final cleanMac = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    if (cleanMac.length < 12) return false;
    final slug = cleanMac.substring(cleanMac.length - 12);
    final t = timeout ?? const Duration(seconds: 10);
    final bases = _candidateBases(baseUrlOverride);
    for (final base in bases) {
      try {
        final uri = Uri.parse('$base/api/frames/$slug');
        final res = await _api
            .delete(
              uri,
              headers: pairingToken != null && pairingToken.trim().isNotEmpty
                  ? {'x-pairing-token': pairingToken.trim()}
                  : null,
            )
            .timeout(t);
        return res.statusCode == 200;
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  /// GET `/api/v1/user/media` — personal upload history for the authenticated user.
  ///
  /// Falls back to `/api/user/gallery` for older server deployments.
  /// Returns newest-first list of upload records.
  Future<List<Map<String, dynamic>>> fetchUserMedia({
    required String bearerToken,
    Duration? timeout,
  }) async {
    final tok = bearerToken.trim();
    if (tok.isEmpty) return const [];
    final t = timeout ?? const Duration(seconds: 12);
    final base = _base(null);
    final headers = <String, String>{
      'accept': 'application/json',
      'Authorization': 'Bearer $tok',
    };

    // Canonical v1 endpoint.
    try {
      final res = await _api
          .get(Uri.parse('$base/api/v1/user/media'), headers: headers)
          .timeout(t);
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        if (json['ok'] == true) {
          final raw =
              (json['media'] ?? json['photos'] ?? json['items']) as List?;
          if (raw != null) return raw.cast<Map<String, dynamic>>();
        }
      }
    } catch (_) {}

    // Fallback: existing /api/user/gallery route.
    try {
      final res = await _api
          .get(Uri.parse('$base/api/user/gallery'), headers: headers)
          .timeout(t);
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final raw = (json['photos'] ?? json['items']) as List?;
        if (raw != null) return raw.cast<Map<String, dynamic>>();
      }
    } catch (_) {}

    return const [];
  }

  /// GET `/api/v1/user/albums` — user-created photo albums for the authenticated user.
  ///
  /// Each record contains at minimum: `id`, `name`, `frame_id`,
  /// `photo_count`, `cover_url`, `created_at`.
  ///
  /// Returns `[]` only when the server positively returned an empty album list.
  /// Returns `null` when the request failed (non-200 / network error / bad
  /// body) so callers can distinguish a transient failure from a genuine
  /// empty server list and avoid wiping locally-persisted albums.
  Future<List<Map<String, dynamic>>?> fetchUserAlbums({
    required String bearerToken,
    Duration? timeout,
  }) async {
    final tok = bearerToken.trim();
    if (tok.isEmpty) return null;
    final t = timeout ?? const Duration(seconds: 12);
    final base = _base(null);
    final headers = <String, String>{
      'accept': 'application/json',
      'Authorization': 'Bearer $tok',
    };

    try {
      final res = await _api
          .get(Uri.parse('$base/api/v1/user/albums'), headers: headers)
          .timeout(t);
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        if (json['ok'] == true) {
          final raw = (json['albums'] ?? json['items']) as List?;
          if (raw != null) return raw.cast<Map<String, dynamic>>();
          return const [];
        }
      }
    } catch (_) {}

    return null;
  }

  /// GET `/api/v1/playlists/:id/photos` — strictly returns photos whose
  /// source === "playlist" AND playlistId === :id (or whose id is in the
  /// playlist's photoIds array). Excludes personal_album and direct_cast
  /// uploads so a playlist view never bleeds into the user's general
  /// gallery feed.
  Future<List<Map<String, dynamic>>> fetchPlaylistPhotos({
    required String bearerToken,
    required String playlistId,
    Duration? timeout,
  }) async {
    final tok = bearerToken.trim();
    final id = playlistId.trim();
    if (tok.isEmpty || id.isEmpty) return const [];
    final t = timeout ?? const Duration(seconds: 12);
    final base = _base(null);
    final headers = <String, String>{
      'accept': 'application/json',
      'Authorization': 'Bearer $tok',
    };
    try {
      final res = await _api
          .get(
            Uri.parse('\$base/api/v1/playlists/\$id/photos'),
            headers: headers,
          )
          .timeout(t);
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        if (json['ok'] == true) {
          final raw = (json['photos'] ?? json['items']) as List?;
          if (raw != null) return raw.cast<Map<String, dynamic>>();
        }
      }
    } catch (_) {}
    return const [];
  }

  /// GET `/api/v1/albums/personal/photos` — strictly returns photos whose
  /// source === "personal_album" (and matching `album_id` if provided).
  /// Excludes playlist and direct_cast uploads so the Personal Album view
  /// never bleeds into playlist photos.
  Future<List<Map<String, dynamic>>> fetchPersonalAlbumPhotos({
    required String bearerToken,
    String? albumId,
    Duration? timeout,
  }) async {
    final tok = bearerToken.trim();
    if (tok.isEmpty) return const [];
    final t = timeout ?? const Duration(seconds: 12);
    final base = _base(null);
    final headers = <String, String>{
      'accept': 'application/json',
      'Authorization': 'Bearer $tok',
    };
    final qp = <String, String>{};
    if (albumId != null && albumId.trim().isNotEmpty) {
      qp['album_id'] = albumId.trim();
    }
    final uri = Uri.parse('\$base/api/v1/albums/personal/photos').replace(
      queryParameters: qp.isEmpty ? null : qp,
    );
    try {
      final res = await _api.get(uri, headers: headers).timeout(t);
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        if (json['ok'] == true) {
          final raw = (json['photos'] ?? json['items']) as List?;
          if (raw != null) return raw.cast<Map<String, dynamic>>();
        }
      }
    } catch (_) {}
    return const [];
  }

  /// DELETE `/api/v1/user/media/:id` (fallback `/api/user/gallery/:id`).
  /// Removes account media; if a frame slideshow becomes empty, server stops it.
  Future<bool> deleteUserMedia({
    required String bearerToken,
    required String mediaId,
    Duration? timeout,
  }) async {
    final tok = bearerToken.trim();
    final id = mediaId.trim();
    if (tok.isEmpty || id.isEmpty) return false;
    final t = timeout ?? const Duration(seconds: 12);
    final base = _base(null);
    final headers = <String, String>{
      'accept': 'application/json',
      'Authorization': 'Bearer $tok',
    };
    for (final path in [
      '/api/v1/user/media/$id',
      '/api/user/gallery/$id',
    ]) {
      try {
        final res = await _api
            .delete(Uri.parse('$base$path'), headers: headers)
            .timeout(t);
        if (res.statusCode == 200 || res.statusCode == 204) return true;
      } catch (_) {}
    }
    return false;
  }

  /// DELETE `/api/v1/user/albums/:id` (fallback `/api/user/playlists/:id`).
  /// Server deletes the album and notifies frames playing it to stop.
  Future<bool> deleteUserAlbum({
    required String bearerToken,
    required String albumId,
    Duration? timeout,
  }) async {
    final tok = bearerToken.trim();
    final id = albumId.trim();
    if (tok.isEmpty || id.isEmpty) return false;
    final t = timeout ?? const Duration(seconds: 12);
    final base = _base(null);
    final headers = <String, String>{
      'accept': 'application/json',
      'Authorization': 'Bearer $tok',
    };
    for (final path in [
      '/api/v1/user/albums/$id',
      '/api/user/playlists/$id',
    ]) {
      try {
        final res = await _api
            .delete(Uri.parse('$base$path'), headers: headers)
            .timeout(t);
        if (res.statusCode == 200 || res.statusCode == 204) return true;
      } catch (_) {}
    }
    return false;
  }

  /// ALBUM_DELETE_SYNC — deletes the album and tells frames (via MQTT) to
  /// drop the deleted images and continue autonomous local playback with the
  /// supplied remaining image list + playback strategy (no stop/fallback).
  Future<Map<String, dynamic>?> deleteUserAlbumSync({
    required String bearerToken,
    required String albumId,
    List<String> imageIds = const [],
    int intervalMinutes = 10,
    int strategy = 1,
    int durationHours = 0,
    List<String> macSlugs = const [],
    Duration? timeout,
  }) async {
    final tok = bearerToken.trim();
    final id = albumId.trim();
    if (tok.isEmpty || id.isEmpty) return null;
    final t = timeout ?? const Duration(seconds: 12);
    final base = _base(null);
    final headers = <String, String>{
      'accept': 'application/json',
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $tok',
    };
    final path = '/api/v1/user/albums/$id/delete-sync';
    try {
      final res = await _api
          .post(
            Uri.parse('$base$path'),
            headers: headers,
            body: jsonEncode({
              'imageIds': imageIds,
              'intervalMinutes': intervalMinutes,
              'strategy': strategy,
              'durationHours': durationHours,
              'macSlugs': macSlugs,
            }),
          )
          .timeout(t);
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        if (json['ok'] == true) return json;
      }
    } catch (_) {}
    return null;
  }

  /// PUT `/api/v1/user/profile` — update profile (nickname and/or avatarUrl).
  Future<bool> updateProfile({
    required String bearerToken,
    String? nickname,
    String? avatarUrl,
    Duration? timeout,
  }) async {
    final tok = bearerToken.trim();
    if (tok.isEmpty) return false;
    final t = timeout ?? const Duration(seconds: 12);
    final base = _base(null);
    final headers = <String, String>{
      'accept': 'application/json',
      'Authorization': 'Bearer $tok',
      'Content-Type': 'application/json',
    };
    final body = <String, dynamic>{};
    if (nickname != null && nickname.trim().isNotEmpty) {
      body['nickname'] = nickname.trim();
    }
    if (avatarUrl != null) {
      body['avatarUrl'] = avatarUrl.trim();
    }
    if (body.isEmpty) return false;
    try {
      final res = await _api
          .put(
            Uri.parse('$base/api/v1/user/profile'),
            headers: headers,
            body: jsonEncode(body),
          )
          .timeout(t);
      return res.statusCode == 200;
    } catch (_) {}
    return false;
  }

  /// POST `/api/v1/user/avatar` — upload profile avatar image.
  Future<String?> uploadAvatar({
    required String bearerToken,
    required String filePath,
    Duration? timeout,
  }) async {
    final tok = bearerToken.trim();
    if (tok.isEmpty) return null;
    final t = timeout ?? const Duration(seconds: 30);
    final base = _base(null);
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$base/api/v1/user/avatar'),
      );
      req.headers['Authorization'] = 'Bearer $tok';
      req.files.add(await http.MultipartFile.fromPath('avatar', file.path));
      final res = await _api.send(req).timeout(t);
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        if (json['ok'] == true) {
          return json['avatarUrl'] as String?;
        }
      }
    } catch (_) {}
    return null;
  }

  void close() => _api.close();

  static String _base(String? override) {
    final o = override?.trim();
    if (o != null && o.isNotEmpty && !ApiConfig.isLoopbackApiBase(o)) {
      return o.replaceAll(RegExp(r'/$'), '');
    }
    return ApiConfig.baseUrl.replaceAll(RegExp(r'/$'), '');
  }

  static List<String> _candidateBases(String? override) {
    return [_base(override)];
  }

  /// Status/upload paths on `https://myframe.ink` (nginx), then LAN/IP fallback.
  static List<String> _frameStatusCandidateBases(String? override) {
    final primary = _base(override);
    // Flutter uploads use VPS IP :3001 — poll status on the same host first.
    if (primary.contains(VpsDefaults.host)) return [primary];
    return [primary, VpsDefaults.apiBase.replaceAll(RegExp(r'/+$'), '')];
  }

  static bool _isTransient(Object e) {
    if (e is TimeoutException || e is SocketException) return true;
    if (e is FrameApiException) {
      return e.statusCode >= 500 || e.statusCode == 429;
    }
    return false;
  }
}

/// Firmware + OTA availability for a frame (`GET /api/frames/:mac/firmware`).
class FirmwareInfo {
  FirmwareInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.hasUpdate,
    this.releaseNotes,
    this.changelogZh = const [],
    this.changelogEn = const [],
    this.frameOnline = false,
    this.otaStatus = 'idle',
  });

  final String? currentVersion;
  final String? latestVersion;
  final bool hasUpdate;
  final String? releaseNotes;
  final List<String> changelogZh;
  final List<String> changelogEn;
  final bool frameOnline;
  final String otaStatus;

  String get currentLabel => currentVersion == null || currentVersion!.isEmpty
      ? '--'
      : (currentVersion!.startsWith('v') ? currentVersion! : 'v$currentVersion');

  String get latestLabel => latestVersion == null || latestVersion!.isEmpty
      ? ''
      : (latestVersion!.startsWith('v') ? latestVersion! : 'v$latestVersion');

  factory FirmwareInfo.fromJson(Map<String, dynamic> json) => FirmwareInfo(
        currentVersion: json['currentVersion'] as String?,
        latestVersion: json['latestVersion'] as String?,
        hasUpdate: json['hasUpdate'] == true,
        releaseNotes: json['releaseNotes'] as String?,
        changelogZh: _asStringList(json['changelogZh']),
        changelogEn: _asStringList(json['changelogEn']),
        frameOnline: json['frameOnline'] == true,
        otaStatus: json['otaStatus'] as String? ?? 'idle',
      );

  static List<String> _asStringList(dynamic raw) {
    if (raw is List) {
      return raw.whereType<String>().where((s) => s.trim().isNotEmpty).toList();
    }
    return const [];
  }
}

class PhotoUploadResponse {
  PhotoUploadResponse({
    required this.ok,
    this.receivedBytes,
    this.storedPath,
    this.checksumSha256,
    this.deliveredToFrame,
    this.deliveryMode,
    /// Public URL passed to MQTT `play` (usually MYFM `.bin` under `/frame-media/`).
    this.imageUrl,
    /// Basename of the file the frame downloads (`*.bin` or original upload).
    this.framePlayBasename,
    this.myfmSidecar,
    /// Original JPEG/PNG basename kept on server (not used in MQTT).
    this.previewStoredPath,
    this.myfmFileBytes,
  });

  final bool ok;
  final int? receivedBytes;
  final String? storedPath;
  final String? checksumSha256;
  final bool? deliveredToFrame;
  final String? deliveryMode;
  final String? imageUrl;
  final String? framePlayBasename;
  final bool? myfmSidecar;
  final String? previewStoredPath;
  final int? myfmFileBytes;

  factory PhotoUploadResponse.fromJson(Map<String, dynamic> json) {
    return PhotoUploadResponse(
      ok: json['ok'] as bool? ?? false,
      receivedBytes: json['received_bytes'] as int?,
      storedPath: json['stored_path'] as String?,
      checksumSha256: json['checksum_sha256'] as String?,
      deliveredToFrame: json['delivered_to_frame'] as bool?,
      deliveryMode: json['delivery_mode'] as String?,
      imageUrl: json['image_url'] as String?,
      framePlayBasename: json['frame_play_basename'] as String?,
      myfmSidecar: json['myfm_sidecar'] as bool?,
      previewStoredPath: json['preview_stored_path'] as String?,
      myfmFileBytes: json['myfm_file_bytes'] as int?,
    );
  }
}

class FrameApiException implements Exception {
  FrameApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'FrameApiException($statusCode): $body';
}

class FrameCastStatusResponse {
  FrameCastStatusResponse({
    required this.ok,
    this.online,
    this.mqttConnected,
    this.frameMqttLive,
    this.displayed,
    this.lastAction,
    this.lastSeenMs,
    this.lastUploadMs,
    this.result,
    this.displayCode,
  });

  final bool ok;
  final bool? online;
  final bool? mqttConnected;
  final bool? frameMqttLive;
  final bool? displayed;
  final String? lastAction;
  final int? lastSeenMs;
  final int? lastUploadMs;
  final int? result;
  final int? displayCode;

  factory FrameCastStatusResponse.fromJson(Map<String, dynamic> json) {
    int? asInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('$v');
    }

    return FrameCastStatusResponse(
      ok: json['ok'] as bool? ?? false,
      online: json['online'] as bool?,
      mqttConnected: json['mqtt_connected'] as bool?,
      frameMqttLive: json['frame_mqtt_live'] as bool?,
      displayed: json['displayed'] as bool?,
      lastAction: json['lastAction'] as String? ?? json['last_action'] as String?,
      lastSeenMs: asInt(json['last_seen_ms']),
      lastUploadMs: asInt(json['last_upload_ms']),
      result: asInt(json['result'] ?? json['lastResult'] ?? json['displayCode']),
      displayCode: asInt(json['displayCode']),
    );
  }

  /// Frame recently reported on MQTT (login/heart/play), not only API broker flag.
  bool isFrameMqttReady({int? provisionStartedMs}) {
    if (!ok) return false;
    if (mqttConnected == true || frameMqttLive == true) return true;
    final seen = lastSeenMs;
    if (seen == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final fresh = provisionStartedMs != null
        ? seen >= provisionStartedMs - 60000
        : seen >= now - 30000;
    if (!fresh || online != true) return false;
    final action = (lastAction ?? '').toLowerCase();
    if (action == 'login' ||
        action == 'heart' ||
        action == 'play_ack' ||
        action == 'play') {
      return true;
    }
    final code = result ?? displayCode;
    return code == 113 || code == 184;
  }

  /// True only when this upload produced a **new** frame play_ack (not stale state).
  ///
  /// [baselineLastUploadMs] is `/api/frames/:mac/status` `last_upload_ms` captured
  /// before POST /api/photo/upload — required so a previous `displayed: true` does
  /// not close the editor early on iOS.
  bool confirmsCastSince(
    int uploadStartedMs, {
    int? baselineLastUploadMs,
  }) {
    if (!ok) return false;
    final ts = lastUploadMs;
    if (ts == null) return false;
    if (baselineLastUploadMs != null && ts <= baselineLastUploadMs) {
      return false;
    }
    if (ts < uploadStartedMs - 3000) return false;

    if (displayed == true) return true;

    // Firmware result codes mean the panel actually refreshed.
    final action = (lastAction ?? '').toLowerCase();
    final code = result ?? displayCode;
    // play_ack without displayed/display-code means download start (106), not done.
    if (action == 'play_ack' && displayed != true) {
      if (code == 113 || code == 182 || code == 184 || code == 186 || code == 188 || code == 210) {
        return true;
      }
      return false;
    }
    // Display codes: 113, 182, 184, 186, 188, 210 = finished
    if (code == 113 || code == 182 || code == 184 || code == 186 || code == 188 || code == 210) {
      return true;
    }
    return false;
  }

  /// Check if frame is stuck downloading (code 106) or failed (code 104).
  bool get isDownloadInProgress {
    final code = result ?? displayCode;
    return code == 106; // Download in progress
  }

  /// Check if download failed.
  bool get isDownloadFailed {
    final code = result ?? displayCode;
    return code == 104; // Download failed
  }

  /// Check if download completed but not displayed yet.
  bool get isDownloadComplete {
    final code = result ?? displayCode;
    return code == 107; // Download complete
  }
}

class DeliveryStatusResponse {
  DeliveryStatusResponse({
    required this.ok,
    required this.found,
    required this.deliveredToFrame,
    this.deliveryMode,
  });

  final bool ok;
  final bool found;
  final bool deliveredToFrame;
  final String? deliveryMode;

  factory DeliveryStatusResponse.fromJson(Map<String, dynamic> json) {
    return DeliveryStatusResponse(
      ok: json['ok'] as bool? ?? false,
      found: json['found'] as bool? ?? false,
      deliveredToFrame: json['delivered_to_frame'] as bool? ?? false,
      deliveryMode: json['delivery_mode'] as String?,
    );
  }
}

class RepublishResponse {
  RepublishResponse({
    required this.ok,
    this.message,
    this.published,
    this.deliveryMode,
  });

  final bool ok;
  final String? message;
  final bool? published;
  final String? deliveryMode;

  factory RepublishResponse.fromJson(Map<String, dynamic> json) {
    return RepublishResponse(
      ok: json['ok'] as bool? ?? false,
      message: json['message'] as String?,
      published: json['published'] as bool?,
      deliveryMode: json['delivery_mode'] as String?,
    );
  }
}

extension PhotoUploadSlideshowId on PhotoUploadResponse {
  /// Key for `POST /api/frames/:mac/slideshow` — prefer unique MYFM `.bin` basename
  /// (checksum can collide when uploads share the same JPEG hash).
  String? get vpsSlideshowImageId {
    final basename = framePlayBasename?.trim();
    if (basename != null && basename.isNotEmpty) return basename;
    final stored = storedPath?.trim();
    if (stored != null && stored.isNotEmpty) {
      final segment = stored.split('/').last.trim();
      if (segment.isNotEmpty) return segment;
    }
    final url = imageUrl?.trim();
    if (url != null && url.isNotEmpty) {
      final segment = url.split('/').last.trim();
      if (segment.isNotEmpty) return Uri.decodeComponent(segment);
    }
    final checksum = checksumSha256?.trim();
    if (checksum != null && checksum.isNotEmpty) return checksum;
    return null;
  }
}
