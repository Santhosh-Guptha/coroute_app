import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/membership_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/membership_service.dart';

/// Plans v2 on the phone: Community is free (solo rides), the group features follow the ride's
/// host plan, the price (coupon + upgrade credit) always comes from the server quote, and a refused
/// coupon never blocks paying.
class _QuoteApi extends ApiClient {
  final List<String> gets = [];
  Object? answer;
  Object? error;
  @override
  Future<dynamic> get(String path, {Duration timeout = const Duration(seconds: 10)}) async {
    gets.add(path);
    if (error != null) throw error!;
    return answer;
  }
}

Map<String, dynamic> _ride(int capacity, {int riders = 1}) => {
      'groupId': 'GRP-1', 'name': 'Ride', 'joinCode': '123456', 'createdByUserId': 'h', 'createdByUserName': 'Host',
      'tripStatus': 'STARTED', 'createdAtEpochMs': 1, 'capacity': capacity,
      'riders': {for (var i = 0; i < riders; i++) 'r$i': {'userId': 'r$i', 'name': 'Rider $i'}},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('PlanQuote', () {
    test('parses the server breakdown: Large Group ₹99 − ₹31 credit for 19 unused days = ₹68', () {
      final q = PlanQuote.fromJson({
        'plan': 'group_large', 'planName': 'Large Group', 'kind': 'upgrade', 'basePriceInr': 99,
        'couponCode': null, 'couponDiscountInr': 0, 'creditInr': 31, 'unusedDays': 19, 'payableInr': 68,
        'startsAt': 1, 'endsAt': 2, 'extraDays': 0,
        'breakdown': [
          {'label': 'Large Group (30 days)', 'amountInr': 99},
          {'label': 'Credit for 19 unused days of Small Group', 'amountInr': -31},
          {'label': 'To pay now', 'amountInr': 68},
        ],
        'summary': 'Large Group ₹99 − ₹31 credit for 19 unused days = ₹68',
        'notes': ['Starts now and runs 30 days, until 5 Dec.'],
        'couponError': null,
      });
      expect([q.basePriceInr, q.creditInr, q.unusedDays, q.payableInr], [99, 31, 19, 68]);
      expect(q.isFree, isFalse);
      expect(q.couponRefused, isFalse);
      expect(q.itemLines.map((l) => l.amountText), ['₹99', '−₹31']);
      expect(q.summary, 'Large Group ₹99 − ₹31 credit for 19 unused days = ₹68');
    });

    test('a refused code comes back with the full price and its reason, never as a failure', () {
      final q = PlanQuote.fromJson({
        'plan': 'group_small', 'basePriceInr': 49, 'payableInr': 49,
        'couponError': {'code': 'NOPE', 'reason': 'COUPON_NOT_FOUND', 'error': "We couldn't find that code"},
      });
      expect(q.couponRefused, isTrue);
      expect(q.hasCoupon, isFalse);
      expect(q.payableInr, 49);
      expect(couponErrorMessage(q.couponErrorReason), "We couldn't find that code");
    });

    test('list price before the server answered', () {
      final q = PlanQuote.listPrice(const MembershipCategory(id: 'group_small', name: 'Small Group', priceRupees: 49, capacity: 6));
      expect([q.payableInr, q.creditInr, q.couponDiscountInr], [49, 0, 0]);
      expect(q.itemLines.single.amountText, '₹49');
    });
  });

  group('MembershipService.fetchQuote', () {
    test('asks the server with the plan and the code (trimmed, upper case)', () async {
      final api = _QuoteApi()..answer = {'plan': 'group_large', 'basePriceInr': 99, 'payableInr': 50, 'couponCode': 'WELCOME50', 'couponDiscountInr': 49};
      final ms = MembershipService(api);
      final q = await ms.fetchQuote(categoryId: 'group_large', couponCode: ' welcome50 ');
      expect(api.gets.single, '/membership/quote?plan=group_large&coupon=WELCOME50');
      expect(q!.payableInr, 50);
      expect(q.hasCoupon, isTrue);
      await ms.fetchQuote(categoryId: 'group_small');
      expect(api.gets.last, '/membership/quote?plan=group_small');
    });

    test('a plan the server refuses (retired Individual): null with the reason', () async {
      final api = _QuoteApi()..error = const ApiException(410, 'The Individual plan is no longer sold.', 'LEGACY_PLAN', 'LEGACY_PLAN');
      final ms = MembershipService(api);
      expect(await ms.fetchQuote(categoryId: 'individual'), isNull);
      expect(ms.lastErrorReason, 'LEGACY_PLAN');
    });
  });

  group('catalog and plan', () {
    test('Community is listed but never bought; the paid plans are, cheapest first', () {
      final cat = MembershipCatalog.fromJson({
        'categories': {
          'group_large': {'name': 'Large Group', 'monthlyPriceInr': 99, 'capacity': 12},
          'community': {'name': 'Community', 'monthlyPriceInr': 0, 'capacity': 1, 'purchasable': false},
          'individual': {'name': 'Individual', 'monthlyPriceInr': 9, 'capacity': 1},
          'group_small': {'name': 'Small Group', 'monthlyPriceInr': 49, 'capacity': 6},
        },
      });
      expect(cat.paidCategories.map((c) => c.id), ['group_small', 'group_large']);
      expect(cat.community!.canBuy, isFalse);
      expect(cat.community!.isCommunity, isTrue);
    });

    test('every rider has at least Community; a service without data says so too', () {
      final ms = MembershipService(_QuoteApi());
      expect(ms.planAccess.source, 'community');
      expect(ms.planAccess.canStartTrip, isTrue);
      expect(ms.planAccess.canHostGroup, isFalse);
    });
  });

  group('solo ride vs group ride', () {
    test('a Community host ride (one seat) is solo: no talk, messages, invite or regroup', () {
      final solo = ConvoyModel.fromJson(_ride(1));
      expect(solo.isSoloRide, isTrue);
      expect(solo.hasGroupFeatures, isFalse);
      expect(FeatureGates.availableInRide(Feature.dynamicWaypointPush, soloRide: solo.isSoloRide), isFalse);
      // Safety is never gated.
      expect(FeatureGates.availableInRide(Feature.guardianLiveShare, soloRide: true), isTrue);
      expect(FeatureGates.availableInRide(Feature.satelliteSosRelay, soloRide: true), isTrue);
    });

    test('a group ride shows the group features to every rider, also while the host is alone', () {
      final alone = ConvoyModel.fromJson(_ride(6));
      expect(alone.isSolo, isTrue, reason: 'only one rider so far');
      expect(alone.isSoloRide, isFalse);
      expect(alone.hasGroupFeatures, isTrue);
      expect(ConvoyModel.fromJson(_ride(12, riders: 3)).hasGroupFeatures, isTrue);
      // An upgrade during the ride (CONFIG capacity) turns a solo ride into a group ride.
      expect(ConvoyModel.fromJson(_ride(1)).copyWith(capacity: 6).hasGroupFeatures, isTrue);
      // Unknown seats (older gateway): group features stay.
      expect(ConvoyModel.fromJson(_ride(0)).hasGroupFeatures, isTrue);
    });
  });
}
