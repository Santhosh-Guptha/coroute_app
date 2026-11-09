// 3.55 coupon QR / link (`<origin>/get?coupon=CODE`, Play Install Referrer `coupon=CODE`): parsing,
// format check, 7-day expiry and the stored code; and the upgrade-only plan rule the plan screens use.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/services/pending_coupon_store.dart';
import 'package:coroute_app/domain/marketing/pending_coupon.dart';
import 'package:coroute_app/domain/membership/plan_change_rules.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('coupon code from a link', () {
    test('format: A-Z 0-9 - _, at most 24, cleaned to upper case', () {
      expect(PendingCoupon.clean(' welcome50 '), 'WELCOME50');
      expect(PendingCoupon.clean('RIDE-FREE_1'), 'RIDE-FREE_1');
      expect(PendingCoupon.clean('A' * 24), 'A' * 24);
      expect(PendingCoupon.clean('A' * 25), isNull);
      expect(PendingCoupon.clean(''), isNull);
      expect(PendingCoupon.clean(null), isNull);
      expect(PendingCoupon.clean('<script>'), isNull);
      expect(PendingCoupon.clean('CODE 1'), isNull);
      expect(PendingCoupon.clean('ÇODE'), isNull);
    });

    test('app link: /get?coupon= on the site hosts and coroute://get', () {
      expect(PendingCoupon.fromUri(Uri.parse('https://coroute.devmonks.space/get?coupon=welcome50')), 'WELCOME50');
      expect(PendingCoupon.fromUri(Uri.parse('https://coroute.duckdns.org/get/?coupon=RIDERFREE&utm_source=qr')), 'RIDERFREE');
      expect(PendingCoupon.fromUri(Uri.parse('https://coroute.devmonks.space/get.html?coupon=X1')), 'X1');
      expect(PendingCoupon.fromUri(Uri.parse('coroute://get?coupon=x1')), 'X1');
      // Other links are not coupons (a join code stays a join code).
      expect(PendingCoupon.fromUri(Uri.parse('https://coroute.devmonks.space/join/ABC123?coupon=X1')), isNull);
      expect(PendingCoupon.fromUri(Uri.parse('https://coroute.devmonks.space/get')), isNull);
      expect(PendingCoupon.fromUri(Uri.parse('https://coroute.devmonks.space/get?coupon=%3Cb%3E')), isNull);
    });

    test('install referrer: coupon=CODE, encoded once or not, with other parameters', () {
      expect(PendingCoupon.fromReferrer('coupon=WELCOME50'), 'WELCOME50');
      expect(PendingCoupon.fromReferrer('coupon%3Dwelcome50'), 'WELCOME50');
      expect(PendingCoupon.fromReferrer('utm_source=google-play&coupon=RIDE-1&utm_medium=organic'), 'RIDE-1');
      expect(PendingCoupon.fromReferrer('utm_source=google-play&utm_medium=organic'), isNull);
      expect(PendingCoupon.fromReferrer(''), isNull);
      expect(PendingCoupon.fromReferrer(null), isNull);
      expect(PendingCoupon.fromReferrer('coupon=bad%20code'), isNull);
    });

    test('expires after 7 days', () {
      const t0 = 1700000000000;
      const p = PendingCoupon('WELCOME50', t0);
      expect(p.isExpired(t0 + const Duration(days: 6).inMilliseconds), isFalse);
      expect(p.isExpired(t0 + const Duration(days: 7, minutes: 1).inMilliseconds), isTrue);
      expect(PendingCoupon.fromJson(p.toJson())?.code, 'WELCOME50');
      expect(PendingCoupon.fromJson({'code': '<x>', 'savedAt': t0}), isNull);
      expect(PendingCoupon.fromJson('nope'), isNull);
    });

    test('store: saves a valid code, drops it after 7 days, ignores an invalid one', () async {
      SharedPreferences.setMockInitialValues({});
      const t0 = 1700000000000;
      expect(await PendingCouponStore.save('bad code', nowMs: t0), isNull);
      expect(await PendingCouponStore.read(nowMs: t0), isNull);
      expect(await PendingCouponStore.save('welcome50', nowMs: t0), 'WELCOME50');
      expect(await PendingCouponStore.read(nowMs: t0 + const Duration(days: 3).inMilliseconds), 'WELCOME50');
      expect(await PendingCouponStore.read(nowMs: t0 + const Duration(days: 8).inMilliseconds), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PendingCouponStore.keyPending), isNull, reason: 'expired code removed');
      await PendingCouponStore.save('RIDERFREE', nowMs: t0);
      await PendingCouponStore.clear();
      expect(await PendingCouponStore.read(nowMs: t0), isNull);
    });
  });

  group('plan change: upgrade only while a paid plan runs', () {
    test('bigger plans only; any plan once it has ended', () {
      bool can(String? cur, bool active, String to) =>
          PlanChangeRules.canChoose(currentPlan: cur, currentActive: active, target: to);
      expect(can('group_small', true, 'group_large'), isTrue);
      expect(can('group_large', true, 'group_small'), isFalse);
      expect(can('group_large', true, 'group_large'), isFalse);
      expect(can('group_small', true, 'group_small'), isFalse);
      expect(can('group_small', true, 'community'), isFalse);
      expect(can('individual', true, 'group_small'), isTrue);
      expect(can('group_large', false, 'group_small'), isTrue);
      expect(can(null, false, 'group_small'), isTrue);
      expect(PlanChangeRules.note, 'You can move to a bigger plan anytime. Smaller plans can be chosen when your current plan ends.');
    });
  });
}
