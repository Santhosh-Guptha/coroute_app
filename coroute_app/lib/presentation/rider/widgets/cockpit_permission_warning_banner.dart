import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/design_kit.dart';
import '../../../../core/ui/ui_tokens.dart';
import '../../../../data/services/permission_revocation_safety_service.dart';

/// Clear, prominent, high-visibility permission warning banner for the cockpit.
///
/// Designed for motorcycle riders wearing thick gloves:
/// - 48 dp+ minimum touch target for direct action buttons.
/// - High-contrast OLED dark styling with glowing perimeter outline.
/// - Clearly distinguishes Essential permissions (Red/SOS glow) from Optional permissions (Amber glow).
/// - Displays affected feature title, why the permission is required, and a direct button
///   to open Android App Settings (`openAppSettings()`).
/// - Guaranteed trip safety: Active ride is NEVER terminated on permission revocation.
class CockpitPermissionWarningBanner extends StatelessWidget {
  final PermissionRevocationSafetyService? service;
  final EdgeInsetsGeometry? margin;

  const CockpitPermissionWarningBanner({
    super.key,
    this.service,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    PermissionRevocationSafetyService? safety = service;
    if (safety == null) {
      try {
        safety = Provider.of<PermissionRevocationSafetyService?>(context);
      } catch (_) {
        safety = null;
      }
    }

    if (safety == null) {
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: safety,
      builder: (context, _) {
        if (!safety!.hasActiveWarning) {
          return const SizedBox.shrink();
        }

        final perm = safety.primaryRevokedPermission;
        if (perm == null) {
          return const SizedBox.shrink();
        }

        final isEssential = PermissionRevocationSafetyService.isEssential(perm);
        final feature = PermissionRevocationSafetyService.affectedFeature(perm);
        final reason = PermissionRevocationSafetyService.reasonRequired(perm);

        // Styling based on essential vs optional distinction
        final borderColor = isEssential ? AppTheme.sos : AppTheme.hyperAmber;
        final badgeBg = isEssential
            ? AppTheme.sos.withValues(alpha: 0.20)
            : AppTheme.hyperAmber.withValues(alpha: 0.18);
        final badgeTextColor = isEssential ? AppTheme.sos : AppTheme.hyperAmber;

        final badgeText = isEssential
            ? (perm == TripPermission.locationService
                ? 'CRITICAL · GPS TURNED OFF'
                : 'CRITICAL · GPS REVOKED')
            : 'FEATURE LIMITED · OPTIONAL PERMISSION';

        final iconData = _getPermissionIcon(perm);

        final semanticLabel =
            'Permission Warning: $badgeText. Affected Feature: $feature. Reason: $reason';

        return Semantics(
          container: true,
          label: semanticLabel,
          child: Container(
            margin: margin ?? const EdgeInsets.symmetric(horizontal: Space.s12, vertical: Space.s4),
            decoration: BoxDecoration(
              color: AppTheme.card.withValues(alpha: 0.98),
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(color: borderColor, width: 2.0),
              boxShadow: dsFloatingShadow(),
            ),
            child: Padding(
              padding: const EdgeInsets.all(Space.s12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header Row: Status Badge + Optional Dismiss
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Flexible: a long badge ellipsizes instead of overflowing on 360 dp phones.
                      Flexible(
                        child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: Space.s8, vertical: Space.s4),
                        decoration: BoxDecoration(
                          color: badgeBg,
                          borderRadius: BorderRadius.circular(Radii.sm),
                          border: Border.all(color: borderColor.withValues(alpha: 0.6), width: 1.0),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(iconData, size: 14, color: badgeTextColor),
                            const SizedBox(width: Space.s4),
                            Flexible(
                              child: Text(
                                badgeText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.caption.copyWith(
                                  color: badgeTextColor,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                        ),
                      ),
                      if (!isEssential)
                        Semantics(
                          button: true,
                          label: 'Dismiss optional warning',
                          child: InkWell(
                            key: const Key('cockpit_permission_dismiss_button'),
                            onTap: () => safety!.dismissOptionalWarning(perm),
                            borderRadius: BorderRadius.circular(16),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                Icons.close_rounded,
                                size: 18,
                                color: AppTheme.muted,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.s8),

                  // Feature Title
                  Text(
                    feature,
                    style: AppText.title.copyWith(
                      color: AppTheme.accentText,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.1,
                    ),
                  ),
                  const SizedBox(height: Space.s4),

                  // Explanation Reason Text
                  Text(
                    reason,
                    style: AppText.caption.copyWith(
                      color: AppTheme.muted,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),

                  // Safety Assurance Note
                  const SizedBox(height: Space.s4),
                  Row(
                    children: [
                      Icon(Icons.shield_rounded, size: 13, color: AppTheme.neonCyan),
                      const SizedBox(width: Space.s4),
                      Expanded(
                        child: Text(
                          'Trip remains active · Unaffected local safety features operational',
                          style: AppText.caption.copyWith(
                            color: AppTheme.neonCyan,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.s12),

                  // Action Buttons Row (Min 48dp height for thick gloves)
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: ElevatedButton.icon(
                            key: const Key('cockpit_permission_settings_button'),
                            onPressed: () async {
                              final s = safety;
                              if (s != null) {
                                await s.openSettings();
                                // Never assume granted just because settings was opened;
                                // immediately re-check actual OS permission state.
                                await s.recheckPermissions();
                              }
                            },
                            icon: const Icon(Icons.settings_rounded, size: 18),
                            label: const Text(
                              'Fix Permission',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isEssential ? AppTheme.sos : AppTheme.hyperAmber,
                              foregroundColor: AppTheme.card,
                              elevation: 2,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(Radii.sm),
                              ),
                              padding: const EdgeInsets.symmetric(horizontal: Space.s12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.s8),
                      SizedBox(
                        height: 48,
                        child: OutlinedButton(
                          key: const Key('cockpit_permission_retry_button'),
                          onPressed: () async {
                            await safety!.recheckPermissions();
                          },
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: AppTheme.border, width: 1.5),
                            foregroundColor: AppTheme.accentText,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(Radii.sm),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: Space.s16),
                          ),
                          child: const Text(
                            'RECHECK',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  IconData _getPermissionIcon(TripPermission perm) {
    switch (perm) {
      case TripPermission.location:
        return Icons.location_off_rounded;
      case TripPermission.locationService:
        return Icons.gps_off_rounded;
      case TripPermission.locationAlways:
        return Icons.location_disabled_rounded;
      case TripPermission.microphone:
        return Icons.mic_off_rounded;
      case TripPermission.bluetooth:
        return Icons.bluetooth_disabled_rounded;
      case TripPermission.notification:
        return Icons.notifications_off_rounded;
    }
  }
}
