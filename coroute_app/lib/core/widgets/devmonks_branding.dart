import 'package:flutter/material.dart';
import '../constants/app_constants.dart';
import '../theme/app_theme.dart';

class DevMonksBadge extends StatelessWidget {
  final bool isCompact;

  const DevMonksBadge({super.key, this.isCompact = false});

  @override
  Widget build(BuildContext context) {
    if (isCompact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppTheme.elevatedCard.withOpacity(0.8),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppTheme.devmonksPurple.withOpacity(0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bolt, color: AppTheme.neonCyan, size: 12),
            const SizedBox(width: 4),
            Text(
              AppConstants.brandName,
              style: const TextStyle(
                color: AppTheme.neonCyan,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.slateCard.withOpacity(0.9),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.glassBorder),
        boxShadow: [
          BoxShadow(
            color: AppTheme.neonCyan.withOpacity(0.12),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.devmonksPurple,
            ),
            child: const Icon(Icons.terminal, color: Colors.white, size: 12),
          ),
          const SizedBox(width: 8),
          RichText(
            text: const TextSpan(
              children: [
                TextSpan(
                  text: 'Powered by ',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                ),
                TextSpan(
                  text: AppConstants.brandName,
                  style: TextStyle(
                    color: AppTheme.neonCyan,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
            Container(
              padding: EdgeInsets.all(8 * scale),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.neonCyan, AppTheme.electricBlue],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12 * scale),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.neonCyan.withOpacity(0.35),
                    blurRadius: 14 * scale,
                    spreadRadius: 2 * scale,
                  ),
                ],
              ),
              child: Icon(
                Icons.navigation_rounded,
                color: Colors.black,
                size: 24 * scale,
              ),
            ),
            SizedBox(width: 10 * scale),
            Text(
              AppConstants.appName,
              style: TextStyle(
                color: Colors.white,
                fontSize: 26 * scale,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        SizedBox(height: 4 * scale),
        Text(
          AppConstants.appTagline,
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 11 * scale,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }
}
