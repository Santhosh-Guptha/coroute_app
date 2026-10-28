import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/presentation/admin/admin_payments_logic.dart';

void main() {
  PlanPriceDraft d(String m, String a) => (monthly: m, annual: a);

  group('validatePlanPricing', () {
    test('accepts whole-rupee prices with annual at or above monthly', () {
      expect(
        validatePlanPricing({
          'proRider': d('149', '1199'),
          'roadCaptain': d('599', '599'),
          'tourOperator': d(' 1999 ', '14999'),
        }),
        isNull,
      );
    });

    test('rejects an annual price below the monthly price', () {
      final e = validatePlanPricing({'proRider': d('149', '100')});
      expect(e, isNotNull);
      expect(e, contains('CoRoute Pro'));
      expect(e, contains('cannot be lower'));
    });

    test('rejects zero, negative, blank and decimal prices', () {
      expect(validatePlanPricing({'proRider': d('0', '1199')}), contains('monthly'));
      expect(validatePlanPricing({'proRider': d('-5', '1199')}), contains('monthly'));
      expect(validatePlanPricing({'proRider': d('149', '')}), contains('annual'));
      expect(validatePlanPricing({'proRider': d('149.5', '1199')}), contains('monthly'));
    });

    test('reports the first bad tier in price order', () {
      final e = validatePlanPricing({
        'tourOperator': d('1999', '10'),
        'proRider': d('149', '10'),
      });
      expect(e, startsWith('CoRoute Pro'));
    });

    test('payload carries numbers and labels', () {
      final body = planPricingPayload({'proRider': d('149', '1199')}, {'proRider': 'Pro'});
      expect(body, {
        'proRider': {'monthly': 149, 'annual': 1199, 'label': 'Pro'},
      });
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
