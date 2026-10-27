import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/services/plan_subscription_service.dart';

void main() {
  setUp(() {
    FeatureGates.forceAllUnlocked = false;
    FeatureGates.activeTier = SubscriptionTier.community;
  });

  group('Strict Plan Entitlements & Feature Gates Verification', () {
    test('Default mode has forceAllUnlocked set to false', () {
      expect(FeatureGates.forceAllUnlocked, isFalse);
    });

    test('Community tier (Free) strictly gates entitlements', () {
      const tier = SubscriptionTier.community;
      expect(FeatureGates.maxConvoyMembers(tier), equals(4));

      // Locked features
      expect(FeatureGates.isUnlocked(Feature.guardianLiveShare, tier), isFalse);
      expect(FeatureGates.isUnlocked(Feature.multiBikeGarage, tier), isFalse);
      expect(FeatureGates.isUnlocked(Feature.advancedTelemetryReplay, tier), isFalse);
      expect(FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks, tier), isFalse);
      expect(FeatureGates.isUnlocked(Feature.sunlightHudMode, tier), isFalse);
      expect(FeatureGates.isUnlocked(Feature.priorityIntercomDucking, tier), isFalse);
      expect(FeatureGates.isUnlocked(Feature.dynamicWaypointPush, tier), isFalse);
      expect(FeatureGates.isUnlocked(Feature.totalConvoySpreadAlert, tier), isFalse);
      expect(FeatureGates.isUnlocked(Feature.fleetAnalytics, tier), isFalse);
    });

    test('Pro Rider tier unlocks solo/pro perks but locks captain features', () {
      const tier = SubscriptionTier.proRider;
      expect(FeatureGates.maxConvoyMembers(tier), equals(4));

      // Unlocked
      expect(FeatureGates.isUnlocked(Feature.guardianLiveShare, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.multiBikeGarage, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.advancedTelemetryReplay, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.sunlightHudMode, tier), isTrue);

      // Locked
      expect(FeatureGates.isUnlocked(Feature.priorityIntercomDucking, tier), isFalse);
      expect(FeatureGates.isUnlocked(Feature.dynamicWaypointPush, tier), isFalse);
      expect(FeatureGates.isUnlocked(Feature.totalConvoySpreadAlert, tier), isFalse);
      expect(FeatureGates.isUnlocked(Feature.fleetAnalytics, tier), isFalse);
    });

    test('Road Captain tier unlocks up to 40 riders and convoy management', () {
      const tier = SubscriptionTier.roadCaptain;
      expect(FeatureGates.maxConvoyMembers(tier), equals(40));

      // Unlocked Pro perks
      expect(FeatureGates.isUnlocked(Feature.guardianLiveShare, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.multiBikeGarage, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.advancedTelemetryReplay, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.sunlightHudMode, tier), isTrue);

      // Unlocked Captain perks
      expect(FeatureGates.isUnlocked(Feature.priorityIntercomDucking, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.dynamicWaypointPush, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.totalConvoySpreadAlert, tier), isTrue);

      // Locked B2B Fleet perks
      expect(FeatureGates.isUnlocked(Feature.fleetAnalytics, tier), isFalse);
    });

    test('Tour Operator tier unlocks 100+ riders and Fleet Analytics', () {
      const tier = SubscriptionTier.tourOperator;
      expect(FeatureGates.maxConvoyMembers(tier), equals(100));

      expect(FeatureGates.isUnlocked(Feature.guardianLiveShare, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.multiBikeGarage, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.advancedTelemetryReplay, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.sunlightHudMode, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.priorityIntercomDucking, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.dynamicWaypointPush, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.totalConvoySpreadAlert, tier), isTrue);
      expect(FeatureGates.isUnlocked(Feature.fleetAnalytics, tier), isTrue);
    });

    test('PlanSubscriptionService switching tiers immediately updates FeatureGates', () async {
      final service = PlanSubscriptionService();
      expect(service.currentTier, equals(SubscriptionTier.community));
      expect(FeatureGates.activeTier, equals(SubscriptionTier.community));

      final future = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch;

      // Switch to Pro Rider (server-confirmed entitlement)
      service.applyServerSubscription('proRider', future);
      expect(service.currentTier, equals(SubscriptionTier.proRider));
      expect(FeatureGates.activeTier, equals(SubscriptionTier.proRider));
      expect(FeatureGates.isUnlocked(Feature.guardianLiveShare), isTrue);
      expect(FeatureGates.isUnlocked(Feature.priorityIntercomDucking), isFalse);

      // Switch to Road Captain (server-confirmed entitlement)
      service.applyServerSubscription('roadCaptain', future);
      expect(service.currentTier, equals(SubscriptionTier.roadCaptain));
      expect(FeatureGates.activeTier, equals(SubscriptionTier.roadCaptain));
      expect(FeatureGates.isUnlocked(Feature.priorityIntercomDucking), isTrue);
      expect(FeatureGates.maxConvoyMembers(), equals(40));

      // Switch back to Community: a free local preference, the pass is kept
      expect(await service.selectTier(SubscriptionTier.community), isTrue);
      expect(service.currentTier, equals(SubscriptionTier.community));
      expect(service.entitledTier, equals(SubscriptionTier.roadCaptain));
      expect(FeatureGates.activeTier, equals(SubscriptionTier.community));
      expect(FeatureGates.isUnlocked(Feature.guardianLiveShare), isFalse);
      expect(FeatureGates.maxConvoyMembers(), equals(4));
    });

    test('PlanDetails allPlans contains proper max convoy sizes', () {
      final plans = PlanSubscriptionService.allPlans;
      final community = plans.firstWhere((p) => p.tier == SubscriptionTier.community);
      final pro = plans.firstWhere((p) => p.tier == SubscriptionTier.proRider);
      final captain = plans.firstWhere((p) => p.tier == SubscriptionTier.roadCaptain);
      final tour = plans.firstWhere((p) => p.tier == SubscriptionTier.tourOperator);

      expect(community.maxConvoySize, equals(4));
      expect(pro.maxConvoySize, equals(4));
      expect(captain.maxConvoySize, equals(40));
      expect(tour.maxConvoySize, equals(100));
    });
  });
}
