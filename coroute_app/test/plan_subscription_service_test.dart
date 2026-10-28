import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/services/plan_subscription_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    FeatureGates.activeTier = SubscriptionTier.community;
    FeatureGates.forceAllUnlocked = false;
  });

  group('PlanSubscriptionService', () {
    test('defaults to community tier with 4 riders and basic features', () async {
      final service = PlanSubscriptionService();
      await service.load();

      expect(service.currentTier, equals(SubscriptionTier.community));
      expect(service.maxConvoyMembers, equals(4));
      expect(service.isUnlocked(Feature.priorityIntercomDucking), isFalse);
    });

    test('selectTier within the entitlement updates the effective tier and FeatureGates', () async {
      final service = PlanSubscriptionService();
      await service.load();

      final futureExpiry = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch;
      service.applyServerSubscription('roadCaptain', futureExpiry);
      expect(await service.selectTier(SubscriptionTier.community), isTrue);
      expect(service.currentTier, equals(SubscriptionTier.community));

      expect(await service.selectTier(SubscriptionTier.roadCaptain), isTrue);

      expect(service.currentTier, equals(SubscriptionTier.roadCaptain));
      expect(FeatureGates.activeTier, equals(SubscriptionTier.roadCaptain));
      expect(service.maxConvoyMembers, equals(40));
      expect(service.isUnlocked(Feature.priorityIntercomDucking), isTrue);
      expect(service.isUnlocked(Feature.roadHazardBroadcast), isTrue);
    });

    test('selectTier above the entitlement is refused and changes nothing (needs checkout)', () async {
      final service = PlanSubscriptionService();
      await service.load();

      expect(await service.selectTier(SubscriptionTier.proRider), isFalse);
      expect(service.currentTier, equals(SubscriptionTier.community));
      expect(service.preferredTier, equals(SubscriptionTier.community));
      expect(FeatureGates.activeTier, equals(SubscriptionTier.community));

      final futureExpiry = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch;
      service.applyServerSubscription('proRider', futureExpiry);
      expect(service.canSelect(SubscriptionTier.proRider), isTrue);
      expect(service.canSelect(SubscriptionTier.roadCaptain), isFalse);
      expect(await service.selectTier(SubscriptionTier.roadCaptain), isFalse);
      expect(service.currentTier, equals(SubscriptionTier.proRider));
      expect(service.entitledTier, equals(SubscriptionTier.proRider));
      expect(service.validUntil, equals(futureExpiry));
    });

    test('a paid plan survives selectTier(community) and comes back without paying', () async {
      final service = PlanSubscriptionService();
      await service.load();

      final futureExpiry = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch;
      service.applyServerSubscription('proRider', futureExpiry);
      expect(service.isEntitledTo(SubscriptionTier.proRider), isTrue);
      expect(service.currentTier, equals(SubscriptionTier.proRider));

      expect(await service.selectTier(SubscriptionTier.community), isTrue);
      expect(service.currentTier, equals(SubscriptionTier.community));
      expect(service.preferredTier, equals(SubscriptionTier.community));
      expect(service.entitledTier, equals(SubscriptionTier.proRider));
      expect(service.validUntil, equals(futureExpiry));
      expect(service.isEntitledTo(SubscriptionTier.proRider), isTrue);
      expect(service.isExpired, isFalse);
      expect(FeatureGates.isUnlocked(Feature.guardianLiveShare), isFalse);

      // Persisted both ways round
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PlanSubscriptionService.keyTier), equals('proRider'));
      expect(prefs.getInt(PlanSubscriptionService.keyValidUntil), equals(futureExpiry));
      expect(prefs.getString(PlanSubscriptionService.keyPreferredTier), equals('community'));

      final reloaded = PlanSubscriptionService();
      await reloaded.load();
      expect(reloaded.entitledTier, equals(SubscriptionTier.proRider));
      expect(reloaded.currentTier, equals(SubscriptionTier.community));

      // Switching back is free
      expect(await reloaded.selectTier(SubscriptionTier.proRider), isTrue);
      expect(reloaded.currentTier, equals(SubscriptionTier.proRider));
      expect(reloaded.validUntil, equals(futureExpiry));
      expect(FeatureGates.isUnlocked(Feature.guardianLiveShare), isTrue);
    });

    test('server status re-sync keeps a Community preference; a new plan becomes preferred', () async {
      final service = PlanSubscriptionService();
      await service.load();

      final futureExpiry = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch;
      service.applySubscriptionStatus({
        'tier': 'proRider',
        'validUntil': futureExpiry,
        'isActive': true,
        'isExpired': false,
        'daysRemaining': 30,
      });
      expect(service.currentTier, equals(SubscriptionTier.proRider));

      await service.selectTier(SubscriptionTier.community);
      // Same plan reported again (e.g. after resume): the rider's choice sticks.
      service.applySubscriptionStatus({
        'tier': 'proRider',
        'validUntil': futureExpiry,
        'isActive': true,
        'isExpired': false,
        'daysRemaining': 30,
      });
      expect(service.currentTier, equals(SubscriptionTier.community));
      expect(service.entitledTier, equals(SubscriptionTier.proRider));

      // An upgrade paid for on the server becomes the plan in use.
      service.applySubscriptionStatus({
        'tier': 'roadCaptain',
        'validUntil': futureExpiry + 1000,
        'isActive': true,
        'isExpired': false,
        'daysRemaining': 30,
      });
      expect(service.entitledTier, equals(SubscriptionTier.roadCaptain));
      expect(service.preferredTier, equals(SubscriptionTier.roadCaptain));
      expect(service.currentTier, equals(SubscriptionTier.roadCaptain));
      expect(service.maxConvoyMembers, equals(40));
    });

    test('expiry rolls the effective tier to Community but leaves the preference alone', () async {
      final service = PlanSubscriptionService();
      await service.load();

      final soon = DateTime.now().add(const Duration(milliseconds: 60)).millisecondsSinceEpoch;
      service.applyServerSubscription('roadCaptain', soon);
      expect(service.currentTier, equals(SubscriptionTier.roadCaptain));
      expect(service.checkExpiry(), isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(service.checkExpiry(), isTrue);
      expect(service.currentTier, equals(SubscriptionTier.community));
      expect(service.entitledTier, equals(SubscriptionTier.community));
      expect(service.validUntil, equals(0));
      expect(service.preferredTier, equals(SubscriptionTier.roadCaptain));
      expect(service.isExpired, isTrue);
      expect(service.previousTier, equals(SubscriptionTier.roadCaptain));
      expect(service.renewTier, equals(SubscriptionTier.roadCaptain));
      expect(FeatureGates.activeTier, equals(SubscriptionTier.community));

      // Paid again: the preference is still the paid tier, so it is in use right away.
      final renewed = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch;
      service.applyServerSubscription('roadCaptain', renewed);
      expect(service.currentTier, equals(SubscriptionTier.roadCaptain));
      expect(service.isExpired, isFalse);
    });

    test('SUBSCRIPTION_EXPIRED event re-applies the entitlement only', () async {
      final service = PlanSubscriptionService();
      await service.load();

      final futureExpiry = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch;
      service.applyServerSubscription('proRider', futureExpiry);
      service.handleExpiredEvent({'previousTier': 'proRider', 'expiredAt': futureExpiry});

      expect(service.currentTier, equals(SubscriptionTier.community));
      expect(service.entitledTier, equals(SubscriptionTier.community));
      expect(service.preferredTier, equals(SubscriptionTier.proRider));
      expect(service.expiredNotice?.previousTier, equals(SubscriptionTier.proRider));
      expect(await service.selectTier(SubscriptionTier.proRider), isFalse);
    });

    test('applyServerSubscription persists and unlocks entitlements from gateway push', () async {
      final service = PlanSubscriptionService();
      await service.load();

      final futureExpiry = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch;
      service.applyServerSubscription('roadCaptain', futureExpiry);

      expect(service.currentTier, equals(SubscriptionTier.roadCaptain));
      expect(service.validUntil, equals(futureExpiry));
      expect(service.isUnlocked(Feature.priorityIntercomDucking), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PlanSubscriptionService.keyTier), equals('roadCaptain'));
      expect(prefs.getInt(PlanSubscriptionService.keyValidUntil), equals(futureExpiry));
    });

    test('allPlans metadata covers Community, Pro, Road Captain, and Tour Operator', () {
      final plans = PlanSubscriptionService.allPlans;
      expect(plans.length, equals(4));

      final community = plans.firstWhere((p) => p.tier == SubscriptionTier.community);
      expect(community.maxConvoySize, equals(4));
      expect(community.monthlyPrice, contains('Free'));

      final pro = plans.firstWhere((p) => p.tier == SubscriptionTier.proRider);
      expect(pro.maxConvoySize, equals(4));
      expect(pro.monthlyPrice, contains('₹149'));

      final captain = plans.firstWhere((p) => p.tier == SubscriptionTier.roadCaptain);
      expect(captain.maxConvoySize, equals(40));
      expect(captain.monthlyPrice, contains('₹599'));
      expect(captain.isPopular, isTrue);

      final operator = plans.firstWhere((p) => p.tier == SubscriptionTier.tourOperator);
      expect(operator.maxConvoySize, equals(100));
      expect(operator.monthlyPrice, contains('₹1,999'));
    });

    test('applyConfiguredPlans dynamically updates plan pricing in allPlans and plans', () {
      final service = PlanSubscriptionService();
      addTearDown(() => PlanSubscriptionService.setConfiguredPlans(null));

      var notified = false;
      service.addListener(() => notified = true);

      service.applyConfiguredPlans({
        'proRider': {'monthly': 50, 'annual': 1199, 'label': 'CoRoute Pro'},
        'roadCaptain': {'monthly': 499, 'annual': 3999, 'label': 'Road Captain Pass'},
      });

      expect(notified, isTrue);
      final pro = service.plans.firstWhere((p) => p.tier == SubscriptionTier.proRider);
      expect(pro.monthlyPrice, equals('₹50 / mo'));
      expect(pro.annualPrice, equals('₹1,199 / yr'));

      final captain = service.plans.firstWhere((p) => p.tier == SubscriptionTier.roadCaptain);
      expect(captain.monthlyPrice, equals('₹499 / mo'));
      expect(captain.annualPrice, equals('₹3,999 / yr'));
    });
  });
}
