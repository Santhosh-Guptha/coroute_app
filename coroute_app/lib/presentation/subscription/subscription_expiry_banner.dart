import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/config/feature_gates.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/plan_subscription_service.dart';
import 'plan_selector_screen.dart';

/// One-line warning shown above account and plan screens when the paid plan
/// ends within 7 days, or has already ended (rolled back to Community).
/// Tapping it opens the plan selector with the plan to renew preselected.
/// Renders nothing when there is nothing to warn about.
class SubscriptionExpiryBanner extends StatelessWidget {
  final EdgeInsetsGeometry margin;

  /// False on the plan selector itself (a tap there would reopen the same screen).
  final bool opensPlanSelector;

  const SubscriptionExpiryBanner({
    super.key,
    this.margin = const EdgeInsets.only(bottom: 14),
    this.opensPlanSelector = true,
  });

  /// Copy for the warning, or null when there is nothing to say.
  static String? messageFor(PlanSubscriptionService plan) {
    final prev = plan.previousTier;
    if (plan.isExpired && prev != null) {
      return 'Your ${FeatureGates.tierLabel(prev)} has ended — you\'re on Community now. '
          'Renew to keep ${PlanSubscriptionService.keyFeatureSummary(prev)}.';
    }
    if (!plan.expiringSoon) return null;
    final name = FeatureGates.tierLabel(plan.currentTier);
    final features = PlanSubscriptionService.keyFeatureSummary(plan.currentTier);
    final days = plan.daysRemaining;
    final when = days <= 0
        ? 'today'
        : days == 1
            ? 'in 1 day'
            : 'in $days days';
    return 'Your $name ends $when — renew to keep $features.';
  }

  static void openRenewal(BuildContext context, PlanSubscriptionService plan) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PlanSelectorScreen(preselectTier: plan.renewTier)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final plan = context.watch<PlanSubscriptionService?>();
    if (plan == null) return const SizedBox.shrink();
    final message = messageFor(plan);
    if (message == null) return const SizedBox.shrink();
    final expired = plan.isExpired;
    final days = plan.daysRemaining;
    final urgent = expired || days <= 1;
    final fg = urgent ? AppTheme.sos : AppTheme.warnText;
    final bg = urgent ? AppTheme.sos.withValues(alpha: 0.10) : AppTheme.warnTint;
    final border = urgent ? AppTheme.sos.withValues(alpha: 0.55) : AppTheme.warnBorder;

    return Padding(
      padding: margin,
      child: DsCard(
        radius: Radii.md,
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        color: bg,
        borderColor: border,
        onTap: opensPlanSelector ? () => openRenewal(context, plan) : null,
        semanticsLabel: '$message Renew',
        child: Row(
          children: [
            Icon(expired ? Icons.lock_clock_rounded : Icons.timer_outlined, color: fg, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    expired ? 'Plan ended' : (days <= 1 ? 'Ends in 1 day' : 'Ends in $days days'),
                    style: AppText.overline.copyWith(color: fg),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    message,
                    style: AppText.caption.copyWith(color: AppTheme.text, fontWeight: FontWeight.w600, height: 1.35),
                  ),
                ],
              ),
            ),
            if (opensPlanSelector) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: fg, borderRadius: BorderRadius.circular(8)),
                child: const Text(
                  'RENEW',
                  style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 0.8),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
