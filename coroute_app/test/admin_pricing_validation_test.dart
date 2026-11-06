import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/presentation/admin/admin_payments_logic.dart';

void main() {
  // The legacy tier pricing form (validatePlanPricing / planPricingPayload) was retired: legacy
  // tiers are not sold any more. Plan labels the admin sees now:
  group('plan labels', () {
    test('membership plans by name, legacy tiers read-only as Legacy', () {
      expect(adminTierLabel('group_small'), 'Small Group (2–6)');
      expect(adminTierLabel('group_large'), 'Large Group (7–12)');
      expect(adminTierLabel('individual'), 'Individual (retired)');
      expect(adminTierLabel('roadCaptain'), 'Legacy: Road Captain');
      expect(adminTierLabel('proRider'), 'Legacy: CoRoute Pro');
      expect(adminTierLabel('community'), 'Community');
      expect(adminTierLabel('all'), 'All plans');
      expect(adminMembershipPlanIds(const [
        {'id': 'proRider', 'kind': 'subscription'},
        {'id': 'club_xl', 'kind': 'membership'},
      ]), ['group_small', 'group_large']);
    });
  });

  group('helpers', () {
    test('rupees typed by an admin become paise', () {
      expect(adminRupeesToPaise('199'), 19900);
      expect(adminRupeesToPaise('₹1,199.50'), 119950);
      expect(adminRupeesToPaise('0'), isNull);
      expect(adminRupeesToPaise('1.234'), isNull);
      expect(adminRupeesToPaise('abc'), isNull);
    });

    test('LIVE needs the exact word', () {
      expect(adminLiveConfirmed('LIVE'), isTrue);
      expect(adminLiveConfirmed(' LIVE '), isTrue);
      expect(adminLiveConfirmed('live'), isFalse);
      expect(adminLiveConfirmed(''), isFalse);
    });

    test('discount checks', () {
      expect(validateDiscount('percentage', 20), isNull);
      expect(validateDiscount('percentage', 120), isNotNull);
      expect(validateDiscount('fixed', 0), isNotNull);
      expect(validateDiscount('price', 499), isNull);
      expect(validateDiscount('free', null), isNull);
      expect(validateDiscount('bogus', 1), isNotNull);
    });

    test('payment badges', () {
      expect(adminPaymentModeBadge({'mode': 'test'}), 'TEST');
      expect(adminPaymentModeBadge({'mode': 'live'}), 'LIVE');
      expect(adminPaymentModeBadge({'mode': 'manual'}), 'MANUAL');
      expect(adminPaymentModeBadge({'mode': null}), 'LIVE');
    });

    test('money formatting', () {
      expect(adminInr(1199), '₹1,199');
      expect(adminInr(119999), '₹1,19,999');
      expect(adminInrPaise(19950), '₹199.50');
    });
  });
}
