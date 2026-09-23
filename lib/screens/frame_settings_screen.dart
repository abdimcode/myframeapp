import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/frame_playback_profile.dart';
import '../services/app_diag_log.dart';
import '../services/device_store.dart';
import '../services/frame_settings_store.dart';
import '../settings/app_settings.dart';
import '../widgets/playlist_controls_widget.dart';

/// Frame Profile — the global playback defaults owned by the frame
/// (interval / playback order / duration) that uploaded photos inherit.
///
/// Replaces the per-album playback configuration as the single unified source
/// for a frame's slideshow behavior.
class FrameSettingsScreen extends StatefulWidget {
  const FrameSettingsScreen({super.key, this.frame});
  final PairedFrame? frame;

  @override
  State<FrameSettingsScreen> createState() => _FrameSettingsScreenState();
}

class _FrameSettingsScreenState extends State<FrameSettingsScreen> {
  FramePlaybackProfile _profile = FramePlaybackProfile.externalShareDefaults;
  PairedFrame? _paired;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await DeviceStore.instance.load();
      final paired = widget.frame ?? DeviceStore.instance.cached;
      final profile = await FrameSettingsStore.instance.load(paired);
      if (!mounted) return;
      setState(() {
        _paired = paired;
        _profile = profile;
        _loading = false;
      });
    } catch (e, st) {
      AppDiagLog.verbose('[FrameSettings] load failed: $e\n$st');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final s = AppStrings.of(context);
    final app = AppSettingsScope.of(context);
    final paired = _paired;
    if (paired == null || _saving) return;

    setState(() => _saving = true);

    // Centered loading dialog HUD
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future.delayed(const Duration(milliseconds: 1000), () {
              if (dialogContext.mounted) {
                setDialogState(() {});
              }
            });
            return Center(
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 15,
                      offset: Offset(0, 5),
                    )
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 50,
                      height: 50,
                      child: CircularProgressIndicator(
                        strokeWidth: 4,
                        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFE53935)),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      s.authBusyLabel,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.black54,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    try {
      await FrameSettingsStore.instance.pushProfileToFrame(
        paired: paired,
        profile: _profile,
        userAuthToken: app.authToken,
      );

      // Close loading dialog and show success checkmark animation
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // pop loading HUD
      }

      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext successContext) {
          return Center(
            child: Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 15,
                    offset: Offset(0, 5),
                  )
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    size: 60,
                    color: Colors.green,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    s.frameProfileSaved,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.black54,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // pop success HUD
        Navigator.of(context).pop(); // go back
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          s.frameProfileNavTitle,
          style: TextStyle(fontWeight: FontWeight.bold, color: cs.onSurface),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _paired == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      s.frameProfileNeedsFrame,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  children: [
                    Text(
                      s.frameProfileIntro,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 20),
                    PlaylistControlsWidget(
                      selectedIntervalSeconds: _profile.intervalSeconds,
                      onIntervalChanged: (seconds) => setState(
                        () => _profile = _profile.copyWith(
                          intervalMinutes: seconds ~/ 60,
                        ),
                      ),
                      selectedStrategy: _profile.strategy,
                      onStrategyChanged: (v) => setState(
                        () => _profile = _profile.copyWith(
                          playbackMode: v == 2
                              ? FramePlaybackProfile.modeRandom
                              : FramePlaybackProfile.modeSequential,
                        ),
                      ),
                      selectedDurationHours: _profile.durationHours,
                      onDurationChanged: (v) => setState(
                        () => _profile = _profile.copyWith(durationHours: v),
                      ),
                    ),
                    const SizedBox(height: 28),
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(s.saveLabel),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
