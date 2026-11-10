import 'package:intl/intl.dart';

// Pure helpers of the admin console: plan labels, numbers and dates. No widgets
// and no I/O, so they are unit-tested directly. Play payments policy
// (docs/features_355/play_payments_policy.md): no money formatting, prices,
// coupons or payment helpers here; those live in the web admin.

const Map<String, String> _legacyTierNames = {
  'proRider': 'CoRoute Pro',
  'roadCaptain': 'Road Captain',
  'tourOperator': 'Tour Operator',
};

/// The plan name an admin sees: "Small Group (2–6)" for a membership plan, "Legacy: Road Captain"
/// for a legacy tier, "No plan" for `community`, "All plans" for `all`, the raw name otherwise.
String adminTierLabel(Object? tier) {
  final name = tier?.toString() ?? '';
  if (name.isEmpty || name == 'all') return 'All plans';
  if (name.toLowerCase() == 'community') return 'Community';
  if (name == 'individual') return 'Individual (retired)';
  final membership = adminMembershipPlanNames[name];
  if (membership != null) return membership;
  for (final e in _legacyTierNames.entries) {
    if (e.key.toLowerCase() == name.toLowerCase()) return 'Legacy: ${e.value}';
  }
  return name;
}

/// A number from JSON (number or numeric string), null otherwise.
num? adminNumOrNull(Object? v) => v is num ? v : num.tryParse('${v ?? ''}');

/// The plan names an admin sees. The retired Individual plan is honoured until it ends.
const Map<String, String> adminMembershipPlanNames = {
  'community': 'Community',
  'group_small': 'Small Group (2–6)',
  'group_large': 'Large Group (7–12)',
};

/// The group plans an admin can assign to a rider (besides Community).
const List<String> adminGroupPlanIds = ['group_small', 'group_large'];

/// The plan id for any value the gateway may send: a plan id as is, a legacy tier mapped to its
/// plan (CoRoute Pro -> Small Group, Road Captain / Tour Operator -> Large Group), else Community.
String adminPlanIdOf(String? raw) {
  final v = (raw ?? '').trim();
  if (v == 'group_small' || v == 'group_large' || v == 'community') return v;
  if (v == 'proRider') return 'group_small';
  if (v == 'roadCaptain' || v == 'tourOperator') return 'group_large';
  return 'community';
}

/// Epoch ms from a number, a numeric string or an ISO date (0 when none).
int adminEpoch(Object? v) {
  if (v is num) return v.toInt();
  if (v is String && v.isNotEmpty) {
    final n = int.tryParse(v);
    if (n != null) return n;
    final d = DateTime.tryParse(v);
    if (d != null) return d.millisecondsSinceEpoch;
  }
  return 0;
}

final DateFormat _date = DateFormat('d MMM yyyy');
final DateFormat _dateTime = DateFormat('d MMM yyyy, HH:mm');

/// "27 Nov 2026" (or with the time), "—" when there is no date.
String adminDate(Object? v, {bool time = false}) {
  final ms = adminEpoch(v);
  if (ms <= 0) return '—';
  return (time ? _dateTime : _date).format(DateTime.fromMillisecondsSinceEpoch(ms));
}
