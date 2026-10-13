import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';

/// Instant high-contrast HUD toast banner for in-flight rider feedback.
///
/// Designed for riders at high speed on vibrating mounts:
/// - Glove-readable text and a prominent accent icon on a floating card.
/// - A 2 px accent border for immediate peripheral visual confirmation.
/// - Zero emojis and ASCII hyphens only.
class CockpitHudToast extends StatelessWidget {
  final String message;
  final IconData icon;
  final Color? color;

  const CockpitHudToast({
    super.key,
    required this.message,
    required this.icon,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final accent = color ?? AppTheme.accentText;
    return Semantics(
      liveRegion: true,
      label: message,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(color: accent, width: 2),
          boxShadow: dsFloatingShadow(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: accent.withOpacity(0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: accent, size: 22),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                message,
                style: TextStyle(
                  color: AppTheme.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
