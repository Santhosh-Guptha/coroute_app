import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/config/feature_gates.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/plan_subscription_service.dart';

/// Screen allowing riders, captains, and testers to inspect and switch between
/// subscription plans (Community, Pro, Road Captain, Tour Operator).
///
/// In this testing release, payments are bypassed; users can toggle between
/// plans freely to evaluate the feature sets and test strict entitlement gating.
class PlanSelectorScreen extends StatelessWidget {
  const PlanSelectorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final planService = context.watch<PlanSubscriptionService>();
    final currentTier = planService.currentTier;
    final forceUnlocked = planService.forceAllUnlocked;
    final plans = PlanSubscriptionService.allPlans;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.card,
        elevation: 0,
        title: const Text(
          'Membership & Plans',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 14),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.accentText.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.accentText, width: 1.2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.verified_user_rounded, color: AppTheme.accentText, size: 14),
                const SizedBox(width: 5),
                Text(
                  FeatureGates.tierLabel(currentTier).toUpperCase(),
                  style: TextStyle(
                    color: AppTheme.accentText,
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // Developer / Tester Mode Banner
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: forceUnlocked ? AppTheme.accentText : AppTheme.warnText,
                width: 1.5,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  forceUnlocked ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
                  color: forceUnlocked ? AppTheme.accentText : AppTheme.warnText,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        forceUnlocked ? 'TEST MODE: ALL FEATURES UNLOCKED' : 'TEST MODE: STRICT PLAN RULES ENFORCED',
                        style: TextStyle(
                          color: forceUnlocked ? AppTheme.accentText : AppTheme.warnText,
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        forceUnlocked
                            ? 'All 4 plan features are currently 100% free and active.'
                            : 'App is strictly constrained by your selected plan below.',
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: forceUnlocked,
                  activeColor: AppTheme.accentText,
                  onChanged: (val) {
                    HapticFeedback.selectionClick();
                    planService.setForceAllUnlocked(val);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        duration: const Duration(seconds: 2),
                        backgroundColor: AppTheme.card,
                        content: Text(
                          val ? 'Unlocked all features for global testing' : 'Enforced strict tier rules for ${FeatureGates.tierLabel(currentTier)}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Heading & Subtitle
          const Text(
            'Choose Your Convoy Power',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 20,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Select a plan to test its specific features, convoy capacities, and cockpit controls.',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(height: 16),

          // Plan Cards
          for (final plan in plans) ...[
            _PlanCard(
              plan: plan,
              isActive: plan.tier == currentTier,
              onSelect: () {
                HapticFeedback.heavyImpact();
                planService.selectTier(plan.tier);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    duration: const Duration(seconds: 3),
                    backgroundColor: AppTheme.card,
                    content: Row(
                      children: [
                        Icon(Icons.check_circle_rounded, color: AppTheme.accentText),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Activated ${plan.name}! Max ${plan.maxConvoySize} riders allowed.',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
          ],

          const SizedBox(height: 12),
          // Informative Footer
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF141F28),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border2),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, color: AppTheme.muted, size: 18),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'No payment is required in this build. You can switch between plans freely to test convoy scaling, priority ducking, and emergency systems.',
                    style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final PlanDetails plan;
  final bool isActive;
  final VoidCallback onSelect;

  const _PlanCard({
    required this.plan,
    required this.isActive,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isActive ? AppTheme.accentText : (plan.isPopular ? AppTheme.neonCyan.withValues(alpha: 0.6) : AppTheme.border2);

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor, width: isActive ? 2.2 : 1.2),
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: AppTheme.accentText.withValues(alpha: 0.25),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                )
              ]
            : null,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Row: Name & Tag
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            plan.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 18,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            plan.tagline,
                            style: const TextStyle(color: Colors.white60, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    // Max Convoy Badge
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF141F28),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppTheme.border2),
                      ),
                      child: Text(
                        'Up to ${plan.maxConvoySize} Bikes',
                        style: TextStyle(
                          color: AppTheme.accentText,
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Pricing
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      plan.monthlyPrice,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 20,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '(${plan.annualPrice})',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
                Divider(height: 24, color: AppTheme.border2),

                // Features Checklist
                for (final f in plan.features) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.check_circle_rounded,
                          size: 16,
                          color: f.isHighlight ? AppTheme.accentText : AppTheme.neonCyan,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                f.title,
                                style: TextStyle(
                                  color: f.isHighlight ? Colors.white : Colors.white.withValues(alpha: 0.9),
                                  fontWeight: f.isHighlight ? FontWeight.w800 : FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                              Text(
                                f.description,
                                style: const TextStyle(color: Colors.white54, fontSize: 11, height: 1.2),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 10),

                // Action Button (56dp glove-friendly target)
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: isActive ? AppTheme.accentText : const Color(0xFF1E3342),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: isActive ? null : onSelect,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          isActive ? Icons.verified_rounded : Icons.touch_app_rounded,
                          color: isActive ? Colors.black : AppTheme.accentText,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          isActive ? 'CURRENT PLAN ACTIVE' : 'ACTIVATE THIS PLAN (TEST)',
                          style: TextStyle(
                            color: isActive ? Colors.black : Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 13,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // "POPULAR" Pill
          if (plan.isPopular)
            Positioned(
              top: -10,
              right: 18,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.accentText,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(color: AppTheme.accentText.withValues(alpha: 0.4), blurRadius: 8),
                  ],
                ),
                child: const Text(
                  '★ MOST POPULAR FOR CLUBS',
                  style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                    fontSize: 10,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
