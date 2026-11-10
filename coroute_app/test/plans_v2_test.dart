import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/membership_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/membership_service.dart';

/// Plans v2 on the phone: Community is free (solo rides) and the group features follow the ride's
/// host plan. The app reads no price (Play payments policy).
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

  group('catalog and plan', () {
    test('Community is listed but is not a group plan; the group plans are, fewest riders first; no price is read', () {
      final cat = MembershipCatalog.fromJson({
        'categories': {
          'group_large': {'name': 'Large Group', 'monthlyPriceInr': 99, 'capacity': 12},
          'community': {'name': 'Community', 'monthlyPriceInr': 0, 'capacity': 1, 'purchasable': false},
          'individual': {'name': 'Individual', 'monthlyPriceInr': 9, 'capacity': 1},
          'group_small': {'name': 'Small Group', 'monthlyPriceInr': 49, 'capacity': 6},
        },
      });
      expect(cat.groupCategories.map((c) => c.id), ['group_small', 'group_large']);
      expect(cat.community!.isGroupPlan, isFalse);
      expect(cat.toJson().toString(), isNot(contains('Price')));
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
