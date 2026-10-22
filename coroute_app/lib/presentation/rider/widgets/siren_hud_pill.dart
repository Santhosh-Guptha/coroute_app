import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/services/siren_acoustic_detector.dart';

/// High-visibility emergency HUD pill displayed when an approaching emergency siren is detected.
///
/// Fully accessible for motorcycle riders wearing gloves.
/// Features high contrast, restrained single-pulse animation, and explicit directionality.
class SirenHudPill extends StatefulWidget {
  final SirenDetectionEvent event;
  final VoidCallback? onDismiss;
  final VoidCallback? onTap;

  const SirenHudPill({
    super.key,
    required this.event,
    this.onDismiss,
    this.onTap,
  });

  @override
  State<SirenHudPill> createState() => _SirenHudPillState();
}

class _SirenHudPillState extends State<SirenHudPill> with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _glowAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final alertLabel = widget.event.alertText;

    return Semantics(
      label: alertLabel,
      liveRegion: true,
      hint: 'Approaching emergency siren detected. Yield right of way.',
      child: AnimatedBuilder(
        animation: _glowAnimation,
        builder: (context, child) {
          return Opacity(
            opacity: _glowAnimation.value,
            child: child,
          );
        },
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              constraints: const BoxConstraints(minHeight: 52, maxWidth: 520),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.isLight ? const Color(0xFFFFF2F2) : const Color(0xFF261012),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: AppTheme.sos.withOpacity(0.85),
                  width: 2.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.sos.withOpacity(0.30),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // Animated Warning Beacon
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.sos.withOpacity(0.18),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        '🚨',
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Alert Message
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.event.approachingFromBehind
                              ? 'EMERGENCY SIREN BEHIND'
                              : 'EMERGENCY SIREN DETECTED',
                          style: TextStyle(
                            color: AppTheme.sos,
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.6,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: AppTheme.sos,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'YIELD',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                widget.event.pattern == SirenPatternType.wail
                                    ? 'Wail siren · Audio ducked -20dB'
                                    : widget.event.pattern == SirenPatternType.yelp
                                        ? 'Yelp siren · Audio ducked -20dB'
                                        : 'Acoustic siren · Audio ducked -20dB',
                                style: TextStyle(
                                  color: AppTheme.text2,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Dismiss Button
                  if (widget.onDismiss != null) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(
                        Icons.close_rounded,
                        color: AppTheme.muted,
                        size: 20,
                      ),
                      onPressed: widget.onDismiss,
                      tooltip: 'Dismiss Alert',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
