import 'plan_summary.dart';

/// Neutral words for every plan gate and capacity refusal (pure Dart, unit-testable).
///
/// Play payments policy (docs/features_355/play_payments_policy.md): a locked feature or a full
/// ride says what is so, never how to buy, change or extend a plan, and offers no button that
/// leads to one. The gateway's own text for these refusals is replaced on the phone ([neutral]),
/// so an older or newer server wording can never reach a rider.
class PlanGateMessages {
  PlanGateMessages._();

  static const String groupRidesNeedHost = 'Group rides need a host with a group plan.';
  static const String hostingNeedsGroupPlan = 'Hosting a group ride needs a group plan.';
  static const String rideFull = 'This ride is full.';
  static const String soloRideNoJoin = "This is a solo ride. Others can't join it.";
  static const String soloRideFeatures = 'Talk, messages and regroup are for group rides. This is a solo ride.';
  static const String notAvailable = "This isn't available right now.";

  /// The neutral text for a gateway refusal code (`code` or `reason` of its error body), or null
  /// when the code is not a plan or capacity refusal.
  static String? forCode(String? code) => switch (code) {
        'MEMBERSHIP_EXPIRED' || 'MEMBERSHIP_REQUIRED' || 'PLAN_REQUIRED' || 'GROUP_PLAN_REQUIRED' => hostingNeedsGroupPlan,
        'LEGACY_PLAN' || 'FREE_PLAN' || 'PLAN_INACTIVE' => hostingNeedsGroupPlan,
        'CONVOY_FULL' || 'RIDE_FULL' || 'MEMBERSHIP_CAPACITY_EXCEEDED' || 'CAPACITY_CONFLICT' => rideFull,
        'SOLO_TRIP_ONLY' => soloRideNoJoin,
        'SOLO_RIDE' => soloRideFeatures,
        _ => null,
      };

  /// What the app shows for a refusal with [code] / [reason] and the server's [message]: the
  /// neutral text for a plan or capacity code, the server's message when it has no price or
  /// buying words, else [notAvailable].
  static String neutral(String? code, String? reason, String message) {
    final known = forCode(code) ?? forCode(reason);
    if (known != null) return known;
    return planForbiddenText.hasMatch(message) ? notAvailable : message;
  }
}
