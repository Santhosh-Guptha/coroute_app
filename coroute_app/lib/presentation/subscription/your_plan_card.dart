import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_tokens.dart';
import '../../data/models/membership_model.dart';
import '../../domain/membership/plan_summary.dart';

/// The facts for the "Your plan" card from the server's plan ([access]), the rider's own
/// membership ([owned], may have ended) and the catalog (what the plan includes).
PlanFacts planFactsOf({
  required PlanAccess access,
  UserMembership? owned,
  MembershipCatalog? catalog,
  bool ridesOnFriendsPlan = false,
}) {
  // An owned membership that has ended still names the plan that ended ("Your Small Group plan
  // ended on ..."); otherwise the server's plan decides.
  if (owned != null && owned.isExpired && !access.isPaid) {
    return PlanFacts(
      source: 'membership',
      category: owned.category,
      name: owned.name,
      seats: owned.capacity,
      validUntil: owned.validUntil,
      ridesOnFriendsPlan: ridesOnFriendsPlan,
    );
  }
  final cat = access.category == null ? null : catalog?.byId(access.category!);
  return PlanFacts(
    source: access.source,
    category: access.category,
    name: access.name,
    seats: access.seats,
    validUntil: access.validUntil,
    ridesOnFriendsPlan: ridesOnFriendsPlan,
    serverFeatures: access.isPaid ? (cat?.features ?? const []) : const [],
  );
}

/// The read-only "Your plan" card: plan name, what it includes, status, end date and
/// "Your plan is managed in your CoRoute account." No buttons, no links, no prices
/// (Play payments policy, docs/features_355/play_payments_policy.md).
class YourPlanCard extends StatelessWidget {
  final PlanSummary summary;

  const YourPlanCard({super.key, required this.summary});

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final accent = s.isCommunity ? StatusColors.success : AppTheme.accentText;
    return Container(
      key: const Key('your_plan_card'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.6), width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.planName,
                  key: const Key('your_plan_name'),
                  style: TextStyle(color: AppTheme.text, fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  s.status,
                  key: const Key('your_plan_status'),
                  style: TextStyle(color: accent, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ],
          ),
          if (s.dateLine != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(s.isEnded ? Icons.event_busy_rounded : Icons.event_available_rounded, size: 16, color: AppTheme.text2),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(s.dateLine!, key: const Key('your_plan_date'), style: TextStyle(color: AppTheme.text2, fontSize: 13)),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          Text('Includes', style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 8),
          for (final line in s.includes)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check_circle_outline_rounded, color: StatusColors.success, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Text(line, style: TextStyle(color: AppTheme.text2, fontSize: 13, height: 1.3))),
                ],
              ),
            ),
          if (s.note != null) ...[
            const SizedBox(height: 6),
            Text(s.note!, key: const Key('your_plan_note'), style: TextStyle(color: AppTheme.text, fontSize: 13, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 12),
          Divider(color: AppTheme.soft, height: 1),
          const SizedBox(height: 12),
          Text(s.managedLine, key: const Key('your_plan_managed'), style: TextStyle(color: AppTheme.muted, fontSize: 12, height: 1.3)),
        ],
      ),
    );
  }
}
