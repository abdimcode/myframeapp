import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/vps_defaults.dart';
import '../l10n/app_strings.dart';
import '../models/pairing_nav_result.dart';
import '../services/account_sync_service.dart';
import '../services/auth_session_manager.dart';
import '../services/blufi_provisioning_service.dart';
import '../services/device_store.dart';
import '../services/frame_api_client.dart';
import '../services/frame_mac_util.dart';
import '../services/wifi_credential_cache.dart';
import 'frame_profile_setup_screen.dart';
import '../services/permission_gate.dart';
import '../navigation/pairing_flow_nav.dart';
import '../services/app_diag_log.dart';
import 'package:shared_preferences/shared_preferences.dart';
// import '../widgets/debug_slog_overlay.dart';
import '../widgets/progress_action_button.dart';
import '../widgets/shell_navigation.dart';
import '../widgets/wifi_password_guide_overlay.dart';

const _kRed = Color(0xFFE5252A);

class WifiProvisionScreen extends StatefulWidget {
  const WifiProvisionScreen({
    super.key,
    this.firstTimeSetup = false,
    this.serverConfigAlreadySent = false,
    this.openSendAfterSetup = true,
    this.initialDevice,
  });

  final bool firstTimeSetup;
  final bool serverConfigAlreadySent;
  final bool openSendAfterSetup;

  /// The live BLE handle established by the discovery screen's handshake.
  /// When present, [BlufiProvisioningService] reuses this warm connection
  /// instead of re-scanning, which is what made the very first attempt fail.
  final BluetoothDevice? initialDevice;

  @override
  State<WifiProvisionScreen> createState() => _WifiProvisionScreenState();
}

class _WifiProvisionScreenState extends State<WifiProvisionScreen> {
  static const MethodChannel _nativeBleMethod = MethodChannel('myframe/native_ble/methods');
  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _scrollController = ScrollController();

  List<({String ssid, int rssi, bool secure})> _wifiNetworks = [];
  String? _selectedSsid;
  bool _scanningWifi = false;

  /// Bumped on every scan start; stale async results whose generation is
  /// behind the latest scan are dropped so overlapping scans never clobber
  /// the freshly returned list.
  int _wifiScanEpoch = 0;
  bool _busy = false;
  bool _hide = true;
  bool _selectedIsOpen = false;
  String? _status;
  String? _error;
  bool _wifiConfirmed = false;
  String? _currentWifiSsid;
  String? _frameMac;
  bool _isAuthError = false;

  /// Coach mark for the Wi‑Fi password field. [GlobalKey] anchors the
  /// spotlight cutout to the password input; [FocusNode] receives focus after
  /// the guide is dismissed so the keyboard opens.
  final _passwordFocusNode = FocusNode();
  final _passwordFieldKey = GlobalKey();
  bool _showPasswordGuide = false;
  OverlayEntry? _guideOverlay;

  @override
  void initState() {
    super.initState();
    final paired = DeviceStore.instance.cached;
    if (paired != null) {
      // Prefill SSID only — never password; never auto-connect.
      _ssidCtrl.text = normalizeWifiSsid(paired.wifiSsid);
      _frameMac = paired.deviceId;
    }
    // Adopt the discovery screen's MAC immediately so the header is correct and
    // "Connect now" always has a valid target even before DeviceStore refreshes.
    if (_frameMac == null || _frameMac!.isEmpty) {
      final devMac = widget.initialDevice?.remoteId.str;
      if (devMac != null && devMac.isNotEmpty) _frameMac = devMac;
    }
    _passCtrl.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_scanWifiNetworks());
      unawaited(_maybeShowPasswordGuideOnEntry());
    });
  }

  @override
  void dispose() {
    _removeGuideOverlay();
    _passwordFocusNode.dispose();
    _scrollController.dispose();
    _ssidCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  static const _kSeenPasswordGuide = 'has_seen_wifi_password_guide';

  /// The in-flow bouncing hand/pill coach ([WifiPasswordCoachMark]) is the
  /// primary guidance now, so we no longer auto-open the full-screen spotlight
  /// on entry (it would cover the pill). The spotlight is still used as the
  /// defensive guide when the user taps Connect on a secured network with an
  /// empty password (see `_connectInner`).
  Future<void> _maybeShowPasswordGuideOnEntry() async {
    return;
  }

  void _presentPasswordGuide() {
    if (_showPasswordGuide || !mounted) return;
    // Guard: the password field must be laid out to anchor the spotlight.
    if (_passwordFieldKey.currentContext?.findRenderObject() == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_showPasswordGuide && _passwordFieldKey.currentContext != null) {
          _presentPasswordGuide();
        }
      });
      if (_passwordFieldKey.currentContext == null) return;
    }
    _showPasswordGuide = true;
    setState(() {});
    _guideOverlay = WifiPasswordGuideOverlay.build(
      context: context,
      targetKey: _passwordFieldKey,
      onDismiss: _dismissPasswordGuide,
    );
    Overlay.of(context, rootOverlay: true).insert(_guideOverlay!);
  }

  void _dismissPasswordGuide() {
    // Persist the seen-flag so the guide only auto-shows once.
    unawaited(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSeenPasswordGuide, true);
    }());
    _removeGuideOverlay();
    if (!mounted) return;
    setState(() => _showPasswordGuide = false);
    // Auto-focus so the cursor blinks + keyboard opens.
    _passwordFocusNode.requestFocus();
  }

  void _removeGuideOverlay() {
    _guideOverlay?.remove();
    _guideOverlay = null;
    _showPasswordGuide = false;
  }

  Future<void> _scanWifiNetworks() async {
    final epoch = ++_wifiScanEpoch;
    setState(() {
      _scanningWifi = true;
      _status = null;
      _error = null;
    });
    try {
      try {
        await PermissionGate.locationWhenInUse();
        if (Platform.isAndroid) {
          await PermissionGate.nearbyWifiDevices();
          final loc = await Permission.locationWhenInUse.status;
          final nearby = await Permission.nearbyWifiDevices.status;
          if (!loc.isGranted && !loc.isLimited && !nearby.isGranted) {
            await PermissionGate.enqueueLocationCoarse();
          }
          final loc2 = await Permission.locationWhenInUse.status;
          final nearby2 = await Permission.nearbyWifiDevices.status;
          if (!loc2.isGranted && !loc2.isLimited && !nearby2.isGranted) {
            if (!mounted || epoch != _wifiScanEpoch) return;
            setState(() {
              _error = AppStrings.of(context).wifiScanPermissionHint;
            });
          }
        }
      } catch (_) {}

      final info = await _nativeBleMethod
          .invokeMethod<Map<dynamic, dynamic>>('getWifiInfo')
          .timeout(const Duration(seconds: 10));
      var currentSsid = normalizeWifiSsid(info?['ssid']?.toString() ?? '');
      
      // Fallback: use network_info_plus if native method returns empty/unknown SSID
      if (currentSsid.isEmpty || currentSsid == '<unknown ssid>') {
        try {
          final networkInfo = NetworkInfo();
          final fallbackSsid = await networkInfo.getWifiName();
          if (fallbackSsid != null && fallbackSsid.isNotEmpty) {
            // Clean OS wrapping quotes if present (e.g., '"MyHome_5G"' -> 'MyHome_5G')
            currentSsid = normalizeWifiSsid(fallbackSsid.replaceAll('"', ''));
          }
        } catch (e) {
          AppDiagLog.verbose('[WiFi] network_info_plus fallback failed: $e');
        }
      }
      
      if (currentSsid.isNotEmpty && currentSsid != '<unknown ssid>') {
        if (!mounted || epoch != _wifiScanEpoch) return;
        setState(() {
          _currentWifiSsid = currentSsid;
          if (_ssidCtrl.text.trim().isEmpty) {
            _ssidCtrl.text = currentSsid;
            _selectedSsid = currentSsid;
          }
        });
      }

      // iOS: no public nearby-SSID API — current network + manual entry only.
      if (!Platform.isAndroid) {
        if (!mounted || epoch != _wifiScanEpoch) return;
        setState(() {
          _wifiNetworks = const [];
          _scanningWifi = false;
        });
        return;
      }

      final wifiEnabled = info?['enabled'] == true;
      if (!wifiEnabled) {
        if (!mounted || epoch != _wifiScanEpoch) return;
        setState(() {
          _wifiNetworks = const [];
          _selectedSsid = null;
          _scanningWifi = false;
        });
        return;
      }

      AppDiagLog.verbose('[WiFi] scan start');
      var raw = await _nativeBleMethod
          .invokeMethod<List<dynamic>>('scanWifiNetworks')
          // Android startScan() can stall (throttle / lost SCAN_RESULTS broadcast);
          // never leave the spinner stuck or the next scan queued forever.
          .timeout(const Duration(seconds: 12)) ?? <dynamic>[];
      // One retry if the first pass returned empty (scan throttle / cold start).
      if (raw.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        raw = await _nativeBleMethod
            .invokeMethod<List<dynamic>>('scanWifiNetworks')
            .timeout(const Duration(seconds: 12)) ?? <dynamic>[];
      }
      final parsed = <({String ssid, int rssi, bool secure})>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final ssidRaw = item['ssid']?.toString() ?? '';
        final ssid = normalizeWifiSsid(ssidRaw);
        if (ssid.isEmpty) continue;
        parsed.add((
          ssid: ssid,
          rssi: (item['rssi'] as num?)?.toInt() ?? -127,
          secure: item['secure'] == true,
        ));
      }
      // A newer scan started while this one was in flight — drop these results.
      if (!mounted || epoch != _wifiScanEpoch) return;
      setState(() {
        _wifiNetworks = parsed;
      });
      AppDiagLog.verbose('[WiFi] scan done count=${parsed.length}');
    } catch (_) {
      if (!mounted || epoch != _wifiScanEpoch) return;
    } finally {
      if (mounted && epoch == _wifiScanEpoch) {
        setState(() => _scanningWifi = false);
      }
    }
  }

  void _onSelectNetwork(String ssid, bool secure) {
    if (_busy) return;
    setState(() {
      _selectedSsid = normalizeWifiSsid(ssid);
      _ssidCtrl.text = _selectedSsid!;
      _selectedIsOpen = !secure;
      _error = null;
      _status = null;
    });
    // Never auto-fill password — user types it (or leaves blank for open Wi‑Fi).
    _passCtrl.clear();
  }

  Widget _signalBar(int rssi) {
    final t = ((rssi + 100) / 60).clamp(0.0, 1.0);
    final filled = (t * 4).round().clamp(0, 4);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(4, (i) {
        final on = i < filled;
        return Container(
          width: 6,
          height: 12,
          margin: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
            color: on ? _kRed : const Color(0xFFEEEEEE),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    );
  }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    try {
      await _connectInner();
    } catch (e, st) {
      AppDiagLog.verbose('[WiFi] connect failed: $e\n$st');
      await DeviceStore.instance.clearWifiProvision();
      if (!mounted) return;
      final s = AppStrings.of(context);
      setState(() {
        _busy = false;
        _wifiConfirmed = false;
        _status = null;
        _error = AppDiagLog.userFacingStatus(
          e.toString(),
          fallback: s.wifiConnectionFailed,
        );
      });
    } finally {
      // Ensure 401 handling is re-enabled even if pairing fails.
      AuthSessionManager.instance.suppressUnauthorizedHandling(false);
    }
  }

  Future<void> _connectInner() async {
    // Suppress 401 handling during the entire pairing flow (WiFi provisioning +
    // profile setup) so transient 401s from pairing endpoints don't log the user
    // out. The AuthSessionManager will not reset the session while this is true.
    AuthSessionManager.instance.suppressUnauthorizedHandling(true);
    try {
      final s = AppStrings.of(context);
      var paired = DeviceStore.instance.cached;
      final currentSsid = normalizeWifiSsid(_ssidCtrl.text);
      // Password is only what the user typed — never cached/saved auto-fill.
      // Trim only trailing/leading spaces; empty string = open network.
      final effectivePassword = _passCtrl.text;
      final match = _wifiNetworks.where(
        (n) => wifiSsidEquals(n.ssid, currentSsid),
      );
      final listedSecure = match.isNotEmpty && match.first.secure;
      // Prefer explicit open selection / blank password over a flaky scan "secure" bit.
      final treatAsOpen =
          _selectedIsOpen || (!listedSecure && effectivePassword.isEmpty);
      if (currentSsid.isEmpty) {
        setState(() {
          _error = s.wifiSsidRequired;
        });
        return;
      }
      if (listedSecure && !treatAsOpen && effectivePassword.isEmpty) {
        // Defensive coach-mark: guide the user to the password field instead
        // of only showing an error, while keeping the error visible.
        setState(() {
          _error = s.wifiRequiresPasswordError;
        });
        _presentPasswordGuide();
        return;
      }

      setState(() {
        _busy = true;
        _error = null;
        _status = s.connectingWifi;
        _wifiConfirmed = false;
      });

      // Carry the discovery screen's warm BLE handle into provisioning so it
      // reuses the established GATT connection instead of re-scanning. This is
      // the core fix for the first-attempt pairing race (see _selectRow).
      final blufi = BlufiProvisioningService.instance;
      if (widget.initialDevice != null) {
        blufi.activeDevice = widget.initialDevice;
      }
      final warmDevice = blufi.activeDevice;

      // Defensive guard: the BLE link can drop while the user is typing
      // credentials. If we hold a warm handle, attempt a non-blocking
      // auto-reconnect before failing, so the "No frame paired yet" banner is
      // only shown when the device is genuinely unreachable — not because of an
      // unawaited future or a transient drop.
      if (warmDevice != null) {
        final reachable = await blufi.ensureActiveDeviceConnected();
        if (!reachable) {
          setState(() {
            _busy = false;
            _error = s.noFramePaired;
          });
          return;
        }
      }

      // Race guard: tapping "Connect" on a freshly scanned frame navigates
      // here BEFORE the selected frame has necessarily been committed to
      // DeviceStore (or the cached entry hasn't refreshed yet). The MAC is
      // already visible on this screen / carried by the warm BLE handle — adopt
      // it immediately so "Connect now" never throws "No frame paired yet"
      // while a valid target is in hand.
      if (paired == null) {
        final bluetoothMac =
            (warmDevice?.remoteId.str ??
                    widget.initialDevice?.remoteId.str ??
                    '')
                .trim();
        if (bluetoothMac.isNotEmpty) {
          final advName = (warmDevice?.advName ?? '').trim().isNotEmpty
              ? warmDevice!.advName.trim()
              : (widget.initialDevice?.advName ?? '').trim();
          await DeviceStore.instance.saveManualPairing(
            deviceId: bluetoothMac,
            bleNamePrefix: advName.isNotEmpty ? advName : bluetoothMac,
            bleRemoteId: bluetoothMac,
          );
          paired = DeviceStore.instance.cached;
        }
      }

      final nonNullPaired = paired;
      if (nonNullPaired == null) {
        // No frame identity persisted and nothing to recover — truly nothing
        // paired yet. (This is Wi‑Fi setup, not firmware management, so the
        // "pair to manage firmware" banner is intentionally not shown here.)
        setState(() {
          _busy = false;
          _error = s.noFramePaired;
        });
        return;
      }

      AppDiagLog.verbose(
        '[WiFi] connect start ssid="$currentSsid" pwdLen=${effectivePassword.length} open=$treatAsOpen',
      );

      final locale = ui.PlatformDispatcher.instance.locale;
      final countryCode = locale.countryCode?.trim().toUpperCase();
      final selfHostedMqtt = SelfHostedMqttConfig(
        host: VpsDefaults.host,
        port: VpsDefaults.mqttPort,
        user: VpsDefaults.mqttUser,
        password: VpsDefaults.mqttPass,
        countryCode: countryCode != null && RegExp(r'^[A-Z]{2}$').hasMatch(countryCode)
            ? countryCode
            : null,
        timezone: DateTime.now().timeZoneName,
        timezoneOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
      );

      final provision = await blufi.provision(
        paired: nonNullPaired,
        ssid: currentSsid,
        password: effectivePassword,
        selfHostedMqtt: selfHostedMqtt,
        serverConfigAlreadySent: widget.serverConfigAlreadySent,
        onStage: (stage) {
          if (!mounted) return;
          setState(() {
            _status = _pairingStageLabel(s, stage);
          });
        },
      );

      AppDiagLog.verbose(
        '[WiFi] provision result ok=${provision.ok} confirmed=${provision.confirmed} stage=${provision.stage} message="${provision.message}" errorType=${provision.errorType}',
      );

      if (!mounted) return;

      if (!provision.ok || !provision.confirmed) {
        // Radio-handover tolerance: after credentials are written the frame may
        // reboot its BLE radio to join Wi-Fi, dropping the GATT link BEFORE the
        // status ack arrives. Do NOT treat that as a Bluetooth failure — confirm
        // through the backend first.
        if (provision.stage == PairingStage.waitingFrameWifi) {
          setState(() => _status = s.pairingStageVerifyingCloud);
          final online = await _pollFrameOnlineAfterProvision(
            DeviceStore.macForPairedFrame(nonNullPaired) ?? nonNullPaired.deviceId,
            pairingToken: nonNullPaired.resolvedPairingToken,
          );
          if (!online) {
            await DeviceStore.instance.clearWifiProvision();
            if (!mounted) return;
            setState(() {
              _busy = false;
              _wifiConfirmed = false;
              _status = null;
              _error = s.pairingErrWaitingFrameWifi;
            });
            return;
          }
          // Frame IS online — fall through to the success path below.
        } else {
          // Never persist a failed SSID as "connected".
          await DeviceStore.instance.clearWifiProvision();
          if (!mounted) return;
          final isAuthError = provision.errorType == BlufiErrorType.authFailure;
          setState(() {
            _busy = false;
            _wifiConfirmed = false;
            _status = null;
            _isAuthError = isAuthError;
            _error = isAuthError
                ? s.pairingErrWaitingFrameWifi
                : _pairingStageError(s, provision.stage);
          });
          return;
        }
      }

      AppDiagLog.verbose('[WiFi] frame confirmed Wi‑Fi — saving SSID, opening profile setup…');
      await DeviceStore.instance.saveWifiProvision(
        ssid: currentSsid,
        password: effectivePassword,
      );

      // Manual pairing won ownership of this hardware — clear any unbound ban
      // from a prior unlink and claim/re-push the owner binding so the frame
      // works again without logging out.
      unawaited(
        AccountSyncService.instance.grantOwnerForManualPair(nonNullPaired.deviceId),
      );

      if (!mounted) return;
      setState(() {
        _wifiConfirmed = true;
        // Keep `_busy = true` so the spinner stays visible during the
        // post-provision server poll. The frame needs ~10–30s to associate
        // to Wi-Fi and send its first MQTT heartbeat — without this poll
        // we used to jump straight to profile setup while the backend
        // still reported `online: false`, which produced a spurious
        // "Frame not paired" error downstream.
        _status = s.frameConnectingToWifiHint;
      });

      // Poll the server until the frame appears online (or grace window
      // expires). NEVER surface an error dialog during this window — if the
      // backend reports `provisioning: true` it simply means the frame is
      // still booting Wi-Fi.
      final frameMac = DeviceStore.macForPairedFrame(nonNullPaired) ?? '';
      if (frameMac.isNotEmpty) {
        await _pollFrameOnlineAfterProvision(
          frameMac,
          pairingToken: nonNullPaired.resolvedPairingToken,
        );
      }

      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '${s.wifiConnectedTo} $currentSsid';
      });

      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;

      final profileOk = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => FrameProfileSetupScreen(
            requiredSetup: widget.firstTimeSetup,
          ),
        ),
      );

      if (!mounted) return;
      if (widget.firstTimeSetup) {
        // Redirect directly to the My Frames list (My Frames tab) so the freshly named
        // frame is immediately selected and shown as online, instead of going to Send tab gallery.
        final result = PairingNavResult(
          success: profileOk == true,
          openSendGallery: false,
        );
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop<PairingNavResult>(result);
        }
        // Always route to Registered Frames / My Frames (tab 0)
        ShellNavigation.completePairingAndShowFrames();
        return;
      }
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop<bool>(profileOk == true);
      }
    } finally {
      // Re-enable 401 handling now that pairing/profile setup is complete.
      AuthSessionManager.instance.suppressUnauthorizedHandling(false);
    }
  }

  /// After BluFi Wi‑Fi delivery succeeds, the frame needs ~10–30s to associate
  /// to Wi‑Fi and send its first MQTT heartbeat. During this window the
  /// backend returns `online: false` but also `provisioning: true` and
  /// `app_paired: true` — we MUST NOT treat that as "Frame not paired".
  ///
  /// This poll keeps the friendly "Connecting frame to Wi‑Fi…" spinner visible
  /// and only fails after the full grace window expires. Intermediate 404 /
  /// not-paired responses are suppressed; only a genuinely "never provisioned"
  /// response or a full timeout triggers the error dialog upstream.
  /// Localized progress label for a provisioning phase.
  String _pairingStageLabel(AppStrings s, PairingStage stage) {
    switch (stage) {
      case PairingStage.scanning:
        return s.pairingStageScanning;
      case PairingStage.connectingBle:
        return s.pairingStageConnectingBle;
      case PairingStage.discoveringServices:
        return s.pairingStageDiscovering;
      case PairingStage.sendingCredentials:
        return s.pairingStageSending;
      case PairingStage.waitingFrameWifi:
        return s.pairingStageWaitingWifi;
      case PairingStage.verifyingCloud:
        return s.pairingStageVerifyingCloud;
      case PairingStage.idle:
      case PairingStage.done:
      case PairingStage.unknown:
        return s.connectingWifi;
    }
  }

  /// Localized, actionable error for the phase that failed.
  String _pairingStageError(AppStrings s, PairingStage stage) {
    switch (stage) {
      case PairingStage.scanning:
        return s.pairingErrScanning;
      case PairingStage.connectingBle:
        return s.pairingErrConnectingBle;
      case PairingStage.discoveringServices:
        return s.pairingErrDiscovering;
      case PairingStage.sendingCredentials:
        return s.pairingErrSendingCredentials;
      case PairingStage.waitingFrameWifi:
        return s.pairingErrWaitingFrameWifi;
      case PairingStage.verifyingCloud:
        return s.pairingErrVerifyingCloud;
      case PairingStage.idle:
      case PairingStage.done:
      case PairingStage.unknown:
        return s.wifiConnectionFailed;
    }
  }

  Future<bool> _pollFrameOnlineAfterProvision(
    String mac, {
    String? pairingToken,
  }) async {
    const maxAttempts = 15; // 15 × 2s = 30s grace window
    const interval = Duration(seconds: 2);
    final client = FrameApiClient();
    try {
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        if (!mounted) return false;
        AppDiagLog.verbose(
          '[WiFi] post-provision poll attempt $attempt/$maxAttempts for $mac',
        );
        try {
          final status = await client.fetchFrameStatus(
            mac: mac,
            pairingToken: pairingToken,
            force: true,
          );
          if (status != null && status.isEffectivelyOnline) {
            AppDiagLog.verbose(
              '[WiFi] post-provision poll: frame is online after $attempt attempt(s)',
            );
            return true;
          }
          // While the backend reports the frame is in the provisioning
          // grace window, keep spinning silently.
          if (status == null || status.provisioning == true) {
            continue;
          }
        } catch (e) {
          AppDiagLog.verbose('[WiFi] post-provision poll: $e');
        }
        await Future<void>.delayed(interval);
      }
      AppDiagLog.verbose(
        '[WiFi] post-provision poll: grace window expired for $mac',
      );
      return false;
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final cs = Theme.of(context).colorScheme;
    final paired = DeviceStore.instance.cached;
    final rawMac = _frameMac ?? paired?.deviceId ?? '';
    final mac = rawMac.isNotEmpty ? FrameMacUtil.normalizeSlug(rawMac) ?? rawMac : '';

    // return DebugSlogOverlay(
    //   child: GestureDetector(
    return GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.opaque,
        child: Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(
          title: Text(s.wifiSetupTitle, style: const TextStyle(fontWeight: FontWeight.w700)),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0.5,
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  // Frame info strip
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: cs.outlineVariant),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.appName,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'MAC · ${mac.isNotEmpty ? mac : s.unknownLabel}',
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Wi‑Fi selection: current phone network + optional nearby list
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: cs.outlineVariant),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (Platform.isAndroid)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: (_busy || _scanningWifi) ? null : _scanWifiNetworks,
                              icon: _scanningWifi
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: _kRed,
                                      ),
                                    )
                                  : const Icon(Icons.refresh, size: 18, color: _kRed),
                              label: Text(
                                s.wifiRescanNetworks,
                                style: const TextStyle(
                                  color: _kRed,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              style: TextButton.styleFrom(
                                foregroundColor: _kRed,
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ),

                        // Current phone Wi‑Fi shortcut
                        if (_currentWifiSsid != null && _currentWifiSsid!.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: cs.outlineVariant),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        s.wifiCurrentNetwork,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: cs.onSurfaceVariant,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _currentWifiSsid!,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          color: cs.onSurface,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () {
                                    final ssid = _currentWifiSsid!;
                                    final match = _wifiNetworks.where(
                                      (n) => wifiSsidEquals(n.ssid, ssid),
                                    );
                                    final secure = match.isEmpty ? false : match.first.secure;
                                    _onSelectNetwork(ssid, secure);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: _kRed,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      s.wifiUseNetwork,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        else if (_scanningWifi)
                          Row(
                            children: [
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: _kRed,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                s.wifiScanningNetworks,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _kRed,
                                ),
                              ),
                            ],
                          ),

                        // Nearby networks (Android scan)
                        if (_wifiNetworks.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Text(
                            s.wifiNearbyNetworksTitle,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            constraints: const BoxConstraints(maxHeight: 200),
                            decoration: BoxDecoration(
                              border: Border.all(color: cs.outlineVariant),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: ListView.separated(
                              shrinkWrap: true,
                              padding: EdgeInsets.zero,
                              itemCount: _wifiNetworks.length,
                              separatorBuilder: (_, __) => Divider(
                                height: 1,
                                color: cs.outlineVariant,
                              ),
                              itemBuilder: (context, i) {
                                final n = _wifiNetworks[i];
                                final selected = wifiSsidEquals(_selectedSsid, n.ssid);
                                return InkWell(
                                  onTap: () => _onSelectNetwork(n.ssid, n.secure),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                    color: selected
                                        ? _kRed.withValues(alpha: 0.08)
                                        : Colors.transparent,
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                n.ssid,
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w700,
                                                  color: cs.onSurface,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                n.secure
                                                    ? s.wifiPasswordRequiredLabel
                                                    : s.wifiOpenNetworkLabel,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: cs.onSurfaceVariant,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        _signalBar(n.rssi),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // SSID + password inputs
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: cs.outlineVariant),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.wifiSsidLabel,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _ssidCtrl,
                          style: const TextStyle(fontSize: 15),
                          decoration: InputDecoration(
                            hintText: s.wifiSsidRequired,
                            filled: true,
                            fillColor: cs.surfaceContainerLow,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: cs.outlineVariant),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: cs.outlineVariant),
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            isDense: true,
                          ),
                        ),

                        const SizedBox(height: 16),

                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: _kRed.withValues(alpha: 0.28),
                              width: 1.5,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    s.wifiPasswordLabel,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: cs.onSurface,
                                    ),
                                  ),
                                  const Spacer(),
                                  GestureDetector(
                                    onTap: () => setState(() => _hide = !_hide),
                                    child: Text(
                                      _hide ? s.wifiShowPassword : s.wifiHidePassword,
                                      style: const TextStyle(
                                        color: _kRed,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                s.wifiRequiredForNetwork,
                                style: const TextStyle(
                                  color: _kRed,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              // Bouncing hand/pill coach: "Enter Wi-Fi password
                              // here". Always rendered while the field is empty
                              // and unfocused; auto-hides the moment the user
                              // focuses or types (independent of the one-time
                              // spotlight overlay above).
                              WifiPasswordCoachMark(
                                controller: _passCtrl,
                                focusNode: _passwordFocusNode,
                              ),
                              TextField(
                                key: _passwordFieldKey,
                                controller: _passCtrl,
                                focusNode: _passwordFocusNode,
                                obscureText: _hide,
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) => _connect(),
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                                decoration: InputDecoration(
                                  hintText: s.wifiPasswordRequired,
                                  filled: true,
                                  fillColor: cs.surface,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(
                                      color: _isAuthError ? _kRed : cs.outlineVariant,
                                      width: 1.5,
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(
                                      color: _isAuthError ? _kRed : cs.outlineVariant,
                                      width: 1.5,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(
                                      color: _isAuthError ? _kRed : cs.primary,
                                      width: 2,
                                    ),
                                  ),
                                  errorText: _isAuthError ? s.wifiIncorrectPassword : null,
                                  errorStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                  isDense: true,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                s.wifiLeaveBlankHint,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Status
                  if (_status != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: cs.outlineVariant),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                            Text(
                              _busy ? s.connectingWifi : s.statusLabel,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _status!,
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // Error
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _kRed.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _kRed.withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, size: 16, color: _kRed),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                fontSize: 12,
                                color: _kRed,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 16),
                ],
              ),
            ),
            // Bottom action bar
            Container(
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                16 + MediaQuery.of(context).padding.bottom,
              ),
              decoration: BoxDecoration(
                color: cs.surface,
                border: Border(top: BorderSide(color: cs.outlineVariant)),
              ),
              child: SafeArea(
                top: false,
                child: ProgressActionButton(
                  height: 52,
                  borderRadius: BorderRadius.circular(100),
                  backgroundColor: _kRed,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: _kRed.withValues(alpha: 0.45),
                  label: _wifiConfirmed
                      ? s.wifiConnectedLabel
                      : s.wifiConnectNowLabel,
                  isLoading: _busy,
                  statusMessage: (_status?.trim().isNotEmpty == true)
                      ? _status!.replaceAll(RegExp(r'[.…]+$'), '').trim()
                      : s.progressConfiguringFrameBusy,
                  progress: null,
                  onPressed: (_busy || _wifiConfirmed) ? null : _connect,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
