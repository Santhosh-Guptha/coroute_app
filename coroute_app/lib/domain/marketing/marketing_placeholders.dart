// 3.55 Marketing studio: {placeholders} in template text, filled from the bound coupon.
//
//   {code}        FEST40
//   {discount}    40% off  /  ₹100 off  /  Free
//   {validUntil}  30 Nov 2030 (India time)
//   {plan}        Small Group plan  /  all plans
//   {name}        the coupon's display name
//   {cap}         up to ₹60 (percentage coupons with a cap, else empty)
//   {link}        the download / offer link (also what the QR code holds)
//
// The gateway computes the same values (couponPlaceholders in gateway/src/marketing_templates.js)
// and sends them with the template; the app prefers the server's values and computes them itself
// only when they are missing. Unknown {words} are left as typed.

import 'marketing_template.dart';

class MkPlaceholders {
  static const List<String> names = ['code', 'discount', 'validUntil', 'plan', 'name', 'cap', 'link'];

  /// What the editor shows while no coupon is bound (clearly sample values).
  static const Map<String, String> sample = {
    'code': 'RIDE50',
    'discount': '50% off',
    'validUntil': '31 Dec 2026',
    'plan': 'Small Group plan',
    'name': 'Sample offer',
    'cap': 'up to ₹100',
    'link': 'https://coroute.app/get',
  };

  static final RegExp _re = RegExp(r'\{([A-Za-z]+)\}');

  /// [text] with every known placeholder replaced from [values]; unknown ones stay.
  static String substitute(String text, Map<String, String> values) =>
      text.replaceAllMapped(_re, (m) => names.contains(m.group(1)) && values.containsKey(m.group(1)) ? values[m.group(1)]! : m.group(0)!);

  /// Placeholder names used in [text].
  static Set<String> usedIn(String text) => {for (final m in _re.allMatches(text)) if (names.contains(m.group(1))) m.group(1)!};

  /// True when the template shows coupon data (a coupon layer, or a coupon placeholder anywhere).
  static bool templateNeedsCoupon(MarketingTemplate t) {
    bool coupon(String s) => usedIn(s).any((n) => n != 'link');
    if (coupon(t.caption)) return true;
    for (final l in t.layers) {
      if (l.hidden) continue;
      switch (l.type) {
        case MkLayerType.coupon:
          return true;
        case MkLayerType.text:
          if (coupon(l.text)) return true;
        case MkLayerType.shape:
          if (coupon(l.label)) return true;
        case MkLayerType.qr:
          if (coupon(l.data)) return true;
        default:
          break;
      }
    }
    return false;
  }

  /// The link for {link} and the QR code: the template's own link (may hold {code}) or
  /// `<site>/get?coupon=<code>` (just `<site>/get` without a coupon).
  static String resolveLink(String linkTemplate, {required String siteBase, String? code}) {
    final base = siteBase.endsWith('/') ? siteBase.substring(0, siteBase.length - 1) : siteBase;
    final c = (code ?? '').trim();
    final t = linkTemplate.trim();
    if (t.isEmpty) return c.isEmpty ? '$base/get' : '$base/get?coupon=${Uri.encodeQueryComponent(c)}';
    return t.replaceAll('{code}', Uri.encodeQueryComponent(c));
  }

  /// Values for [coupon]: the gateway's when sent, otherwise computed here (same rules).
  static Map<String, String> forCoupon(MkCouponInfo coupon, {required String link, Map<String, String> planLabels = const {}}) {
    final server = coupon.placeholders;
    final local = {
      'code': coupon.code,
      'discount': discountText(coupon.discountType, coupon.discountValue),
      'validUntil': formatDate(coupon.expiresAt),
      'plan': planText(coupon.plans, planLabels),
      'name': coupon.name.isEmpty ? coupon.code : coupon.name,
      'cap': coupon.discountType == 'percentage' && (coupon.maxDiscountCap ?? 0) > 0 ? 'up to ${inr(coupon.maxDiscountCap!)}' : '',
    };
    return {...local, ...?server, 'link': link};
  }

  /// The values the editor uses: the bound coupon's, or the samples (with the real link).
  static Map<String, String> valuesFor(MarketingTemplate t, {required String siteBase}) {
    final c = t.coupon;
    final link = resolveLink(t.link, siteBase: siteBase, code: c?.code ?? t.couponCode);
    if (c == null || c.missing) return {...sample, 'link': link};
    return forCoupon(c, link: link);
  }

  static String inr(num v) {
    final whole = v == v.roundToDouble();
    final s = whole ? v.round().toString() : v.toStringAsFixed(2);
    return '₹${_indianGrouping(s)}';
  }

  static String _indianGrouping(String s) {
    final parts = s.split('.');
    var n = parts[0];
    if (n.length > 3) {
      final last3 = n.substring(n.length - 3);
      var rest = n.substring(0, n.length - 3);
      final groups = <String>[];
      while (rest.length > 2) {
        groups.insert(0, rest.substring(rest.length - 2));
        rest = rest.substring(0, rest.length - 2);
      }
      if (rest.isNotEmpty) groups.insert(0, rest);
      n = '${groups.join(',')},$last3';
    }
    return parts.length > 1 ? '$n.${parts[1]}' : n;
  }

  static String discountText(String type, num value) {
    if (type == 'free' || (type == 'percentage' && value >= 100)) return 'Free';
    if (type == 'fixed') return '${inr(value)} off';
    final v = (value * 100).round() / 100;
    return '${v == v.roundToDouble() ? v.round() : v}% off';
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "30 Nov 2026" in India time (UTC+5:30), or '' without a date.
  static String formatDate(int? ms) {
    if (ms == null || ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).add(const Duration(hours: 5, minutes: 30));
    return '${d.day} ${_months[d.month - 1]} ${d.year}';
  }

  static const Map<String, String> planFallback = {'group_small': 'Small Group', 'group_large': 'Large Group', 'individual': 'Small Group', 'community': 'Community'};

  static String planText(List<String> tiers, [Map<String, String> labels = const {}]) {
    if (tiers.isEmpty || tiers.contains('all')) return 'all plans';
    final names = <String>[];
    for (final t in tiers) {
      final n = labels[t] ?? planFallback[t] ?? t;
      if (!names.contains(n)) names.add(n);
    }
    if (names.length == 1) return '${names.first} plan';
    return '${names.sublist(0, names.length - 1).join(', ')} & ${names.last} plans';
  }

  /// A ready-to-post caption: the offer, the code, the validity and the link.
  static String autoCaption(Map<String, String> v, {bool bound = true}) {
    if (!bound) return 'Ride together with CoRoute: live group tracking, intercom and SOS for every ride.\nGet the app: ${v['link'] ?? ''}';
    final cap = (v['cap'] ?? '').isEmpty ? '' : ' (${v['cap']})';
    final until = (v['validUntil'] ?? '').isEmpty ? '' : ' Valid till ${v['validUntil']}.';
    return 'Ride together for less: ${v['discount']}$cap on the CoRoute ${v['plan']}. '
        'Use code ${v['code']} in the app.$until\n'
        'Get CoRoute: ${v['link']}';
  }
}
