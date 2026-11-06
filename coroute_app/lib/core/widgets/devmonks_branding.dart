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
          color: AppTheme.tint,
          borderRadius: Radii.smAll,
        ),
        child: Text(
          AppConstants.brandName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w800, letterSpacing: 0.5),
        ),
      );
    }

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'Powered by ', style: AppText.caption),
          TextSpan(
            text: AppConstants.brandName,
            style: AppText.caption.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w800),
          ),
        ],
      ),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

