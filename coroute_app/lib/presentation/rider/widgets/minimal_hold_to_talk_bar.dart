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

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
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

    // Background color
    final Color bgColor;
    if (tx) {
      bgColor = private ? AppTheme.infoBlue : AppTheme.warnText;
    } else if (rx) {
      bgColor = const Color(0xFF0F766E);
    } else if (muted) {
      bgColor = AppTheme.card;
    } else if (leadChannel) {
      bgColor = AppTheme.warnText;
    } else {
      bgColor = AppTheme.brand;
    }

    // Label & Icon
    final String label;
    final IconData icon;
    if (tx) {
      label = private ? 'PRIVATE TALKING' : (leadChannel ? 'LEAD TALKING' : 'TALKING');
      icon = Icons.mic_rounded;
    } else if (rx) {
      final who = ic.activeSpeakerName?.split(' ').first.toUpperCase() ?? 'RIDER';
      label = '$who SPEAKING';
      icon = Icons.volume_up_rounded;
    } else if (muted) {
      label = 'MIC MUTED · TAP TO UNMUTE';
      icon = Icons.mic_off_rounded;
    } else if (vox) {
      label = 'VOX ACTIVE (HANDS-FREE)';
      icon = Icons.record_voice_over_rounded;
    } else if (leadChannel) {
      label = 'LEAD & SWEEPER TALK';
      icon = Icons.shield_rounded;
    } else {
      label = 'HOLD TO TALK';
      icon = Icons.mic_rounded;
    }

    return Semantics(
      button: true,
      label: label,
      child: Listener(
        onPointerDown: (_) async {
          if (muted) {
            HapticFeedback.lightImpact();
            ic.setMicMuted(false);
            return;
          }
          if (vox) return;
          HapticFeedback.selectionClick();
          final ok = await ic.beginTransmission();
          if (!ok && context.mounted) {
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Cannot transmit: check microphone permission and connection.'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        },
        onPointerUp: (_) {
          if (!vox && tx) {
            HapticFeedback.selectionClick();
            ic.endTransmission();
          }
        },
        onPointerCancel: (_) {
          if (!vox && tx) ic.endTransmission();
        },
        child: AnimatedContainer(
          duration: Motion.button,
          curve: Motion.curve,
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 16),
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
