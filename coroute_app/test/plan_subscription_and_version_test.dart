import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/app_version_service.dart';
import 'package:coroute_app/data/services/meta_service.dart';
import 'package:coroute_app/data/services/plan_subscription_service.dart';

class _TestMetaService extends MetaService {
  _TestMetaService() : super(ApiClient());

  AppMeta? _testMeta;

  void updateMeta(AppMeta? meta) {
    _testMeta = meta;
    notifyListeners();
  }

  @override
  AppMeta? get meta => _testMeta;

  @override
  bool get updateRequired {
    if (MetaService.currentBuild <= 0 || _testMeta == null) return false;
    return _testMeta!.minBuild > MetaService.currentBuild;
  }

  @override
  bool get updateAvailable {
    if (MetaService.currentBuild <= 0 || _testMeta == null) return false;
    return _testMeta!.latestBuild > MetaService.currentBuild;
  }
}

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
    tearDown(() {
      MetaService.currentBuild = 0;
    });

    test('MetaService version metadata drives isMandatoryUpdateRequired accurately', () {
      final metaService = _TestMetaService();
      final versionService = AppVersionService(metaService);

      // Initially no update required
      expect(versionService.isMandatoryUpdateRequired, isFalse);
      expect(versionService.isUpdateAvailable, isFalse);

      // Client build is 100, server requires minBuild 105
      MetaService.currentBuild = 100;
      metaService.updateMeta(const AppMeta(
        minBuild: 105,
        latestBuild: 110,
        downloadUrl: 'https://coroute.space/downloads/latest.apk',
        privacyUrl: '',
        termsUrl: '',
        supportEmail: '',
        googleSignIn: false,
      ));

      expect(versionService.isMandatoryUpdateRequired, isTrue);
      expect(versionService.isUpdateAvailable, isTrue);
      expect(versionService.minRequiredBuild, 105);
      expect(versionService.latestBuild, 110);
      expect(versionService.downloadUrl, 'https://coroute.space/downloads/latest.apk');

      // Client updates to 105: mandatory barrier clears, but optional update available
      MetaService.currentBuild = 105;
      metaService.updateMeta(const AppMeta(
        minBuild: 105,
        latestBuild: 110,
        downloadUrl: 'https://coroute.space/downloads/latest.apk',
        privacyUrl: '',
        termsUrl: '',
        supportEmail: '',
        googleSignIn: false,
      ));

      expect(versionService.isMandatoryUpdateRequired, isFalse);
      expect(versionService.isUpdateAvailable, isTrue);

      // Client is at latest build 110: fully up to date
      MetaService.currentBuild = 110;
      metaService.updateMeta(const AppMeta(
        minBuild: 105,
        latestBuild: 110,
        downloadUrl: '',
        privacyUrl: '',
        termsUrl: '',
        supportEmail: '',
        googleSignIn: false,
      ));

      expect(versionService.isMandatoryUpdateRequired, isFalse);
      expect(versionService.isUpdateAvailable, isFalse);
      expect(versionService.downloadUrl, AppVersionService.defaultStoreUrl);

      versionService.dispose();
    });
  });
}
