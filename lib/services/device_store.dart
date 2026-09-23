import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'wifi_credential_cache.dart';
import 'frame_api_client.dart';
import 'account_sync_service.dart';
import 'local_storage_service.dart';

import '../config/api_config.dart';
import '../config/vps_defaults.dart';
import '../l10n/app_strings.dart';
import '../models/pairing_payload.dart';
import 'frame_mac_util.dart';
import 'frame_shortcut_service.dart';

/// Persisted pairing(s): multiple frames in JSON + legacy keys mirroring the **active** frame.
class DeviceStore {
  DeviceStore._();

  static final DeviceStore instance = DeviceStore._();

  /// Bumped when paired frames are added, removed, or cleared — Home listens to refresh.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void _bumpRevision() => revision.value++;

  static const _kFramesJson = 'paired_frames_json_v1';
  static const _kActiveDeviceId = 'paired_active_device_id_v1';

  static const _kDeviceId = 'paired_device_id';
  static const _kToken = 'paired_pairing_token';
  static const _kApiUrl = 'paired_api_url';
  static const _kBleService = 'paired_ble_service_uuid';
  static const _kBleData = 'paired_ble_data_char_uuid';
  static const _kBleNamePrefix = 'paired_ble_name_prefix';
  static const _kBleRemoteId = 'paired_ble_remote_id';
  static const _kProduct = 'paired_product';
  static const _kWifiSsid = 'paired_wifi_ssid';
  static const _kWifiUser = 'paired_wifi_user';
  static const _kWifiPass = 'paired_wifi_pass';
  static const _kWifiProvisionedAt = 'paired_wifi_provisioned_at';
  static const _kFrameName = 'paired_frame_name';
  static const _kFrameOrientation = 'paired_frame_orientation';
  static const _kMqttHost = 'paired_mqtt_host';
  static const _kMqttPort = 'paired_mqtt_port';
  static const _kMqttUser = 'paired_mqtt_user';
  static const _kMqttPass = 'paired_mqtt_pass';

  /// Same key as WeChat mini program (`wx.setStorageSync('pairedFrameMac', mac)`).
  static const kPairedFrameMac = 'pairedFrameMac';

  List<PairedFrame> _frames = [];
  List<Map<String, dynamic>> _serverFrames = [];
  String? _pairedFrameMac;
  String? _activeDeviceId;

  int _indexOf(String deviceId) {
    final t = deviceId.trim();
    final exact = _frames.indexWhere((e) => e.deviceId.trim() == t);
    if (exact >= 0) return exact;
    return _frames.indexWhere((e) => _macsRelated(e.deviceId, t));
  }

  static bool _macsRelated(String a, String b) {
    final aa = FrameMacUtil.normalizeSlug(a);
    final bb = FrameMacUtil.normalizeSlug(b);
    if (aa == null || bb == null) return false;
    if (aa == bb) return true;
    // Only server-recorded aliases prove two addresses belong to one frame.
    return instance._serverFrames.any((row) {
      final aliases = <String>{};
      for (final key in ['id', 'frame_id', 'bleMac', 'ble_mac', 'stationMac', 'station_mac']) {
        final mac = FrameMacUtil.normalizeSlug('${row[key] ?? ''}');
        if (mac != null) aliases.add(mac);
      }
      return aliases.contains(aa) && aliases.contains(bb);
    });
  }

  static bool _seenHasRelated(Set<String> seen, String key) {
    if (seen.contains(key)) return true;
    for (final s in seen) {
      if (_macsRelated(s, key)) return true;
    }
    return false;
  }

  /// Drop frameName when it is clearly just the Wi‑Fi SSID.
  static List<PairedFrame> _sanitizeFrameNames(List<PairedFrame> frames) {
    return frames.map((f) {
      final name = f.frameName?.trim();
      final ssid = f.wifiSsid?.trim();
      if (name == null || name.isEmpty) return f;
      if (ssid != null &&
          ssid.isNotEmpty &&
          name.toLowerCase() == ssid.toLowerCase()) {
        return PairedFrame(
          deviceId: f.deviceId,
          pairingToken: f.pairingToken,
          apiUrl: f.apiUrl,
          bleServiceUuid: f.bleServiceUuid,
          bleDataCharUuid: f.bleDataCharUuid,
          bleNamePrefix: f.bleNamePrefix,
          bleRemoteId: f.bleRemoteId,
          product: f.product,
          wifiSsid: f.wifiSsid,
          wifiUsername: f.wifiUsername,
          wifiPassword: f.wifiPassword,
          wifiProvisionedAtMs: f.wifiProvisionedAtMs,
          frameName: null,
          frameOrientation: f.frameOrientation,
          mqttBrokerHost: f.mqttBrokerHost,
          mqttBrokerPort: f.mqttBrokerPort,
          mqttBrokerUser: f.mqttBrokerUser,
          mqttBrokerPassword: f.mqttBrokerPassword,
        );
      }
      return f;
    }).toList();
  }

  /// Collapse BLE/STA duplicate rows into one card (prefer station MAC + real name).
  Future<void> dedupeRelatedFrames() async {
    await load();
    if (_frames.isEmpty) return;

    String? identity(PairedFrame f) {
      return FrameMacUtil.macFromBleName(f.bleNamePrefix ?? '') ??
          FrameMacUtil.normalizeSlug(f.deviceId) ??
          FrameMacUtil.normalizeSlug(f.bleRemoteId ?? '');
    }

    if (_frames.length < 2) {
      final cleaned = _sanitizeFrameNames(_frames);
      if (!_sameNames(cleaned, _frames)) {
        _frames = cleaned;
        await _persistAll();
        _bumpRevision();
      }
      return;
    }

    final kept = <PairedFrame>[];
    final used = <int>{};
    for (var i = 0; i < _frames.length; i++) {
      if (used.contains(i)) continue;
      var best = _frames[i];
      used.add(i);
      final bi = identity(best)?.toUpperCase() ??
          best.deviceId.trim().toUpperCase();
      for (var j = i + 1; j < _frames.length; j++) {
        if (used.contains(j)) continue;
        final other = _frames[j];
        final oj = identity(other)?.toUpperCase() ??
            other.deviceId.trim().toUpperCase();
        if (!_macsRelated(bi, oj) && bi != oj) continue;
        used.add(j);
        best = _mergeSiblingFrames(best, other);
      }
      kept.add(best);
    }

    final next = _sanitizeFrameNames(kept);
    if (_sameNames(next, _frames) && next.length == _frames.length) return;
    _frames = next;
    if (_activeDeviceId != null && _indexOf(_activeDeviceId!) < 0) {
      _activeDeviceId = _frames.isNotEmpty ? _frames.first.deviceId : null;
    }
    await _persistAll();
    _bumpRevision();
  }

  static bool _sameNames(List<PairedFrame> a, List<PairedFrame> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].deviceId != b[i].deviceId) return false;
      if (a[i].frameName != b[i].frameName) return false;
    }
    return true;
  }

  static PairedFrame _mergeSiblingFrames(PairedFrame a, PairedFrame b) {
    final idA = FrameMacUtil.normalizeSlug(a.deviceId) ?? a.deviceId;
    final preferA =
        (PairedFrame.preferEsp32WifiStationMac(idA) ?? idA) == idA;
    final primary = preferA ? a : b;
    final secondary = preferA ? b : a;
    final nameA = a.frameName?.trim();
    final nameB = b.frameName?.trim();
    final ssidA = a.wifiSsid?.trim();
    final ssidB = b.wifiSsid?.trim();
    String? name;
    for (final n in [nameA, nameB]) {
      if (n == null || n.isEmpty) continue;
      if (ssidA != null && n.toLowerCase() == ssidA.toLowerCase()) continue;
      if (ssidB != null && n.toLowerCase() == ssidB.toLowerCase()) continue;
      name = n;
      break;
    }
    final stationId =
        PairedFrame.preferEsp32WifiStationMac(primary.deviceId) ??
            primary.deviceId;
    return PairedFrame(
      deviceId: stationId,
      pairingToken: primary.pairingToken ?? secondary.pairingToken,
      apiUrl: primary.apiUrl ?? secondary.apiUrl,
      bleServiceUuid: primary.bleServiceUuid ?? secondary.bleServiceUuid,
      bleDataCharUuid: primary.bleDataCharUuid ?? secondary.bleDataCharUuid,
      bleNamePrefix: primary.bleNamePrefix ?? secondary.bleNamePrefix,
      bleRemoteId: primary.bleRemoteId ?? secondary.bleRemoteId,
      product: primary.product ?? secondary.product,
      wifiSsid: primary.wifiSsid ?? secondary.wifiSsid,
      wifiUsername: primary.wifiUsername ?? secondary.wifiUsername,
      wifiPassword: primary.wifiPassword ?? secondary.wifiPassword,
      wifiProvisionedAtMs:
          primary.wifiProvisionedAtMs ?? secondary.wifiProvisionedAtMs,
      frameName: name,
      frameOrientation: primary.frameOrientation ?? secondary.frameOrientation,
      mqttBrokerHost: primary.mqttBrokerHost ?? secondary.mqttBrokerHost,
      mqttBrokerPort: primary.mqttBrokerPort ?? secondary.mqttBrokerPort,
      mqttBrokerUser: primary.mqttBrokerUser ?? secondary.mqttBrokerUser,
      mqttBrokerPassword:
          primary.mqttBrokerPassword ?? secondary.mqttBrokerPassword,
    );
  }

  /// Per-frame MAC for live status / cast.
  /// Never treat iOS UUID as MAC.
  /// Resolve from this frame only; global active-frame state is never a fallback.
  static String? macForPairedFrame(PairedFrame f) {
    return FrameMacUtil.normalizeSlug(f.deviceId) ??
        FrameMacUtil.macFromBleName(f.bleNamePrefix ?? '') ??
        FrameMacUtil.normalizeSlug(f.bleRemoteId ?? '');
  }

  /// Only identities stored on this frame, never guessed adjacent MACs.
  static List<String> statusMacCandidates(PairedFrame f) => <String>{
    if (macForPairedFrame(f) case final String mac) mac,
    if (FrameMacUtil.macFromBleName(f.bleNamePrefix ?? '') case final String mac) mac,
  }.toList();

  /// Frames shown on **My Frames** (order preserved).
  List<PairedFrame> get pairedFrames => List.unmodifiable(_frames);

  /// Server-synced frames (shared via family, not BLE-paired locally).
  List<Map<String, dynamic>> get serverFrames => List.unmodifiable(_serverFrames);

  static const _kUnboundMacsKey = 'account_unbound_frame_macs_v1';

  Future<bool> _isUnboundMac(String? raw) async {
    final slug = FrameMacUtil.normalizeSlug(raw ?? '')?.toUpperCase() ??
        (raw ?? '').trim().toUpperCase();
    if (slug.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    final unbound = (prefs.getStringList(_kUnboundMacsKey) ?? const <String>[])
        .map((e) => e.trim().toUpperCase())
        .where((e) => e.isNotEmpty)
        .toSet();
    if (unbound.contains(slug)) return true;
    final si = int.tryParse(slug, radix: 16);
    if (si == null) return false;
    for (final k in unbound) {
      final ki = int.tryParse(k, radix: 16);
      if (ki != null && (ki - si).abs() == 2) return true;
    }
    return false;
  }

  /// Sync frames from cloud into Home's [pairedFrames] list.
  ///
  /// Family joiners rely on this: shared frames must appear on Home without BLE.
  Future<void> syncServerFrames({String? bearerToken}) async {
    try {
      final api = FrameApiClient();
      final frames = await api.fetchFrames(bearerToken: bearerToken);
      _serverFrames = frames;

      final mapped = <Map<String, dynamic>>[];
      for (final f in frames) {
        final row = Map<String, dynamic>.from(
          f.map((k, v) => MapEntry(k.toString(), v)),
        );
        final id = '${row['id'] ?? row['bleMac'] ?? row['ble_mac'] ?? ''}'.trim();
        final ble = '${row['bleMac'] ?? row['ble_mac'] ?? id}'.trim();
        final station = '${row['stationMac'] ?? row['station_mac'] ?? ''}'.trim();
        final name =
            '${row['custom_name'] ?? row['alias'] ?? row['displayName'] ?? row['display_name'] ?? row['name'] ?? ''}'
                .trim();
        final ssid = '${row['wifiSsid'] ?? row['wifi_ssid'] ?? ''}'.trim();
        if (id.isEmpty && ble.isEmpty) continue;
        mapped.add({
          'frame_id': id.isNotEmpty ? id : ble,
          'ble_mac': ble.isNotEmpty ? ble : id,
          if (station.isNotEmpty) 'station_mac': station,
          'frame_name': name,
          if (ssid.isNotEmpty) 'wifi_ssid': ssid,
          'is_owner': row['isOwner'] == true || row['is_owner'] == true,
          'user_role': '${row['userRole'] ?? row['user_role'] ?? ''}',
        });
      }

      if (mapped.isEmpty) {
        _bumpRevision();
        return;
      }

      await applyBoundFramesFromServer(
        mapped,
        bearerToken: bearerToken,
        pruneMissing: false,
        refreshServerCache: false,
      );
    } catch (_) {
      _serverFrames = [];
    }
  }

  /// Merge server `bound_frames` into the local Home list.
  ///
  /// Local BLE pairings are sticky: they stay on this phone forever until the
  /// user taps Remove/Delete (which bans the MAC via [AccountSyncService.deleteFrame]).
  /// [pruneMissing] is kept for call-site compatibility but **never** drops a
  /// locally paired frame just because the cloud list is empty/incomplete.
  Future<void> applyBoundFramesFromServer(
    List<Map<String, dynamic>> serverFrames, {
    String? primaryFrameId,
    String? bearerToken,
    bool pruneMissing = false,
    bool refreshServerCache = true,
  }) async {
    await load();

    // Cloud is actively listing these frames for this account → lift Remove bans
    // so family invitees see the owner's shared device on Home again. BUT never
    // clear the ban for a MAC the user just deleted — doing so is what let the
    // periodic sync resurrect the frame during the ~30s unbind window. Only
    // clear bans for frames that are NOT currently tombstoned locally.
    final nonUnbound = <Map<String, dynamic>>[];
    for (final f in serverFrames) {
      final station = (f['station_mac'] as String?) ?? '';
      final mac = (f['ble_mac'] as String?) ?? '';
      final frameId = (f['frame_id'] as String?) ?? '';
      final rawId = station.isNotEmpty ? station : (mac.isNotEmpty ? mac : frameId);
      final slug = FrameMacUtil.normalizeSlug(rawId);
      final unb = slug != null &&
          (await AccountSyncService.instance.isUnboundFrameId(slug) ||
              await AccountSyncService.instance.isUnboundFrameId(station) ||
              await AccountSyncService.instance.isUnboundFrameId(mac));
      if (!unb) nonUnbound.add(f);
    }
    if (nonUnbound.isNotEmpty) {
      await AccountSyncService.instance.clearUnboundBansForCloudFrames(nonUnbound);
    }

    final next = <PairedFrame>[];
    final seen = <String>{};

    for (final f in serverFrames) {
      final station = (f['station_mac'] as String?) ?? '';
      final mac = (f['ble_mac'] as String?) ?? '';
      final frameId = (f['frame_id'] as String?) ?? '';
      // Prefer Wi‑Fi station MAC (upload/cast identity), then BLE, never product SKUs.
      final rawId = station.isNotEmpty
          ? station
          : (mac.isNotEmpty ? mac : frameId);
      final slugRaw = FrameMacUtil.normalizeSlug(rawId);
      if (slugRaw == null) continue; // skip non-MAC ids like YX-133P-001
      final slug = PairedFrame.preferEsp32WifiStationMac(slugRaw) ?? slugRaw;
      final key = slug.trim().toUpperCase();
      if (key.isEmpty || seen.contains(key)) continue;
      // Honor explicit Remove/Delete — never resurrect unbound MACs.
      if (await _isUnboundMac(key) ||
          await _isUnboundMac(station) ||
          await _isUnboundMac(mac)) {
        continue;
      }
      seen.add(key);

      PairedFrame? existing;
      for (final e in _frames) {
        final ed = FrameMacUtil.normalizeSlug(e.deviceId)?.toUpperCase() ??
            e.deviceId.trim().toUpperCase();
        if (ed == key) {
          existing = e;
          break;
        }
        if (ed == FrameMacUtil.normalizeSlug(mac) ||
            ed == FrameMacUtil.normalizeSlug(frameId)) {
          existing = e;
          break;
        }
      }

      // Frame name is a user label — NEVER fall back to Wi‑Fi SSID (that caused
      // frames named "O" / home router names). Keep local name if server omits it.
      final serverFrameName = (f['frame_name'] as String?)?.trim();
      final wifiSsid = (f['wifi_ssid'] as String?)?.trim();
      final resolvedName = () {
        if (serverFrameName != null &&
            serverFrameName.isNotEmpty &&
            serverFrameName != wifiSsid) {
          return serverFrameName;
        }
        final local = existing?.frameName?.trim();
        if (local != null &&
            local.isNotEmpty &&
            local != wifiSsid &&
            local != existing?.wifiSsid) {
          return local;
        }
        // Family-shared rows sometimes only have a MAC id — still show on Home
        // so invitees can send photos/playlists without BLE pairing.
        if (key.length >= 4) return 'Frame ${key.substring(key.length - 4)}';
        return 'Frame';
      }();

      // Other-device / family imports: require Wi‑Fi so incomplete BLE ghosts
      // never appear as sendable. Name always has a fallback above.
      final hasWifi = wifiSsid != null && wifiSsid.isNotEmpty;
      if (existing == null && !hasWifi) {
        continue;
      }

      if (existing != null) {
        next.add(
          PairedFrame(
            deviceId: slug,
            pairingToken: existing.pairingToken,
            apiUrl: existing.apiUrl ?? ApiConfig.baseUrl,
            bleServiceUuid: existing.bleServiceUuid,
            bleDataCharUuid: existing.bleDataCharUuid,
            // Never overwrite BLE advertised name with SSID / display label.
            bleNamePrefix: existing.bleNamePrefix,
            bleRemoteId: existing.bleRemoteId,
            product: existing.product,
            wifiSsid: wifiSsid?.isNotEmpty == true ? wifiSsid : existing.wifiSsid,
            wifiUsername: existing.wifiUsername,
            wifiPassword: existing.wifiPassword,
            wifiProvisionedAtMs: existing.wifiProvisionedAtMs,
            frameName: (serverFrameName != null &&
                    serverFrameName.isNotEmpty &&
                    serverFrameName != wifiSsid)
                ? serverFrameName
                : (existing.frameName?.trim().isNotEmpty == true
                    ? existing.frameName
                    : resolvedName),
            frameOrientation: existing.frameOrientation,
            mqttBrokerHost: existing.mqttBrokerHost,
            mqttBrokerPort: existing.mqttBrokerPort,
            mqttBrokerUser: existing.mqttBrokerUser,
            mqttBrokerPassword: existing.mqttBrokerPassword,
          ),
        );
      } else {
        next.add(
          PairedFrame(
            deviceId: slug,
            bleNamePrefix: null,
            frameName: resolvedName,
            wifiSsid: wifiSsid,
            apiUrl: ApiConfig.baseUrl,
          ),
        );
      }
    }

    // Always keep local pairings not on the server. A wall frame must survive
    // empty cloud lists, app restarts, and soft sync — only Remove/Delete
    // (unbound ban) may drop it. [pruneMissing] is ignored for sticky locals.
    for (final e in _frames) {
      final key = FrameMacUtil.normalizeSlug(e.deviceId)?.toUpperCase() ??
          e.deviceId.trim().toUpperCase();
      if (key.isEmpty) continue;
      if (_seenHasRelated(seen, key)) continue;
      if (await _isUnboundMac(key) || await _isUnboundMac(e.deviceId)) {
        continue;
      }
      seen.add(key);
      next.add(e);
    }
    // Call sites still pass pruneMissing; sticky pairing intentionally ignores it.
    if (pruneMissing) {
      // no-op: never wipe wall frames from an empty/partial server list
    }

    _frames = _sanitizeFrameNames(next);
    _serverFrames = serverFrames
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);

    final primary = primaryFrameId?.trim() ?? '';
    if (primary.isNotEmpty) {
      final primarySlug =
          (FrameMacUtil.normalizeSlug(primary) ?? primary).trim().toUpperCase();
      PairedFrame? match;
      for (final e in _frames) {
        final id = e.deviceId.trim().toUpperCase();
        if (id == primarySlug || id == primary.toUpperCase()) {
          match = e;
          break;
        }
      }
      _activeDeviceId =
          match?.deviceId ?? (_frames.isNotEmpty ? _frames.first.deviceId : null);
    } else if (_frames.isNotEmpty) {
      if (_activeDeviceId == null ||
          _activeDeviceId!.isEmpty ||
          _indexOf(_activeDeviceId!) < 0) {
        _activeDeviceId = _frames.first.deviceId;
      }
    } else {
      _activeDeviceId = null;
    }

    final active = cached;
    if (active != null) {
      final mac = FrameMacUtil.macFromBleIdentity(
            bleName: active.bleNamePrefix,
            fallbackText: active.deviceId,
          ) ??
          FrameMacUtil.normalizeSlug(active.deviceId);
      if (mac != null && mac.isNotEmpty) {
        await savePairedFrameMac(mac);
      }
    } else {
      _pairedFrameMac = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kPairedFrameMac);
    }

    await _persistAll();
    if (refreshServerCache) {
      // Refresh side-cache only (avoid re-entering applyBoundFramesFromServer).
      try {
        final api = FrameApiClient();
        _serverFrames = await api.fetchFrames(bearerToken: bearerToken);
      } catch (_) {
        /* keep existing _serverFrames */
      }
    } else {
      _serverFrames = serverFrames
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    }
    _bumpRevision();
  }

  /// 12-hex MAC from BLE name (`IJ_…`) for `/api/frames/:mac/*` — never hardcode.
  String? get pairedFrameMac => _pairedFrameMac?.trim().isNotEmpty == true
      ? _pairedFrameMac!.trim().toUpperCase()
      : null;

  /// Active frame used by Send, editor, Wi‑Fi setup, etc.
  PairedFrame? get cached {
    if (_frames.isEmpty) return null;
    final id = _activeDeviceId?.trim();
    if (id != null && id.isNotEmpty) {
      for (final f in _frames) {
        if (f.deviceId.trim() == id) return f;
      }
    }
    return _frames.first;
  }

  Future<PairedFrame?> load() async {
    final p = await SharedPreferences.getInstance();
    final rawMac = p.getString(kPairedFrameMac)?.trim();
    if (rawMac != null && rawMac.isNotEmpty) {
      final bare = rawMac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
      if (bare.length >= 12) {
        final twelve = bare.length == 12 ? bare : bare.substring(bare.length - 12);
        final fixed = PairedFrame.preferEsp32WifiStationMac(twelve) ?? twelve;
        _pairedFrameMac = fixed;
        if (fixed != twelve) {
          await p.setString(kPairedFrameMac, fixed);
        }
      }
    }
    final bundle = p.getString(_kFramesJson);
    if (bundle != null && bundle.isNotEmpty) {
      try {
        final decoded = jsonDecode(bundle);
        if (decoded is List && decoded.isNotEmpty) {
          _frames = decoded
              .map(
                (e) =>
                    PairedFrame.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList();
          _activeDeviceId = p.getString(_kActiveDeviceId)?.trim();
          if (_activeDeviceId == null ||
              _activeDeviceId!.isEmpty ||
              _indexOf(_activeDeviceId!) < 0) {
            _activeDeviceId = _frames.first.deviceId;
          }
          final a = cached;
          if (a != null) await _writeLegacyFromFrame(p, a);
          return a;
        }
      } catch (_) {
        _frames = [];
        _activeDeviceId = null;
      }
    }

    final id = p.getString(_kDeviceId);
    if (id == null || id.isEmpty) {
      _frames = [];
      _activeDeviceId = null;
      return null;
    }
    final f = _readLegacyAsFrame(p, id);
    _frames = [f];
    _activeDeviceId = id;
    await p.setString(
      _kFramesJson,
      jsonEncode(_frames.map((e) => e.toJson()).toList()),
    );
    await p.setString(_kActiveDeviceId, id);
    return cached;
  }

  PairedFrame _readLegacyAsFrame(SharedPreferences p, String id) {
    final mqttPort = p.getInt(_kMqttPort);
    return PairedFrame(
      deviceId: id,
      pairingToken: p.getString(_kToken),
      apiUrl: p.getString(_kApiUrl),
      bleServiceUuid: p.getString(_kBleService),
      bleDataCharUuid: p.getString(_kBleData),
      bleNamePrefix: p.getString(_kBleNamePrefix),
      bleRemoteId: p.getString(_kBleRemoteId),
      product: p.getString(_kProduct),
      wifiSsid: p.getString(_kWifiSsid),
      wifiUsername: p.getString(_kWifiUser),
      wifiPassword: p.getString(_kWifiPass),
      wifiProvisionedAtMs: p.getInt(_kWifiProvisionedAt),
      frameName: p.getString(_kFrameName),
      frameOrientation: p.getString(_kFrameOrientation),
      mqttBrokerHost: p.getString(_kMqttHost),
      mqttBrokerPort: (mqttPort != null && mqttPort > 0) ? mqttPort : null,
      mqttBrokerUser: p.getString(_kMqttUser),
      mqttBrokerPassword: p.getString(_kMqttPass),
    );
  }

  Future<void> setActiveFrameDeviceId(String deviceId) async {
    await load();
    final id = deviceId.trim();
    if (id.isEmpty || _indexOf(id) < 0) return;
    _activeDeviceId = id;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kActiveDeviceId, id);
    final a = cached;
    if (a != null) await _writeLegacyFromFrame(p, a);
    // iOS: donate a Siri/Shortcuts interaction so this frame surfaces as a
    // 1-tap target in the share sheet's top circular row (Frameo/QQ style).
    if (a != null) {
      final name = a.frameName?.trim().isNotEmpty == true
          ? a.frameName!.trim()
          : a.deviceId;
      final mac = macForPairedFrame(a) ?? a.deviceId;
      if (name.isNotEmpty && mac.isNotEmpty) {
        unawaited(
          FrameShortcutService.instance.donateFrame(
            frameName: name,
            frameMac: mac,
          ),
        );
      }
    }
  }

  /// Removes one frame and all persisted data tied to it (slideshow, MAC, legacy keys).
  Future<void> forgetPairedFrame(String deviceId) async {
    await load();
    final id = deviceId.trim();
    if (id.isEmpty) return;

    var idx = _indexOf(id);
    // Also match by normalized MAC when the list stores a related BLE/STA sibling.
    if (idx < 0) {
      final want = FrameMacUtil.normalizeSlug(id)?.toUpperCase() ?? id.toUpperCase();
      idx = _frames.indexWhere((e) {
        final k = FrameMacUtil.normalizeSlug(e.deviceId)?.toUpperCase() ??
            e.deviceId.trim().toUpperCase();
        if (k == want) return true;
        return _macsRelated(k, want);
      });
    }
    if (idx < 0) {
      // Still bump so UI refreshes after a no-op sibling sweep.
      _bumpRevision();
      return;
    }
    final removed = _frames[idx];

    final p = await SharedPreferences.getInstance();
    final macSlug = _macSlugForFrame(removed);
    await p.remove(
      await LocalStorageService.instance.slideshowScopedKey(macSlug),
    );
    await p.remove('slideshow_playlist_$macSlug');

    final removedKey =
        FrameMacUtil.normalizeSlug(removed.deviceId)?.toUpperCase() ??
            removed.deviceId.trim().toUpperCase();
    _frames.removeWhere((e) {
      final k = FrameMacUtil.normalizeSlug(e.deviceId)?.toUpperCase() ??
          e.deviceId.trim().toUpperCase();
      return _macsRelated(k, removedKey) || k == removedKey;
    });

    if (_frames.isEmpty) {
      await clear();
      return;
    }

    if (_activeDeviceId == null ||
        _activeDeviceId!.trim() == id ||
        _indexOf(_activeDeviceId!) < 0) {
      _activeDeviceId = _frames.first.deviceId;
    }

    final active = cached;
    if (active != null) {
      final mac = FrameMacUtil.macFromBleIdentity(
        bleName: active.bleNamePrefix,
        fallbackText: active.deviceId,
      );
      if (mac != null) {
        await savePairedFrameMac(mac);
      } else {
        _pairedFrameMac = null;
        await p.remove(kPairedFrameMac);
      }
    } else {
      _pairedFrameMac = null;
      await p.remove(kPairedFrameMac);
    }

    await _persistAll();
    _bumpRevision();
  }

  Future<void> removePairedFrame(String deviceId) =>
      forgetPairedFrame(deviceId);

  String _macSlugForFrame(PairedFrame f) {
    return macForPairedFrame(f) ??
        f.deviceId.replaceAll(RegExp(r'[^\w\-]'), 'FRAME');
  }

  Future<void> saveFromPayload(PairingPayload payload) async {
    await load();
    final rawId = payload.deviceId.trim();
    if (rawId.isEmpty) return;
    final id = PairedFrame.preferEsp32WifiStationMac(rawId) ?? rawId;
    final idx = _indexOf(id);
    final old = idx >= 0 ? _frames[idx] : null;
    final merged = PairedFrame(
      deviceId: id,
      pairingToken: payload.pairingToken ?? old?.pairingToken,
      apiUrl: payload.apiUrl ?? old?.apiUrl,
      bleServiceUuid: payload.bleServiceUuid ?? old?.bleServiceUuid,
      bleDataCharUuid: payload.bleDataCharUuid ?? old?.bleDataCharUuid,
      bleNamePrefix: payload.bleNamePrefix ?? old?.bleNamePrefix,
      bleRemoteId: old?.bleRemoteId,
      product: payload.product ?? old?.product,
      wifiSsid: old?.wifiSsid,
      wifiUsername: old?.wifiUsername,
      wifiPassword: old?.wifiPassword,
      wifiProvisionedAtMs: old?.wifiProvisionedAtMs,
      frameName: old?.frameName,
      frameOrientation: old?.frameOrientation,
      mqttBrokerHost: old?.mqttBrokerHost,
      mqttBrokerPort: old?.mqttBrokerPort,
      mqttBrokerUser: old?.mqttBrokerUser,
      mqttBrokerPassword: old?.mqttBrokerPassword,
    );
    if (idx >= 0) {
      _frames[idx] = merged;
    } else {
      _frames.add(merged);
    }
    _activeDeviceId = id;
    final mac = FrameMacUtil.macFromBleIdentity(
      bleName: merged.bleNamePrefix,
      fallbackText: id,
    );
    if (mac != null) await savePairedFrameMac(mac);
    await _persistAll();
    // Do NOT pushBoundFrame here — frame must finish Wi‑Fi + naming first.
  }

  Future<void> savePairedFrameMac(String mac) async {
    final slug = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    if (slug.length < 12) return;
    final bare = slug.length == 12 ? slug : slug.substring(slug.length - 12);
    // MQTT/API use Wi‑Fi station MAC; BLE names often carry BLE MAC (+2).
    final clean = PairedFrame.preferEsp32WifiStationMac(bare) ?? bare;
    _pairedFrameMac = clean;
    final p = await SharedPreferences.getInstance();
    await p.setString(kPairedFrameMac, clean);
  }

  Future<void> saveManualPairing({
    required String deviceId,
    String? bleNamePrefix,
    String? bleRemoteId,
  }) async {
    await load();
    final rawId = deviceId.trim();
    if (rawId.isEmpty) return;
    final fromName = FrameMacUtil.macFromBleName(bleNamePrefix ?? '');
    final fromRaw = FrameMacUtil.normalizeSlug(rawId);
    final hardware = fromName ?? fromRaw;
    if (hardware == null || hardware.length != 12) {
      // Refuse to persist iOS UUID as a frame id (creates ghost second cards).
      return;
    }
    final station = PairedFrame.preferEsp32WifiStationMac(hardware) ?? hardware;
    final idx = _indexOf(station);
    final old = idx >= 0 ? _frames[idx] : null;
    final merged = PairedFrame(
      deviceId: station,
      pairingToken: old?.pairingToken,
      apiUrl: old?.apiUrl,
      bleServiceUuid: old?.bleServiceUuid,
      bleDataCharUuid: old?.bleDataCharUuid,
      bleNamePrefix: bleNamePrefix?.trim().isNotEmpty == true
          ? bleNamePrefix!.trim()
          : old?.bleNamePrefix,
      bleRemoteId: bleRemoteId?.trim().isNotEmpty == true
          ? bleRemoteId!.trim()
          : (rawId.contains('-') ? rawId : old?.bleRemoteId),
      product: old?.product,
      wifiSsid: old?.wifiSsid,
      wifiUsername: old?.wifiUsername,
      wifiPassword: old?.wifiPassword,
      wifiProvisionedAtMs: old?.wifiProvisionedAtMs,
      frameName: old?.frameName,
      frameOrientation: old?.frameOrientation,
      mqttBrokerHost: old?.mqttBrokerHost,
      mqttBrokerPort: old?.mqttBrokerPort,
      mqttBrokerUser: old?.mqttBrokerUser,
      mqttBrokerPassword: old?.mqttBrokerPassword,
    );
    if (idx >= 0) {
      _frames[idx] = merged;
    } else {
      _frames.add(merged);
    }
    _activeDeviceId = station;
    await savePairedFrameMac(station);
    await _persistAll();
    await dedupeRelatedFrames();
    // iOS: donate a Siri/Shortcuts shortcut for the freshly paired frame so it
    // surfaces immediately in the share sheet's top circular row.
    final name = merged.frameName?.trim().isNotEmpty == true
        ? merged.frameName!.trim()
        : station;
    final mac = macForPairedFrame(merged) ?? station;
    if (name.isNotEmpty && mac.isNotEmpty) {
      unawaited(
        FrameShortcutService.instance.donateFrame(frameName: name, frameMac: mac),
      );
    }
    // Do NOT cloud-bind on BLE pair — wait until Wi‑Fi + name (saveFrameProfile).
  }

  Future<void> saveSelfHostedMqtt({
    required String host,
    int port = 1883,
    String user = '',
    String password = '',
  }) async {
    final c = cached;
    if (c == null) return;
    final cleanHost = host.trim();
    final updated = PairedFrame(
      deviceId: c.deviceId,
      pairingToken: c.pairingToken,
      apiUrl: c.apiUrl,
      bleServiceUuid: c.bleServiceUuid,
      bleDataCharUuid: c.bleDataCharUuid,
      bleNamePrefix: c.bleNamePrefix,
      bleRemoteId: c.bleRemoteId,
      product: c.product,
      wifiSsid: c.wifiSsid,
      wifiUsername: c.wifiUsername,
      wifiPassword: c.wifiPassword,
      wifiProvisionedAtMs: c.wifiProvisionedAtMs,
      frameName: c.frameName,
      frameOrientation: c.frameOrientation,
      mqttBrokerHost: cleanHost.isEmpty ? null : cleanHost,
      mqttBrokerPort: cleanHost.isEmpty ? null : port,
      mqttBrokerUser: cleanHost.isEmpty
          ? null
          : (user.trim().isEmpty ? null : user.trim()),
      mqttBrokerPassword: cleanHost.isEmpty
          ? null
          : (password.isEmpty ? null : password),
    );
    _replaceFrame(updated);
    await _persistAll();
  }

  Future<void> saveWifiProvision({
    required String ssid,
    String? username,
    String? password,
  }) async {
    final cleanSsid = normalizeWifiSsid(ssid);
    final cleanUser = username?.trim();
    final cleanPass = password ?? '';
    if (cleanSsid.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final c = cached;
    if (c == null) return;
    final updated = PairedFrame(
      deviceId: c.deviceId,
      pairingToken: c.pairingToken,
      apiUrl: c.apiUrl,
      bleServiceUuid: c.bleServiceUuid,
      bleDataCharUuid: c.bleDataCharUuid,
      bleNamePrefix: c.bleNamePrefix,
      bleRemoteId: c.bleRemoteId,
      product: c.product,
      wifiSsid: cleanSsid,
      wifiUsername: cleanUser,
      wifiPassword: cleanPass.isEmpty ? null : cleanPass,
      wifiProvisionedAtMs: now,
      frameName: c.frameName,
      frameOrientation: c.frameOrientation,
      mqttBrokerHost: c.mqttBrokerHost,
      mqttBrokerPort: c.mqttBrokerPort,
      mqttBrokerUser: c.mqttBrokerUser,
      mqttBrokerPassword: c.mqttBrokerPassword,
    );
    _replaceFrame(updated);
    await _persistAll();
    if (cleanPass.isNotEmpty) {
      await WifiCredentialCache.instance.remember(cleanSsid, cleanPass);
    }
    // Bind as soon as Wi‑Fi is confirmed. Name can be filled later — waiting
    // for isReadyForAccountSync left a ~window where Home only trusted BLE,
    // then flipped "disconnected" when the ESP turned BLE off after Wi‑Fi.
    unawaited(
      AccountSyncService.instance.pushBoundFrame(
        updated.deviceId,
        setPrimary: true,
        frameName: updated.frameName,
        wifiSsid: updated.wifiSsid,
      ),
    );
  }

  /// Clears saved Wi‑Fi credentials after a failed provision attempt so the UI
  /// never shows a fake "connected" network name.
  Future<void> clearWifiProvision({String? deviceId}) async {
    await load();
    final id = (deviceId ?? _activeDeviceId ?? cached?.deviceId)?.trim();
    if (id == null || id.isEmpty) return;
    final i = _indexOf(id);
    if (i < 0) return;
    final c = _frames[i];
    if ((c.wifiSsid == null || c.wifiSsid!.trim().isEmpty) &&
        (c.wifiPassword == null || c.wifiPassword!.isEmpty) &&
        c.wifiProvisionedAtMs == null) {
      return;
    }
    _frames[i] = PairedFrame(
      deviceId: c.deviceId,
      pairingToken: c.pairingToken,
      apiUrl: c.apiUrl,
      bleServiceUuid: c.bleServiceUuid,
      bleDataCharUuid: c.bleDataCharUuid,
      bleNamePrefix: c.bleNamePrefix,
      bleRemoteId: c.bleRemoteId,
      product: c.product,
      wifiSsid: null,
      wifiUsername: null,
      wifiPassword: null,
      wifiProvisionedAtMs: null,
      frameName: c.frameName,
      frameOrientation: c.frameOrientation,
      mqttBrokerHost: c.mqttBrokerHost,
      mqttBrokerPort: c.mqttBrokerPort,
      mqttBrokerUser: c.mqttBrokerUser,
      mqttBrokerPassword: c.mqttBrokerPassword,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kWifiSsid);
    await prefs.remove(_kWifiUser);
    await prefs.remove(_kWifiPass);
    await prefs.remove(_kWifiProvisionedAt);
    await _persistAll();
    _bumpRevision();
  }

  Future<void> saveFrameProfile({
    required String frameName,
    required String orientation,
  }) async {
    final cleanName = frameName.trim();
    final cleanOrientation = orientation.trim().toLowerCase();
    if (cleanOrientation != 'portrait' && cleanOrientation != 'landscape') {
      return;
    }
    final c = cached;
    if (c == null) return;
    final storedName = cleanName.isEmpty ? null : cleanName;
    final updated = PairedFrame(
      deviceId: c.deviceId,
      pairingToken: c.pairingToken,
      apiUrl: c.apiUrl,
      bleServiceUuid: c.bleServiceUuid,
      bleDataCharUuid: c.bleDataCharUuid,
      bleNamePrefix: c.bleNamePrefix,
      bleRemoteId: c.bleRemoteId,
      product: c.product,
      wifiSsid: c.wifiSsid,
      wifiUsername: c.wifiUsername,
      wifiPassword: c.wifiPassword,
      wifiProvisionedAtMs: c.wifiProvisionedAtMs,
      frameName: storedName,
      frameOrientation: cleanOrientation,
      mqttBrokerHost: c.mqttBrokerHost,
      mqttBrokerPort: c.mqttBrokerPort,
      mqttBrokerUser: c.mqttBrokerUser,
      mqttBrokerPassword: c.mqttBrokerPassword,
    );
    _replaceFrame(updated);
    await _persistAll();
    _bumpRevision();
    // Cloud-bind only when Wi‑Fi is set AND a real name exists.
    if (updated.isReadyForAccountSync) {
      unawaited(
        AccountSyncService.instance.pushBoundFrame(
          updated.deviceId,
          setPrimary: true,
          frameName: storedName,
          wifiSsid: updated.wifiSsid,
        ),
      );
    }
  }

  /// Rename the active (or given) frame and push to account when ready.
  Future<void> updateFrameDisplayName(
    String frameName, {
    String? deviceId,
  }) async {
    await load();
    final id = (deviceId ?? _activeDeviceId ?? cached?.deviceId)?.trim();
    if (id == null || id.isEmpty) return;
    final i = _indexOf(id);
    if (i < 0) return;
    final c = _frames[i];
    final storedName = frameName.trim().isEmpty ? null : frameName.trim();
    final updated = PairedFrame(
      deviceId: c.deviceId,
      pairingToken: c.pairingToken,
      apiUrl: c.apiUrl,
      bleServiceUuid: c.bleServiceUuid,
      bleDataCharUuid: c.bleDataCharUuid,
      bleNamePrefix: c.bleNamePrefix,
      bleRemoteId: c.bleRemoteId,
      product: c.product,
      wifiSsid: c.wifiSsid,
      wifiUsername: c.wifiUsername,
      wifiPassword: c.wifiPassword,
      wifiProvisionedAtMs: c.wifiProvisionedAtMs,
      frameName: storedName,
      frameOrientation: c.frameOrientation,
      mqttBrokerHost: c.mqttBrokerHost,
      mqttBrokerPort: c.mqttBrokerPort,
      mqttBrokerUser: c.mqttBrokerUser,
      mqttBrokerPassword: c.mqttBrokerPassword,
    );
    _frames[i] = updated;
    await _persistAll();
    _bumpRevision();
    // Always persist the custom name server-side so it survives app reinstall /
    // fresh login / device resync. `pushBoundFrame` stores the name alongside
    // the frame even when Wi‑Fi SSID is empty or still being provisioned.
    if (updated.deviceId.trim().isNotEmpty) {
      await AccountSyncService.instance.pushBoundFrame(
        updated.deviceId,
        setPrimary: true,
        frameName: storedName,
        wifiSsid: updated.wifiSsid,
      );
    }
  }

  void _replaceFrame(PairedFrame u) {
    final i = _indexOf(u.deviceId);
    if (i >= 0) _frames[i] = u;
  }

  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    _frames = [];
    _activeDeviceId = null;
    _pairedFrameMac = null;
    await p.remove(_kFramesJson);
    await p.remove(_kActiveDeviceId);
    await p.remove(kPairedFrameMac);
    await _removeAllLegacy(p);
    _bumpRevision();
  }

  Future<void> _persistAll() async {
    final p = await SharedPreferences.getInstance();
    if (_frames.isEmpty) {
      _activeDeviceId = null;
      await p.remove(_kFramesJson);
      await p.remove(_kActiveDeviceId);
      await _removeAllLegacy(p);
      return;
    }
    await p.setString(
      _kFramesJson,
      jsonEncode(_frames.map((e) => e.toJson()).toList()),
    );
    final a = cached;
    _activeDeviceId = a?.deviceId;
    if (_activeDeviceId != null && _activeDeviceId!.isNotEmpty) {
      await p.setString(_kActiveDeviceId, _activeDeviceId!);
    }
    if (a != null) await _writeLegacyFromFrame(p, a);
  }

  Future<void> _removeAllLegacy(SharedPreferences p) async {
    await p.remove(_kDeviceId);
    await p.remove(_kToken);
    await p.remove(_kApiUrl);
    await p.remove(_kBleService);
    await p.remove(_kBleData);
    await p.remove(_kBleNamePrefix);
    await p.remove(_kBleRemoteId);
    await p.remove(_kProduct);
    await p.remove(_kWifiSsid);
    await p.remove(_kWifiUser);
    await p.remove(_kWifiPass);
    await p.remove(_kWifiProvisionedAt);
    await p.remove(_kFrameName);
    await p.remove(_kFrameOrientation);
    await p.remove(_kMqttHost);
    await p.remove(_kMqttPort);
    await p.remove(_kMqttUser);
    await p.remove(_kMqttPass);
  }

  Future<void> _writeLegacyFromFrame(SharedPreferences p, PairedFrame f) async {
    await p.setString(_kDeviceId, f.deviceId);
    if (f.pairingToken != null && f.pairingToken!.isNotEmpty) {
      await p.setString(_kToken, f.pairingToken!);
    } else {
      await p.remove(_kToken);
    }
    if (f.apiUrl != null && f.apiUrl!.isNotEmpty) {
      await p.setString(_kApiUrl, f.apiUrl!);
    } else {
      await p.remove(_kApiUrl);
    }
    if (f.bleServiceUuid != null && f.bleServiceUuid!.isNotEmpty) {
      await p.setString(_kBleService, f.bleServiceUuid!);
    } else {
      await p.remove(_kBleService);
    }
    if (f.bleDataCharUuid != null && f.bleDataCharUuid!.isNotEmpty) {
      await p.setString(_kBleData, f.bleDataCharUuid!);
    } else {
      await p.remove(_kBleData);
    }
    if (f.bleNamePrefix != null && f.bleNamePrefix!.isNotEmpty) {
      await p.setString(_kBleNamePrefix, f.bleNamePrefix!);
    } else {
      await p.remove(_kBleNamePrefix);
    }
    if (f.bleRemoteId != null && f.bleRemoteId!.isNotEmpty) {
      await p.setString(_kBleRemoteId, f.bleRemoteId!);
    } else {
      await p.remove(_kBleRemoteId);
    }
    if (f.product != null && f.product!.isNotEmpty) {
      await p.setString(_kProduct, f.product!);
    } else {
      await p.remove(_kProduct);
    }
    if (f.wifiSsid != null && f.wifiSsid!.isNotEmpty) {
      await p.setString(_kWifiSsid, f.wifiSsid!);
    } else {
      await p.remove(_kWifiSsid);
    }
    if (f.wifiUsername != null && f.wifiUsername!.isNotEmpty) {
      await p.setString(_kWifiUser, f.wifiUsername!);
    } else {
      await p.remove(_kWifiUser);
    }
    if (f.wifiPassword != null && f.wifiPassword!.isNotEmpty) {
      await p.setString(_kWifiPass, f.wifiPassword!);
    } else {
      await p.remove(_kWifiPass);
    }
    if (f.wifiProvisionedAtMs != null) {
      await p.setInt(_kWifiProvisionedAt, f.wifiProvisionedAtMs!);
    } else {
      await p.remove(_kWifiProvisionedAt);
    }
    if (f.frameName != null && f.frameName!.isNotEmpty) {
      await p.setString(_kFrameName, f.frameName!);
    } else {
      await p.remove(_kFrameName);
    }
    if (f.frameOrientation != null && f.frameOrientation!.isNotEmpty) {
      await p.setString(_kFrameOrientation, f.frameOrientation!);
    } else {
      await p.remove(_kFrameOrientation);
    }
    if (f.mqttBrokerHost != null && f.mqttBrokerHost!.trim().isNotEmpty) {
      await p.setString(_kMqttHost, f.mqttBrokerHost!.trim());
      await p.setInt(_kMqttPort, f.mqttBrokerPort ?? 1883);
      if (f.mqttBrokerUser != null && f.mqttBrokerUser!.isNotEmpty) {
        await p.setString(_kMqttUser, f.mqttBrokerUser!);
      } else {
        await p.remove(_kMqttUser);
      }
      if (f.mqttBrokerPassword != null && f.mqttBrokerPassword!.isNotEmpty) {
        await p.setString(_kMqttPass, f.mqttBrokerPassword!);
      } else {
        await p.remove(_kMqttPass);
      }
    } else {
      await p.remove(_kMqttHost);
      await p.remove(_kMqttPort);
      await p.remove(_kMqttUser);
      await p.remove(_kMqttPass);
    }
  }
}

class PairedFrame {
  const PairedFrame({
    required this.deviceId,
    this.pairingToken,
    this.apiUrl,
    this.bleServiceUuid,
    this.bleDataCharUuid,
    this.bleNamePrefix,
    this.bleRemoteId,
    this.product,
    this.wifiSsid,
    this.wifiUsername,
    this.wifiPassword,
    this.wifiProvisionedAtMs,
    this.frameName,
    this.frameOrientation,
    this.mqttBrokerHost,
    this.mqttBrokerPort,
    this.mqttBrokerUser,
    this.mqttBrokerPassword,
  });

  final String deviceId;
  final String? pairingToken;
  final String? apiUrl;
  final String? bleServiceUuid;
  final String? bleDataCharUuid;
  final String? bleNamePrefix;
  final String? bleRemoteId;
  final String? product;
  final String? wifiSsid;
  final String? wifiUsername;
  final String? wifiPassword;
  final int? wifiProvisionedAtMs;
  final String? frameName;
  final String? frameOrientation;

  final String? mqttBrokerHost;
  final int? mqttBrokerPort;
  final String? mqttBrokerUser;
  final String? mqttBrokerPassword;

  /// Candidate backend targets in priority order (Wi‑Fi / MQTT MAC first).
  ///
  /// ESP32-class frames use BLE MAC = station MAC + 2 (e.g. BLE `…161E`, MQTT
  /// `…161C`). iOS often stores the QR/BLE id plus a CoreBluetooth UUID in
  /// [bleRemoteId]; uploads must target the station MAC, then retry the BLE id.
  List<String> get resolvedFrameTargetCandidates {
    final id = deviceId.trim();
    final ble = bleRemoteId?.trim() ?? '';
    final nameMac = _macFromText(bleNamePrefix ?? '');
    final idMac = _normalizedHexMac(id);
    final bleMac = _normalizedHexMac(ble);
    final out = <String>[];

    void add(String? value) {
      if (value == null) return;
      final v = value.trim().toUpperCase();
      if (v.length != 12 || out.contains(v)) return;
      out.add(v);
    }

    // The backend resolves explicitly observed BLE/STA aliases. Do not
    // probe neighboring addresses, which can belong to another frame.
    for (final mac in [idMac, nameMac, bleMac]) {
      add(mac);
    }

    if (out.isEmpty &&
        id.isNotEmpty &&
        !_looksLikeIosPeripheralUuid(id) &&
        !_looksLikeIosPeripheralUuid(ble)) {
      add(id.toUpperCase());
    }
    return out;
  }

  /// Upload targets: station (Wi‑Fi/MQTT) MAC only when it is already known.
  ///
  /// Retrying the BLE (+2) MAC after a timeout publishes to `/myframe/…161E`
  /// where no subscriber exists — Android avoids that; iOS must match.
  List<String> get resolvedFrameUploadTargets {
    final station = resolvedFrameTargetId;
    final all = resolvedFrameTargetCandidates;
    if (all.isEmpty) return const [];
    if (all.length == 1) return all;
    if (all.first == station) return [station];
    return all;
  }

  /// For backend frame commands, target the Wi-Fi/MQTT MAC rather than the BLE MAC.
  String get resolvedFrameTargetId {
    final ownMac = DeviceStore.macForPairedFrame(this);
    if (ownMac != null) return ownMac;
    final ids = resolvedFrameTargetCandidates;
    if (ids.isNotEmpty) return ids.first;
    final id = deviceId.trim();
    final ble = bleRemoteId?.trim() ?? '';
    return id.isNotEmpty ? id : ble;
  }

  /// Best-effort Wi‑Fi station MAC for uploads/MQTT from a 12‑hex id.
  /// When [fromBleAdvertisement] is true, apply ESP32 BLE→STA (−2).
  /// Otherwise leave the MAC unchanged (callers try ±2 siblings for status).
  static String? preferEsp32WifiStationMac(
    String raw, {
    bool fromBleAdvertisement = false,
  }) {
    final n = _normalizedHexMac(raw);
    if (n == null) return null;
    if (fromBleAdvertisement) {
      return _esp32WifiMacFromBleMac(n) ?? n;
    }
    return n;
  }

  static String? _normalizedHexMac(String raw) {
    final hex = raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
    if (hex.length != 12) return null;
    return hex;
  }

  static String? _esp32WifiMacFromBleMac(String bleMac) {
    final value = int.tryParse(bleMac, radix: 16);
    if (value == null || value < 2) return null;
    return (value - 2).toRadixString(16).toUpperCase().padLeft(12, '0');
  }

  static String? _macFromText(String raw) {
    final upper = raw.toUpperCase();
    if (_looksLikeIosPeripheralUuid(upper)) return null;
    final separated = RegExp(
      r'(?<![0-9A-F])([0-9A-F]{2}[:-]){5}[0-9A-F]{2}(?![0-9A-F])',
    ).firstMatch(upper)?.group(0);
    if (separated != null) {
      return separated.replaceAll(RegExp(r'[^0-9A-F]'), '');
    }
    return RegExp(
      r'(?<![0-9A-F])[0-9A-F]{12}(?![0-9A-F])',
    ).firstMatch(upper)?.group(0);
  }

  static bool _looksLikeIosPeripheralUuid(String raw) {
    return RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(raw.trim());
  }

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'pairingToken': pairingToken,
    'apiUrl': apiUrl,
    'bleServiceUuid': bleServiceUuid,
    'bleDataCharUuid': bleDataCharUuid,
    'bleNamePrefix': bleNamePrefix,
    'bleRemoteId': bleRemoteId,
    'product': product,
    'wifiSsid': wifiSsid,
    'wifiUsername': wifiUsername,
    'wifiPassword': wifiPassword,
    'wifiProvisionedAtMs': wifiProvisionedAtMs,
    'frameName': frameName,
    'frameOrientation': frameOrientation,
    'mqttBrokerHost': mqttBrokerHost,
    'mqttBrokerPort': mqttBrokerPort,
    'mqttBrokerUser': mqttBrokerUser,
    'mqttBrokerPassword': mqttBrokerPassword,
  };

  factory PairedFrame.fromJson(Map<String, dynamic> m) {
    final port = m['mqttBrokerPort'];
    return PairedFrame(
      deviceId: '${m['deviceId'] ?? ''}'.trim(),
      pairingToken: m['pairingToken'] as String?,
      apiUrl: m['apiUrl'] as String?,
      bleServiceUuid: m['bleServiceUuid'] as String?,
      bleDataCharUuid: m['bleDataCharUuid'] as String?,
      bleNamePrefix: m['bleNamePrefix'] as String?,
      bleRemoteId: m['bleRemoteId'] as String?,
      product: m['product'] as String?,
      wifiSsid: m['wifiSsid'] as String?,
      wifiUsername: m['wifiUsername'] as String?,
      wifiPassword: m['wifiPassword'] as String?,
      wifiProvisionedAtMs: (m['wifiProvisionedAtMs'] as num?)?.toInt(),
      frameName: m['frameName'] as String?,
      frameOrientation: m['frameOrientation'] as String?,
      mqttBrokerHost: m['mqttBrokerHost'] as String?,
      mqttBrokerPort: port is int ? port : (port is num ? port.toInt() : null),
      mqttBrokerUser: m['mqttBrokerUser'] as String?,
      mqttBrokerPassword: m['mqttBrokerPassword'] as String?,
    );
  }

  bool get hasApiUrl =>
      apiUrl != null &&
      apiUrl!.trim().isNotEmpty &&
      !ApiConfig.isLoopbackApiBase(apiUrl!);

  String? get resolvedApiBaseUrl {
    final id = deviceId.trim();
    if (id.isEmpty) return null;

    final raw = apiUrl?.trim();
    if (raw != null && raw.isNotEmpty && !ApiConfig.isLoopbackApiBase(raw)) {
      return VpsDefaults.coerceUploadBaseUri(raw);
    }

    final h = mqttBrokerHost?.trim();
    if (h != null && h.isNotEmpty) {
      if (VpsDefaults.shouldUseIpInsteadOfHostname(h)) {
        return VpsDefaults.apiBase;
      }
      return 'http://$h:${VpsDefaults.apiPort}';
    }

    return VpsDefaults.apiBase;
  }

  bool get canUploadToServer =>
      resolvedApiBaseUrl != null && resolvedFrameTargetCandidates.isNotEmpty;

  String? get resolvedPairingToken {
    final t = pairingToken?.trim();
    if (t != null && t.isNotEmpty) return t;
    return VpsDefaults.pairingToken;
  }

  bool get isWifiProvisioned => wifiSsid != null && wifiSsid!.trim().isNotEmpty;

  /// Ready to appear on other signed-in devices (Wi‑Fi + real name).
  bool get isReadyForAccountSync {
    final name = frameName?.trim() ?? '';
    final ssid = wifiSsid?.trim() ?? '';
    if (name.isEmpty || ssid.isEmpty) return false;
    if (name.toLowerCase() == ssid.toLowerCase()) return false;
    return true;
  }

  /// List row / editor labels when [frameName] is unset (avoids raw BLE MAC like `D0:CF:…`).
  String listDisplayTitle(AppStrings s) {
    final n = frameName?.trim();
    if (n != null && n.isNotEmpty) return n;
    return s.frameDefaultDisplayName;
  }
}
