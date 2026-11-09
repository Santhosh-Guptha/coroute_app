// Prints the starter templates (bound to a sample coupon, with QR matrices) as JSON for render.js.
import 'dart:convert';
import 'dart:io';
import 'package:coroute_app/domain/marketing/marketing_layout.dart';
import 'package:coroute_app/domain/marketing/marketing_placeholders.dart';
import 'package:coroute_app/domain/marketing/marketing_template.dart';
import 'package:coroute_app/domain/marketing/qr_encoder.dart';
import 'package:coroute_app/domain/marketing/starter_templates.dart';
void main() {
  final coupon = MkCouponInfo(code: 'DIWALI40', name: 'Diwali 40', discountType: 'percentage', discountValue: 40, maxDiscountCap: 60, expiresAt: DateTime.utc(2026, 11, 30, 12).millisecondsSinceEpoch, plans: const ['group_small', 'group_large']);
  final out = <String, dynamic>{};
  void add(String k, MarketingTemplate t) {
    t..couponCode = coupon.code..coupon = coupon;
    final v = MkPlaceholders.valuesFor(t, siteBase: 'https://coroute.duckdns.org');
    final q = QrCode.encode(v['link']!);
    out[k] = {'t': t.toJson(), 'values': v, 'qr': [for (var y = 0; y < q.size; y++) [for (var x = 0; x < q.size; x++) q.isDark(x, y) ? 1 : 0].join()]};
  }
  for (final s in MkStarters.all) { add(s.id, s.build()); }
  add('festive_banner', mkRetarget(MkStarters.festive(), MkSize.of(MkSizePreset.banner)));
  add('festive_story', mkRetarget(MkStarters.festive(), MkSize.of(MkSizePreset.instagramStory)));
  stdout.write(jsonEncode(out));
}
