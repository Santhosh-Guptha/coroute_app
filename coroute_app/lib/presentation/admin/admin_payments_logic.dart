import 'package:intl/intl.dart';

// Pure helpers of the "Payments & Plans" admin console: labels, money and
// date formatting, and the checks run before a form is sent. No widgets
// and no I/O, so they are unit-tested directly.

/// The legacy paid tiers (no longer sold). They show read-only as "Legacy: ..." in rider details,
/// payments and old coupon bindings until the last one ends.
const List<String> adminPaidTierNames = ['proRider', 'roadCaptain', 'tourOperator'];

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

/// "Monthly", "Annual" or "Any cycle" for `all`.
String adminCycleLabel(Object? cycle) {
  final c = cycle?.toString().toLowerCase() ?? '';
  if (c == 'annual' || c == 'yearly') return 'Annual';
  if (c == 'monthly') return 'Monthly';
  return 'Any cycle';
}

final NumberFormat _inr = NumberFormat.decimalPattern('en_IN');

/// "₹1,19,999" for rupees (two decimals only when there are paise).
String adminInr(num? rupees) {
  if (rupees == null) return '₹—';
  if (rupees != rupees.roundToDouble()) return '₹${rupees.toStringAsFixed(2)}';
  return '₹${_inr.format(rupees.toInt())}';
}

/// [adminInr] of an amount in paise.
String adminInrPaise(num? paise) => paise == null ? '₹—' : adminInr(paise / 100);

/// A number from JSON (number or numeric string), null otherwise.
num? adminNumOrNull(Object? v) => v is num ? v : num.tryParse('${v ?? ''}');

/// The plans of the catalog, with names but no prices: prices come from the server plan catalog
/// (`GET /api/admin/coupons/plan-options`, `monthlyInr`), so an admin price change on the gateway
/// never leaves an old price in the app (3.54). Community is free (not sold); the paid ₹9
/// Individual plan was retired (an active one is honoured until it ends).
const Map<String, String> adminMembershipPlanNames = {
  'community': 'Community',
  'group_small': 'Small Group (2–6)',
  'group_large': 'Large Group (7–12)',
};

/// The plans riders can buy (and coupons can be bound to): the paid plans only.
const List<String> adminPaidPlanIds = ['group_small', 'group_large'];

/// "Small Group (2–6) (₹59/mo)" from the server plan [options] for [id]; the catalog label when
/// the server has one, and no price when the server has none (never a hard-coded price).
String adminPlanLabel(String id, List<Map<String, dynamic>> options, {bool perMonth = true}) {
  Map<String, dynamic>? opt;
  for (final o in options) {
    if (o['id']?.toString() == id) {
      opt = o;
      break;
    }
  }
  final label = opt?['label']?.toString().trim() ?? '';
  final name = label.isNotEmpty ? label : (adminMembershipPlanNames[id] ?? adminTierLabel(id));
  final price = adminNumOrNull(opt?['monthlyInr']);
  if (price == null || price <= 0) return name;
  return '$name (${adminInr(price)}${perMonth ? '/mo' : ''})';
}

/// The plan ids to list for coupons and paid-plan figures: the paid plans riders can buy
/// ([options] is kept for callers; the server offers no other plan).
List<String> adminMembershipPlanIds(List<Map<String, dynamic>> options) => [...adminPaidPlanIds];

/// The first of [keys] in [m] that holds a number.
num? adminPickNum(Map? m, List<String> keys) {
  if (m == null) return null;
  for (final k in keys) {
    final v = adminNumOrNull(m[k]);
    if (v != null) return v;
  }
  return null;
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

/// The badge of a payment: MANUAL (granted or recorded by an admin), TEST or LIVE.
String adminPaymentModeBadge(Map p) {
  final mode = (p['mode']?.toString() ?? '').toLowerCase();
  final source = (p['source']?.toString() ?? '').toLowerCase();
  final method = (p['method']?.toString() ?? '').toLowerCase();
  if (mode == 'manual' || source == 'manual' || source == 'admin' || method == 'manual') return 'MANUAL';
  if (mode == 'test') return 'TEST';
  return 'LIVE';
}

/// Rupees typed by an admin ("199", "199.5", "₹1,199.50") as paise; null when
/// it is not a positive amount with at most two decimals.
int? adminRupeesToPaise(String text) {
  final clean = text.replaceAll(RegExp(r'[₹,\s]'), '');
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(clean)) return null;
  final paise = (double.parse(clean) * 100).round();
  return paise > 0 ? paise : null;
}

/// Checks a discount (offers: percentage | fixed | price; coupons: percentage | fixed | free).
String? validateDiscount(String type, num? value) {
  switch (type) {
    case 'free':
      return null;
    case 'percentage':
      if (value == null || value <= 0 || value > 100) return 'A percentage must be between 1 and 100.';
      return null;
    case 'fixed':
      if (value == null || value <= 0) return 'The discount must be more than ₹0.';
      return null;
    case 'price':
      if (value == null || value <= 0) return 'The offer price must be more than ₹0.';
      return null;
    default:
      return 'Choose a discount type.';
  }
}

/// "20% off", "₹100 off", "Pay ₹499", "Free".
String adminDiscountLabel(Object? type, Object? value) {
  final v = adminNumOrNull(value) ?? 0;
  switch (type?.toString()) {
    case 'percentage':
      return '${v % 1 == 0 ? v.toInt() : v}% off';
    case 'fixed':
      return '${adminInr(v)} off';
    case 'price':
      return 'Pay ${adminInr(v)}';
    case 'free':
      return 'Free';
    default:
      return '—';
  }
}

/// True only when the admin typed exactly LIVE (the gateway switch to real money).
bool adminLiveConfirmed(String typed) => typed.trim() == 'LIVE';
