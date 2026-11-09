/// Plan changes (owner's rule, 3.55): while a paid plan is active a rider may only move to a bigger
/// plan (Community < Small Group < Large Group; the retired Individual sits between Community and
/// Small Group). A smaller or the same plan can be chosen when the current plan ends. The gateway
/// enforces the same rule (409 DOWNGRADE_NOT_ALLOWED, gateway/src/plan_pricing.js `changeBlock`);
/// admins may set any plan.
library;

class PlanChangeRules {
  PlanChangeRules._();

  /// Tier order, lowest first (same as the gateway's PLAN_ORDER).
  static const List<String> order = ['community', 'individual', 'group_small', 'group_large'];

  /// The one line shown where smaller plans are hidden (same words as the server's refusal).
  static const String note = 'You can move to a bigger plan anytime. Smaller plans can be chosen when your current plan ends.';

  /// Server reason for a refused smaller / same plan.
  static const String reason = 'DOWNGRADE_NOT_ALLOWED';

  /// Rank of [planId] in [order] (-1 when unknown).
  static int rank(String? planId) => order.indexOf(planId ?? '');

  /// True when a rider whose current plan is [currentPlan] ([currentActive]: a paid plan that has
  /// not ended) may choose [target] now.
  static bool canChoose({required String? currentPlan, required bool currentActive, required String target}) {
    if (!currentActive) return true;
    final from = rank(currentPlan);
    final to = rank(target);
    if (from <= 0 || to < 0) return true; // Community (free) or unknown: nothing to protect
    return to > from;
  }
}
