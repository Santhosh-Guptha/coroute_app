import 'package:intl/intl.dart';
import '../../core/config/feature_gates.dart';

// Pure helpers of the "Payments & Plans" admin console: labels, money and
// date formatting, and the checks run before a form is sent. No widgets
// and no I/O, so they are unit-tested directly.

/// The paid tiers, in price order, as the server names them.
const List<String> adminPaidTierNames = ['proRider', 'roadCaptain', 'tourOperator'];

/// "CoRoute Pro" for `proRider`, "All plans" for `all`, the raw name otherwise.
String adminTierLabel(Object? tier) {
  final name = tier?.toString() ?? '';
  if (name.isEmpty || name == 'all') return 'All plans';
  for (final t in SubscriptionTier.values) {
    if (t.name.toLowerCase() == name.toLowerCase()) return FeatureGates.tierLabel(t);
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

/// One paid tier's row of the pricing form, as typed.
typedef PlanPriceDraft = ({String monthly, String annual});

/// Checks the pricing form before `PUT /admin/subscription/pricing`: every
/// paid tier needs whole-rupee prices above zero, and a year may never cost
/// less than a month. Returns the first problem in plain words, or null.
String? validatePlanPricing(Map<String, PlanPriceDraft> drafts) {
  for (final tier in [...adminPaidTierNames, ...drafts.keys.where((k) => !adminPaidTierNames.contains(k))]) {
    final d = drafts[tier];
    if (d == null) continue;
    final label = adminTierLabel(tier);
    final monthly = int.tryParse(d.monthly.trim());
    final annual = int.tryParse(d.annual.trim());
    if (monthly == null || monthly <= 0) return '$label: the monthly price must be a whole number of rupees above 0.';
    if (annual == null || annual <= 0) return '$label: the annual price must be a whole number of rupees above 0.';
    if (annual < monthly) {
      return '$label: the annual price (${adminInr(annual)}) cannot be lower than the monthly price (${adminInr(monthly)}).';
    }
  }
  return null;
}

/// The `plans` body of the pricing PUT from a form [validatePlanPricing] accepted.
Map<String, dynamic> planPricingPayload(Map<String, PlanPriceDraft> drafts, Map<String, String> labels) => {
      for (final e in drafts.entries)
        e.key: {
          'monthly': int.parse(e.value.monthly.trim()),
          'annual': int.parse(e.value.annual.trim()),
          'label': labels[e.key] ?? adminTierLabel(e.key),
        },
    };

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
