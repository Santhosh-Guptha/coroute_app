import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/membership_model.dart';
import '../../data/services/membership_service.dart';

/// The rider's plan on the home screen: the plan name only ("Community", "Small Group",
/// "Large Group"). Not tappable: the app has no plan screen for riders any more (owner decision,
/// Nov 11). Hidden when the gateway runs without plans. Play payments policy: no price, no buying
/// words, no link (play_payments_policy.md).
class MembershipStatusChip extends StatelessWidget {
  const MembershipStatusChip({super.key});

  /// The line for [access] (pure, for tests).
  static String textFor(PlanAccess access) => access.isPaid ? access.shortName : 'Community';

  @override
  Widget build(BuildContext context) {
    final ms = context.watch<MembershipService?>();
    if (ms == null || !ms.plansEnforced) return const SizedBox.shrink();
    final access = ms.planAccess;
    final text = textFor(access);
    // A paid plan in the accent colour; Community (free) in the quiet text colour.
    final color = access.isPaid ? AppTheme.accentText : AppTheme.text2;
    return Semantics(
      label: 'Your plan: $text',
      child: KeyedSubtree(
        key: const Key('home_membership_status'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color, width: 1.2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(access.isPaid ? Icons.verified_rounded : Icons.groups_rounded, size: 14, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
