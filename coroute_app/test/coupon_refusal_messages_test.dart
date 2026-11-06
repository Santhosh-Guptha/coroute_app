import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/membership_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('Coupon refusal messages', () {
    test('every reason the gateway sends has a short plain message', () {
      const reasons = [
        'COUPON_NOT_FOUND',
        'COUPON_EXPIRED',
        'COUPON_SCHEDULED',
        'COUPON_LIMIT_REACHED',
        'COUPON_INACTIVE',
        'PER_USER_LIMIT_REACHED',
        'TIER_MISMATCH',
        'CYCLE_MISMATCH',
        'MIN_ORDER_NOT_MET',
        'COUPON_REQUIRED',
        'PLAN_INACTIVE',
      ];
      for (final r in reasons) {
        final m = couponErrorMessage(r);
        expect(m, isNotNull, reason: r);
        expect(m!.length, lessThan(60), reason: r);
      }
      expect(couponErrorMessage('PER_USER_LIMIT_REACHED'), "You've already used this code");
      expect(couponErrorMessage('TIER_MISMATCH'), "This code isn't for this plan");
      expect(couponErrorMessage('COUPON_EXPIRED'), 'Code expired');
      expect(couponErrorMessage('SESSION_INVALID'), isNull);
      expect(couponErrorMessage(null), isNull);
    });

    test('only coupon refusals let the rider continue at the normal price', () {
      expect(isCouponRefusal('PER_USER_LIMIT_REACHED'), isTrue);
      expect(isCouponRefusal('COUPON_EXPIRED'), isTrue);
      expect(isCouponRefusal('CYCLE_MISMATCH'), isTrue);
      expect(isCouponRefusal('PLAN_INACTIVE'), isFalse);
      expect(isCouponRefusal('CAPACITY_CONFLICT'), isFalse);
      expect(isCouponRefusal(null), isFalse);
    });

    test('free only when the server says so; discounts are never assumed', () {
      expect(couponServerConfirmsFree({'valid': true, 'isFree': true}), isTrue);
      expect(couponServerConfirmsFree({'valid': true, 'finalAmount': 0}), isTrue);
      expect(couponServerConfirmsFree({'valid': true, 'finalAmount': 6, 'isFree': false}), isFalse);
      expect(couponServerConfirmsFree({'valid': true}), isFalse);
      expect(couponServerConfirmsFree({'valid': false, 'isFree': true}), isFalse);
      expect(couponDiscountRupees({'valid': true}, 9), 0);
      expect(couponDiscountRupees({'discountAmount': 3}, 9), 3);
      expect(couponDiscountRupees({'discountInr': 20}, 9), 9);
      expect(couponDiscountRupees({'discountPercent': 50}, 10), 5);
    });
  });

  group('Gateway reason codes reach the membership service', () {
    MembershipService answering(int status, Map<String, dynamic> body, List<http.Request> seen) {
      final client = MockClient((req) async {
        seen.add(req);
        return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
      });
      return MembershipService(ApiClient(httpClient: client, storage: const FlutterSecureStorage()));
    }

    test('ApiException carries the reason from the error body', () async {
      final client = MockClient((_) async => http.Response(
            jsonEncode({'error': 'Coupon RIDERFREE is not valid for Group', 'reason': 'TIER_MISMATCH'}),
            400,
            headers: {'content-type': 'application/json'},
          ));
      final api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
      try {
        await api.post('/membership/order', {'category': 'group_large', 'offerCode': 'RIDERFREE'});
        fail('a 400 must throw');
      } on ApiException catch (e) {
        expect(e.statusCode, 400);
        expect(e.reason, 'TIER_MISMATCH');
        expect(e.code, isNull);
        expect(e.endsSession, isFalse);
      }
    });

    test('a refused code keeps its reason and gets the plain message', () async {
      final seen = <http.Request>[];
      final ms = answering(400, {
        'valid': false,
        'error': 'You have reached the redemption limit (1) for coupon RIDERFREE',
        'reason': 'PER_USER_LIMIT_REACHED',
      }, seen);
      final res = await ms.validateCoupon(code: 'riderfree', categoryId: 'individual');
      expect(res, isNull);
      expect(ms.lastErrorReason, 'PER_USER_LIMIT_REACHED');
      expect(ms.lastError, "You've already used this code");
      expect(ms.lastErrorIsCouponRefusal, isTrue);
      expect(jsonDecode(seen.single.body), {'code': 'RIDERFREE', 'category': 'individual'});
    });

    test('an order without a code sends none; a plan that is off sale is not a coupon refusal', () async {
      final seen = <http.Request>[];
      final ms = answering(400, {'error': 'Group Small is not on sale right now', 'reason': 'PLAN_INACTIVE'}, seen);
      final res = await ms.createOrder(categoryId: 'group_small');
      expect(res, isNull);
      final sent = jsonDecode(seen.single.body) as Map<String, dynamic>;
      expect(sent.containsKey('offerCode'), isFalse);
      expect(sent.containsKey('couponCode'), isFalse);
      expect(ms.lastErrorReason, 'PLAN_INACTIVE');
      expect(ms.lastError, "This plan isn't on sale right now");
      expect(ms.lastErrorIsCouponRefusal, isFalse);
    });

    test('a free activation the server refuses reports the coupon reason', () async {
      final seen = <http.Request>[];
      final ms = answering(400, {'error': 'Coupon is expired', 'reason': 'COUPON_EXPIRED'}, seen);
      final mem = await ms.activateFreeMembership(categoryId: 'individual', couponCode: 'oldcode');
      expect(mem, isNull);
      expect(jsonDecode(seen.single.body), {'category': 'individual', 'couponCode': 'OLDCODE'});
      expect(ms.lastError, 'Code expired');
      expect(ms.lastErrorIsCouponRefusal, isTrue);
    });
  });
}
