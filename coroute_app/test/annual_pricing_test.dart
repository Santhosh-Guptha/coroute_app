import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/services/plan_subscription_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    PlanSubscriptionService.setConfiguredPlans(null);
    FeatureGates.activeTier = SubscriptionTier.community;
    FeatureGates.forceAllUnlocked = false;
  });

  group('annual saving', () {
    test('saving is twelve months minus the annual price', () {
      expect(PlanSubscriptionService.annualSaving(149, 1199), 589);
      expect(PlanSubscriptionService.annualSaving(599, 4499), 2689);
    });

    test('percentage is of twelve monthly payments, rounded', () {
      expect(PlanSubscriptionService.annualSavingPercent(149, 1199), 33); // 589 / 1788
      expect(PlanSubscriptionService.annualSavingPercent(100, 1000), 17); // 200 / 1200
      expect(PlanSubscriptionService.annualSavingPercent(100, 1200), 0);
    });

    test('never negative, and zero for missing prices', () {
      expect(PlanSubscriptionService.annualSaving(100, 1500), 0);
      expect(PlanSubscriptionService.annualSavingPercent(100, 1500), 0);
      expect(PlanSubscriptionService.annualSaving(0, 1199), 0);
      expect(PlanSubscriptionService.annualSaving(149, 0), 0);
    });
  });

  group('priceOf', () {
    test('uses the server config (/subscription/config plans) when present', () {
      PlanSubscriptionService.setConfiguredPlans({
        'proRider': {'monthly': 50, 'annual': 500, 'label': 'CoRoute Pro'},
      });
      expect(PlanSubscriptionService.priceOf(SubscriptionTier.proRider, annual: false), 50);
      expect(PlanSubscriptionService.priceOf(SubscriptionTier.proRider, annual: true), 500);
      // Not configured: built-in fallback.
      expect(PlanSubscriptionService.priceOf(SubscriptionTier.roadCaptain, annual: true), 4499);
    });

    test('Community is free, and missing config falls back to built-in prices', () {
      expect(PlanSubscriptionService.priceOf(SubscriptionTier.community, annual: true), 0);
      expect(PlanSubscriptionService.priceOf(SubscriptionTier.tourOperator, annual: false), 1999);
    });

    test('best saving across tiers drives the toggle label', () {
      PlanSubscriptionService.setConfiguredPlans({
        'proRider': {'monthly': 100, 'annual': 1200},
        'roadCaptain': {'monthly': 500, 'annual': 3000}, // 50 %
        'tourOperator': {'monthly': 1000, 'annual': 10000},
      });
      expect(PlanSubscriptionService.bestAnnualSavingPercent(), 50);
    });
  });

  test('formatInr groups thousands and keeps paise', () {
    expect(PlanSubscriptionService.formatInr(589), '₹589');
    expect(PlanSubscriptionService.formatInr(2689), '₹2,689');
    expect(PlanSubscriptionService.formatInr(49.5), '₹49.50');
  });

  group('plan changes while a paid plan is held', () {
    test('upgrade credits the remaining days; a cheaper tier waits for the end', () {
      final service = PlanSubscriptionService();
      addTearDown(service.dispose);
      final until = DateTime.now().add(const Duration(days: 12)).millisecondsSinceEpoch;
      service.applyServerSubscription('roadCaptain', until);

      expect(service.planChangeNote(SubscriptionTier.tourOperator), 'Your remaining Road Captain days are credited to Tour Operator.');
      expect(service.isQueuedDowngrade(SubscriptionTier.tourOperator), isFalse);

      final note = service.planChangeNote(SubscriptionTier.proRider)!;
      expect(note, startsWith('Starts when your Road Captain ends on '));
      expect(note, contains(PlanSubscriptionService.formatDate(until)));
      expect(service.isQueuedDowngrade(SubscriptionTier.proRider), isTrue);

      expect(service.planChangeNote(SubscriptionTier.roadCaptain), isNull, reason: 'renewing the same plan');
      expect(service.planChangeNote(SubscriptionTier.community), isNull);
    });

    test('no note without a paid plan', () {
      final service = PlanSubscriptionService();
      addTearDown(service.dispose);
      expect(service.planChangeNote(SubscriptionTier.proRider), isNull);
      expect(service.isQueuedDowngrade(SubscriptionTier.proRider), isFalse);
    });

    test('pendingTier from subscriptionStatus is shown as the next plan', () {
      final service = PlanSubscriptionService();
      addTearDown(service.dispose);
      final until = DateTime.now().add(const Duration(days: 5)).millisecondsSinceEpoch;
      service.applySubscriptionStatus({
        'tier': 'roadCaptain',
        'validUntil': until,
        'pendingTier': 'proRider',
        'pendingStartsAt': until,
      });
      expect(service.pendingTier, SubscriptionTier.proRider);
      expect(service.pendingPlanSummary, 'CoRoute Pro starts ${PlanSubscriptionService.formatDate(until)}');

      service.applySubscriptionStatus({'tier': 'roadCaptain', 'validUntil': until});
      expect(service.pendingTier, isNull);

      // Object form from the gateway: {tier, startsAt}.
      service.applySubscriptionStatus({
        'tier': 'roadCaptain',
        'validUntil': until,
        'pendingTier': {'tier': 'proRider', 'startsAt': until},
      });
      expect(service.pendingTier, SubscriptionTier.proRider);
      expect(service.pendingStartsAt, until);
    });
  });

  group('SUBSCRIPTION_REVOKED', () {
    test('ends the plan like an expiry, worded as ended by support', () {
      final service = PlanSubscriptionService();
      addTearDown(service.dispose);
      service.applyServerSubscription('proRider', DateTime.now().add(const Duration(days: 20)).millisecondsSinceEpoch);
      service.handleRevokedEvent({'previousTier': 'proRider', 'revokedAt': 1000, 'reason': 'Duplicate account'});
      expect(service.entitledTier, SubscriptionTier.community);
      expect(service.isExpired, isTrue);
      final n = service.expiredNotice!;
      expect(n.previousTier, SubscriptionTier.proRider);
      expect(n.reason, PlanEndReason.revoked);
      expect(n.note, 'Duplicate account');
    });

    test('a refund reason is reported as refunded', () {
      final service = PlanSubscriptionService();
      addTearDown(service.dispose);
      service.applyServerSubscription('tourOperator', DateTime.now().add(const Duration(days: 20)).millisecondsSinceEpoch);
      service.handleRevokedEvent({'previousTier': 'tourOperator', 'reason': 'full refund'});
      expect(service.expiredNotice!.reason, PlanEndReason.refunded);
    });
  });
}
