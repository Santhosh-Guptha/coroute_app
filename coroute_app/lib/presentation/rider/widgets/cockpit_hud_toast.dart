import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_tokens.dart';

/// Instant high-contrast HUD toast banner for in-flight rider feedback.
///
/// Designed for riders at high speed on vibrating mounts:
/// - Glove-readable text and prominent high-contrast icon.
/// - Glowing active border for immediate peripheral visual confirmation.
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
    final accent = color ?? AppTheme.neonCyan;
    return Semantics(
      liveRegion: true,
      label: message,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s12),
        decoration: BoxDecoration(
          color: AppTheme.obsidianVoid.withOpacity(0.95),
          borderRadius: Radii.lgAll,
          border: Border.all(color: accent, width: 2.0),
          boxShadow: [
            BoxShadow(
              color: accent.withOpacity(0.35),
              blurRadius: 12.0,
              spreadRadius: 1.0,
            ),
            BoxShadow(
              color: AppTheme.shadow,
              blurRadius: 8.0,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: accent, size: 24),
            const SizedBox(width: Space.s12),
            Flexible(
              child: Text(
                message,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
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
