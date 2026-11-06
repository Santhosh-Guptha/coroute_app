import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/membership_model.dart';
import '../../data/services/membership_service.dart';
import 'membership_dashboard_screen.dart';

/// The rider's plan on the home screen, in one plain line, e.g.
/// "Small Group · up to 6 riders · until 12 Dec" or
/// "Community · Solo rides free · Host a group from ₹49". Tap opens the membership screen.
/// Hidden when payments are switched off on the gateway.
class MembershipStatusChip extends StatelessWidget {
  const MembershipStatusChip({super.key});

  /// The line for [access] (pure, for tests).
  static String textFor(PlanAccess access, {int? groupFromPrice}) =>
      access.statusLine(groupFromPrice: groupFromPrice);

  @override
  Widget build(BuildContext context) {
    final ms = context.watch<MembershipService?>();
    if (ms == null || !ms.paymentsEnabled) return const SizedBox.shrink();
    final access = ms.planAccess;
    final text = textFor(access, groupFromPrice: ms.groupFromPrice);
    // A paid plan in the accent colour; Community (free) in the quiet text colour.
    final color = access.isPaid ? AppTheme.accentText : AppTheme.text2;
    return Semantics(
      button: true,
      label: 'Membership: $text',
      child: GestureDetector(
        key: const Key('home_membership_status'),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const MembershipDashboardScreen()),
        ),
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
                  style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded, size: 14, color: color.withValues(alpha: 0.7)),
            ],
          ),
        ),
      ),
    );
  }
}
