import 'package:flutter/material.dart';
import '../../../data/services/voice/voice_assistant_controller.dart';

/// Ergonomic HUD status pill for the CoRoute Multilingual Voice Assistant.
///
/// Complies with:
/// - 0.8-second cognitive glance budget.
/// - 56dp touch target for motorcycle gloves.
/// - AMOLED deep black palette (#000000 / #0B0E14) with high-contrast status accents.
class VoiceAssistantHudPill extends StatelessWidget {
  final VoiceAssistantController controller;
  final VoidCallback? onPttPressed;

  const VoiceAssistantHudPill({
    super.key,
    required this.controller,
    this.onPttPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.state;
        if (state == VoiceSessionState.idle && controller.statusFeedback.isEmpty) {
          return const SizedBox.shrink();
        }

        final config = _resolveVisualConfig(state, controller.statusFeedback);

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              if (state == VoiceSessionState.listening) {
                controller.stopListening();
              } else if (state == VoiceSessionState.confirming) {
                controller.cancelSession(reason: 'User cancelled');
              } else {
                onPttPressed?.call();
              }
            },
            borderRadius: BorderRadius.circular(28.0),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 56.0,
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              decoration: BoxDecoration(
                color: const Color(0xFF0B0E14).withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(28.0),
                border: Border.all(
                  color: config.accentColor,
                  width: 2.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: config.accentColor.withValues(alpha: 0.25),
                    blurRadius: 10.0,
                    spreadRadius: 1.0,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    config.icon,
                    color: config.accentColor,
                    size: 26.0,
                  ),
                  const SizedBox(width: 12.0),
                  Flexible(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          config.title,
                          style: TextStyle(
                            color: config.accentColor,
                            fontSize: 14.0,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (controller.currentTranscript.isNotEmpty)
                          Text(
                            controller.currentTranscript,
                            style: const TextStyle(
                              color: Color(0xFFE2E8F0),
                              fontSize: 12.0,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (state == VoiceSessionState.confirming) ...[
                    const SizedBox(width: 10.0),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                      decoration: BoxDecoration(
                        color: config.accentColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6.0),
                      ),
                      child: const Text(
                        'Say Yes / No',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11.0,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  _PillVisualConfig _resolveVisualConfig(VoiceSessionState state, String feedback) {
    if (feedback.contains('🚨') || feedback.contains('EMERGENCY')) {
      return _PillVisualConfig(
        title: 'EMERGENCY SOS',
        accentColor: const Color(0xFFFF1744),
        icon: Icons.warning_amber_rounded,
      );
    }

    switch (state) {
      case VoiceSessionState.starting:
      case VoiceSessionState.listening:
        return _PillVisualConfig(
          title: 'LISTENING (PTT)',
          accentColor: const Color(0xFF00E5FF), // Cyan
          icon: Icons.mic_rounded,
        );
      case VoiceSessionState.processing:
        return _PillVisualConfig(
          title: 'PROCESSING...',
          accentColor: const Color(0xFFFFB300), // Amber
          icon: Icons.sync_rounded,
        );
      case VoiceSessionState.confirming:
        return _PillVisualConfig(
          title: 'CONFIRM ACTION',
          accentColor: const Color(0xFFFF9100), // Orange
          icon: Icons.help_outline_rounded,
        );
      case VoiceSessionState.completed:
        return _PillVisualConfig(
          title: feedback.isNotEmpty ? feedback : 'COMPLETED',
          accentColor: const Color(0xFF00E676), // Green
          icon: Icons.volume_up_rounded,
        );
      case VoiceSessionState.failed:
        return _PillVisualConfig(
          title: feedback.isNotEmpty ? feedback : 'FAILED',
          accentColor: const Color(0xFFFF5252), // Red
          icon: Icons.error_outline_rounded,
        );
      case VoiceSessionState.idle:
      case VoiceSessionState.cancelled:
        return _PillVisualConfig(
          title: feedback.isNotEmpty ? feedback : 'READY',
          accentColor: const Color(0xFF94A3B8), // Slate
          icon: Icons.check_circle_outline_rounded,
        );
    }
  }
}

class _PillVisualConfig {
  final String title;
  final Color accentColor;
  final IconData icon;

  const _PillVisualConfig({
    required this.title,
    required this.accentColor,
    required this.icon,
  });
}

/// Glove-friendly 56dp Push-to-Talk (PTT) round thumb button for motorcycle handlebars / cockpit HUD.
class VoicePttButton extends StatelessWidget {
  final VoiceAssistantController? controller;
  final VoidCallback? onPressed;

  const VoicePttButton({
    super.key,
    this.controller,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (controller == null) return const SizedBox.shrink();

    return ListenableBuilder(
      listenable: controller!,
      builder: (context, _) {
        final state = controller!.state;
        final isListening = state == VoiceSessionState.listening || state == VoiceSessionState.starting;
        final isConfirming = state == VoiceSessionState.confirming;

        final Color ringColor = switch (state) {
          VoiceSessionState.listening || VoiceSessionState.starting => const Color(0xFF00E5FF),
          VoiceSessionState.processing => const Color(0xFFFFB300),
          VoiceSessionState.confirming => const Color(0xFFFF9100),
          VoiceSessionState.failed => const Color(0xFFFF5252),
          _ => const Color(0xFF00E5FF).withValues(alpha: 0.6),
        };

        final IconData icon = switch (state) {
          VoiceSessionState.listening || VoiceSessionState.starting => Icons.graphic_eq_rounded,
          VoiceSessionState.processing => Icons.sync_rounded,
          VoiceSessionState.confirming => Icons.help_outline_rounded,
          _ => Icons.mic_rounded,
        };

        return Semantics(
          button: true,
          label: 'Voice Assistant Push to Talk',
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                if (onPressed != null) {
                  onPressed!();
                } else {
                  if (isListening) {
                    controller!.stopListening();
                  } else if (isConfirming) {
                    controller!.cancelSession(reason: 'User tapped cancel');
                  } else {
                    controller!.startListening();
                  }
                }
              },
              borderRadius: BorderRadius.circular(28.0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 56.0,
                height: 56.0,
                decoration: BoxDecoration(
                  color: const Color(0xFF0B0E14),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: ringColor,
                    width: isListening ? 2.5 : 2.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: ringColor.withValues(alpha: isListening ? 0.45 : 0.2),
                      blurRadius: isListening ? 14.0 : 8.0,
                      spreadRadius: isListening ? 2.0 : 0.0,
                    ),
                  ],
                ),
                child: Center(
                  child: Icon(
                    icon,
                    color: ringColor,
                    size: 26.0,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
