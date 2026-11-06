import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/models/convoy_model.dart';
import '../../../data/models/rider_model.dart';
import '../../../data/services/intercom_service.dart';

/// Full-width glove-friendly in-cockpit Push-To-Talk Intercom Bar.
///
/// Features:
/// - Glove-accessible 56 dp height with 16 dp rounded corners.
/// - Integrated audio waveform visualizer.
/// - Dynamic states: Idle (Teal), Transmitting (Amber with active glow),
///   Receiving (Teal border with speaker name), and Muted (tap to unmute).
/// - Instant press-and-hold recording via Pointer events with haptics.
class MinimalHoldToTalkBar extends StatefulWidget {
  final ConvoyModel convoy;
  final RiderModel me;

  const MinimalHoldToTalkBar({
    super.key,
    required this.convoy,
    required this.me,
  });

  @override
  State<MinimalHoldToTalkBar> createState() => _MinimalHoldToTalkBarState();
}

class _MinimalHoldToTalkBarState extends State<MinimalHoldToTalkBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _waveController;

  // Press tracking: a release before the mic finished opening still ends the
  // transmission, and a quick vertical swipe that starts on the bar (the rider
  // dragging the ride sheet up or down) does not keep the mic keyed.
  bool _pressed = false;
  bool _swipeCancelled = false;
  Offset? _downPos;
  DateTime? _downTime;

  @override
  void initState() {
    super.initState();
    // Runs only while someone is talking (see [_syncWave]): an always-running
    // ticker would redraw the cockpit every frame for nothing.
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  void _syncWave(bool active) {
    if (active) {
      if (!_waveController.isAnimating) _waveController.repeat(reverse: true);
    } else if (_waveController.isAnimating) {
      _waveController.stop();
    }
  }

  @override
  void dispose() {
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ic = context.watch<IntercomService?>();
    if (ic == null) return const SizedBox.shrink();

    final tx = ic.isTransmitting;
    final rx = ic.isReceiving;
    final muted = ic.isMicMuted;
    final private = ic.isPrivateTalk;
    final leadChannel = ic.channel == IntercomChannel.leadOnly;
    final vox = ic.mode == IntercomMode.vox;
    _syncWave(tx || rx);

    // Background color
    final Color bgColor;
    if (tx) {
      bgColor = private ? AppTheme.infoBlue : AppTheme.warnText;
    } else if (rx) {
      bgColor = const Color(0xFF0F766E);
    } else if (muted) {
      bgColor = AppTheme.card;
    } else if (vox) {
      bgColor = const Color(0xFF0F766E);
    } else if (leadChannel) {
      bgColor = AppTheme.warnText;
    } else {
      bgColor = AppTheme.brand;
    }

    // Label & Icon
    final String label;
    final IconData icon;
    if (tx) {
      label = private
          ? 'PRIVATE TALKING'
          : (leadChannel
              ? 'LEAD TALKING'
              : (vox ? 'HANDS-FREE · TALKING' : 'TALKING'));
      icon = Icons.mic_rounded;
    } else if (rx) {
      final who = ic.activeSpeakerName?.split(' ').first.toUpperCase() ?? 'RIDER';
      label = '$who SPEAKING';
      icon = Icons.volume_up_rounded;
    } else if (vox) {
      label = 'HANDS-FREE ACTIVE · TAP TO DISABLE';
      icon = Icons.record_voice_over_rounded;
    } else if (muted) {
      label = 'MIC MUTED · TAP TO UNMUTE';
      icon = Icons.mic_off_rounded;
    } else if (leadChannel) {
      label = 'LEAD & SWEEPER TALK';
      icon = Icons.shield_rounded;
    } else {
      label = 'HOLD TO TALK';
      icon = Icons.mic_rounded;
    }

    return Semantics(
      button: true,
      label: vox ? 'Hands-Free active. Tap to disable.' : label,
      child: Listener(
        onPointerDown: (e) async {
          if (vox) {
            HapticFeedback.lightImpact();
            await ic.disableHandsFree();
            if (context.mounted) {
              ScaffoldMessenger.of(context).clearSnackBars();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Hands-Free disabled · Switched to Hold-to-Talk'),
                  duration: Duration(seconds: 2),
                ),
              );
            }
            return;
          }
          if (muted) {
            HapticFeedback.lightImpact();
            ic.setMicMuted(false);
            return;
          }
          _pressed = true;
          _swipeCancelled = false;
          _downPos = e.position;
          _downTime = DateTime.now();
          HapticFeedback.selectionClick();
          final ok = await ic.beginTransmission();
          if (ok && (!_pressed || _swipeCancelled)) {
            // Released, or turned into a sheet drag, while the mic was opening.
            await ic.endTransmission();
            return;
          }
          if (!ok && !_swipeCancelled && context.mounted) {
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Cannot transmit: check microphone permission and connection.'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        },
        onPointerMove: (e) {
          final start = _downPos;
          final at = _downTime;
          if (!_pressed || _swipeCancelled || start == null || at == null) return;
          final dy = (e.position.dy - start.dy).abs();
          final dx = (e.position.dx - start.dx).abs();
          final vertical = dy > dx * 1.5;
          final quick = DateTime.now().difference(at) < const Duration(milliseconds: 350);
          // A quick vertical swipe, or a slow but long vertical drag (the ride
          // sheet already follows the finger past the drag slop), is the rider
          // moving the sheet, not holding to talk: the mic is let go. A press
          // that stays put (or drifts sideways) keeps transmitting.
          if (vertical && ((quick && dy > 24) || dy > 48)) {
            _swipeCancelled = true;
            if (ic.isTransmitting) ic.endTransmission();
          }
        },
        onPointerUp: (_) {
          final wasPressed = _pressed;
          _pressed = false;
          if (!vox && (tx || (wasPressed && ic.isTransmitting))) {
            HapticFeedback.selectionClick();
            ic.endTransmission();
          }
        },
        onPointerCancel: (_) {
          _pressed = false;
          if (!vox && (tx || ic.isTransmitting)) ic.endTransmission();
        },
        child: AnimatedContainer(
          duration: Motion.button,
          curve: Motion.curve,
          // At least 56 dp (gloves), growing with large text instead of clipping it.
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(16),
            border: muted
                ? Border.all(color: AppTheme.warnBorder, width: 2)
                : (tx
                    ? Border.all(color: Colors.white.withOpacity(0.4), width: 1.5)
                    : null),
            boxShadow: tx
                ? [
                    BoxShadow(
                      color: AppTheme.warnText.withOpacity(0.4),
                      blurRadius: 16,
                      spreadRadius: 2,
                    )
                  ]
                : (muted ? null : dsFloatingShadow()),
          ),
          child: Row(
            children: [
              Icon(icon, size: 24, color: muted ? AppTheme.warnText : Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: muted ? AppTheme.warnText : Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              if (vox) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  key: const Key('minimal_bar_disable_hands_free'),
                  onTap: () async {
                    HapticFeedback.lightImpact();
                    await ic.disableHandsFree();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white.withOpacity(0.4)),
                    ),
                    child: const Text(
                      'DISABLE',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              _AudioWaveformVisualizer(
                controller: _waveController,
                active: tx || rx,
                color: muted ? AppTheme.muted : Colors.white,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Visual audio waveform bars matching the cockpit PTT design.
class _AudioWaveformVisualizer extends StatelessWidget {
  final AnimationController controller;
  final bool active;
  final Color color;

  const _AudioWaveformVisualizer({
    required this.controller,
    required this.active,
    required this.color,
  });

  static const List<double> _baseHeights = [8, 14, 22, 16, 26, 18, 10];

  @override
  Widget build(BuildContext context) {
    if (!active) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final h in _baseHeights)
            Container(
              width: 3,
              height: h * 0.7,
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                color: color.withOpacity(0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      );
    }

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = controller.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < _baseHeights.length; i++) ...[
              Container(
                width: 3,
                height: (_baseHeights[i] * (0.5 + 0.5 * ((t + i * 0.15) % 1.0)))
                    .clamp(4.0, 26.0),
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
