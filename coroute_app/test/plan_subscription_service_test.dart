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

    test('selectTier updates current tier and synchronizes with FeatureGates', () async {
      final service = PlanSubscriptionService();
      await service.load();

      await service.selectTier(SubscriptionTier.roadCaptain);

      expect(service.currentTier, equals(SubscriptionTier.roadCaptain));
      expect(service.maxConvoyMembers, equals(40));
      expect(service.isUnlocked(Feature.priorityIntercomDucking), isTrue);
      expect(service.isUnlocked(Feature.roadHazardBroadcast), isTrue);
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
  });
}
