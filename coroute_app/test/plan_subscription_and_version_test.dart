import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/app_version_service.dart';
import 'package:coroute_app/data/services/meta_service.dart';
import 'package:coroute_app/data/services/plan_subscription_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlanSubscriptionService & FeatureGates Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FeatureGates.forceAllUnlocked = true;
      FeatureGates.activeTier = SubscriptionTier.roadCaptain;
    });

    test('PlanDetails specification contains all 4 tiers with accurate limits', () {
      final plans = PlanSubscriptionService.allPlans;
      expect(plans.length, 4);

      final community = plans.firstWhere((p) => p.tier == SubscriptionTier.community);
      expect(community.maxConvoySize, 4);
      expect(community.annualPrice, contains('\$0'));

      final pro = plans.firstWhere((p) => p.tier == SubscriptionTier.proRider);
      expect(pro.maxConvoySize, 4);
      expect(pro.monthlyPrice, contains('\$3.99'));
      expect(pro.annualPrice, contains('\$29.99'));

      final captain = plans.firstWhere((p) => p.tier == SubscriptionTier.roadCaptain);
      expect(captain.maxConvoySize, 30);
      expect(captain.isPopular, isTrue);
      expect(captain.monthlyPrice, contains('\$12.99'));
      expect(captain.annualPrice, contains('\$99.99'));

      final tour = plans.firstWhere((p) => p.tier == SubscriptionTier.tourOperator);
      expect(tour.maxConvoySize, 100);
      expect(tour.monthlyPrice, contains('\$79'));
      expect(tour.annualPrice, contains('\$499'));
    });

    test('FeatureGates: when forceAllUnlocked is true, all features unlock regardless of tier', () {
      FeatureGates.forceAllUnlocked = true;
      for (final tier in SubscriptionTier.values) {
        for (final feature in Feature.values) {
          expect(
            FeatureGates.isUnlocked(feature, tier),
            isTrue,
            reason: 'Feature ${feature.name} must be unlocked when forceAllUnlocked=true for tier ${tier.name}',
          );
        }
      }
      expect(FeatureGates.maxConvoyMembers(), 40);
    });

    test('FeatureGates: strict tier entitlement enforcement when forceAllUnlocked is false', () {
      FeatureGates.forceAllUnlocked = false;

      // 1. Community Rider: strictly limited
      expect(FeatureGates.isUnlocked(Feature.priorityIntercomDucking, SubscriptionTier.community), isFalse);
      expect(FeatureGates.isUnlocked(Feature.unlimitedConvoyCapacity, SubscriptionTier.community), isFalse);
      expect(FeatureGates.isUnlocked(Feature.guardianLiveShare, SubscriptionTier.community), isFalse);
      expect(FeatureGates.isUnlocked(Feature.multiBikeGarage, SubscriptionTier.community), isFalse);
      expect(FeatureGates.maxConvoyMembers(SubscriptionTier.community), 4);

      // 2. Pro Rider: solo features unlocked, fleet captain features locked
      expect(FeatureGates.isUnlocked(Feature.guardianLiveShare, SubscriptionTier.proRider), isTrue);
      expect(FeatureGates.isUnlocked(Feature.multiBikeGarage, SubscriptionTier.proRider), isTrue);
      expect(FeatureGates.isUnlocked(Feature.advancedTelemetryReplay, SubscriptionTier.proRider), isTrue);
      expect(FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks, SubscriptionTier.proRider), isTrue);
      expect(FeatureGates.isUnlocked(Feature.priorityIntercomDucking, SubscriptionTier.proRider), isFalse);
      expect(FeatureGates.isUnlocked(Feature.totalConvoySpreadAlert, SubscriptionTier.proRider), isFalse);
      expect(FeatureGates.maxConvoyMembers(SubscriptionTier.proRider), 15);

      // 3. Road Captain: captain features unlocked
      expect(FeatureGates.isUnlocked(Feature.priorityIntercomDucking, SubscriptionTier.roadCaptain), isTrue);
      expect(FeatureGates.isUnlocked(Feature.unlimitedConvoyCapacity, SubscriptionTier.roadCaptain), isTrue);
      expect(FeatureGates.isUnlocked(Feature.totalConvoySpreadAlert, SubscriptionTier.roadCaptain), isTrue);
      expect(FeatureGates.isUnlocked(Feature.dynamicWaypointPush, SubscriptionTier.roadCaptain), isTrue);
      expect(FeatureGates.maxConvoyMembers(SubscriptionTier.roadCaptain), 40);

      // 4. Tour Operator: enterprise capacity
      expect(FeatureGates.maxConvoyMembers(SubscriptionTier.tourOperator), 100);
    });

    test('PlanSubscriptionService: selects tier, toggles test mode, and persists state', () async {
      final service = PlanSubscriptionService();
      await service.load();

      // Default state
      expect(service.forceAllUnlocked, isFalse);

      // Switch to Community with strict rules
      await service.setForceAllUnlocked(false);
      await service.selectTier(SubscriptionTier.community);

      expect(service.currentTier, SubscriptionTier.community);
      expect(service.forceAllUnlocked, isFalse);
      expect(FeatureGates.activeTier, SubscriptionTier.community);
      expect(FeatureGates.forceAllUnlocked, isFalse);
      expect(FeatureGates.isUnlocked(Feature.priorityIntercomDucking), isFalse);

      // Reloading from storage preserves state
      final reloadedService = PlanSubscriptionService();
      await reloadedService.load();
      expect(reloadedService.currentTier, SubscriptionTier.community);
      expect(reloadedService.forceAllUnlocked, isFalse);
    });
  });

  group('AppVersionService & Force Update Tests', () {
    test('Simulated mandatory update forces isMandatoryUpdateRequired = true', () {
      final apiClient = ApiClient();
      final metaService = MetaService(apiClient);
      final versionService = AppVersionService(metaService);

      expect(versionService.simulateMandatoryUpdate, isFalse);
      expect(versionService.isMandatoryUpdateRequired, isFalse);

      versionService.setSimulateMandatoryUpdate(true);
      expect(versionService.simulateMandatoryUpdate, isTrue);
      expect(versionService.isMandatoryUpdateRequired, isTrue);
      expect(versionService.minRequiredBuild, 100);
      expect(versionService.downloadUrl, AppVersionService.defaultStoreUrl);

      versionService.setSimulateMandatoryUpdate(false);
      expect(versionService.isMandatoryUpdateRequired, isFalse);
      versionService.dispose();
    });
  });
}
