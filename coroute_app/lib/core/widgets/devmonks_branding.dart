import 'package:flutter/material.dart';
import '../constants/app_constants.dart';
import '../theme/app_theme.dart';
import '../ui/ui_tokens.dart';

/// Small "Powered by" credit. Flat: no glow, no shadow.
class DevMonksBadge extends StatelessWidget {
  final bool isCompact;

  const DevMonksBadge({super.key, this.isCompact = false});

  @override
  Widget build(BuildContext context) {
    if (isCompact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: Space.s8, vertical: Space.s4),
        decoration: BoxDecoration(
          color: AppTheme.elevatedCard,
          borderRadius: Radii.smAll,
          border: Border.all(color: AppTheme.subtleBorder),
        ),
        child: Text(
          AppConstants.brandName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption.copyWith(color: AppTheme.textSecondary, fontWeight: FontWeight.w600),
        ),
      );
    }

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'Powered by ', style: AppText.caption),
          TextSpan(
            text: AppConstants.brandName,
            style: AppText.caption.copyWith(color: AppTheme.textSecondary, fontWeight: FontWeight.w600),
          ),
        ],
      ),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// App icon, name and tagline, used at the top of the sign-in screen.
class CoRouteHeaderLogo extends StatelessWidget {
  final double scale;

  const CoRouteHeaderLogo({super.key, this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.md * scale),
              child: Image.asset(
                'assets/branding/coroute_icon.png',
                width: 44 * scale,
                height: 44 * scale,
                // Decode the 1024 px icon at about 3x its drawn size (not full size) to save memory.
                cacheWidth: (44 * scale * 3).round(),
                filterQuality: FilterQuality.medium,
              ),
            ),
            SizedBox(width: Space.s12 * scale),
            Flexible(
              child: Text(
                AppConstants.appName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 26 * scale,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: Space.s4 * scale),
        Text(
          AppConstants.appTagline,
          textAlign: TextAlign.center,
          style: AppText.label,
        ),
      ],
    );
  }
}
