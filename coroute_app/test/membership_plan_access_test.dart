import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/membership_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/membership_service.dart';
import 'package:coroute_app/presentation/subscription/membership_status_chip.dart';

/// The membership plans (Individual, Small Group 2–6, Large Group 7–12) are the single source of
/// what a rider may host; legacy tiers count only until they end; safety is never gated.
class _FakeMembership extends MembershipService {
  _FakeMembership(this._access, {this.payments = true}) : super(ApiClient());
  final PlanAccess _access;
  final bool payments;
  @override
  PlanAccess get planAccess => _access;
  @override
  bool get paymentsEnabled => payments;
  @override
  int? get groupFromPrice => 49;
}

Map<String, dynamic> _rider(String id) => {'userId': id, 'name': 'Rider $id'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 11, 6, 10);
  final dec12 = DateTime(2026, 12, 12, 23).millisecondsSinceEpoch;

  group('home status line', () {
    test('Small Group: seats and end date', () {
      const access = PlanAccess(source: 'membership', category: 'group_small', name: 'Small Group (2–6)', seats: 6);
      final a = PlanAccess(source: access.source, category: access.category, name: access.name, seats: 6, validUntil: dec12);
      expect(a.statusLine(now: now), 'Small Group · up to 6 riders · until 12 Dec');
      expect(a.canHostGroup, isTrue);
    });

    test('Individual: solo trips, no group hosting', () {
      final a = PlanAccess(source: 'membership', category: 'individual', name: 'Individual', seats: 1, validUntil: dec12);
      expect(a.statusLine(now: now), 'Individual · solo trips · until 12 Dec');
      expect(a.canStartTrip, isTrue);
      expect(a.canHostGroup, isFalse);
    });

    test('no plan (unknown, older gateway): join free, host from the cheapest group plan', () {
      expect(PlanAccess.none.statusLine(groupFromPrice: 49), 'No plan · Join rides free · Host a group from ₹49');
      expect(PlanAccess.none.statusLine(), 'No plan · Join rides free · Host a group');
      expect(PlanAccess.none.canStartTrip, isFalse);
    });

    test('Community: free for every rider, solo rides, never ends', () {
      final c = PlanAccess.fromJson({'source': 'community', 'category': 'community', 'name': 'Community', 'seats': 1, 'validUntil': 0, 'isFree': true});
      expect(c.statusLine(groupFromPrice: 49, now: now), 'Community · Solo rides free · Host a group from ₹49');
      expect(c.shortName, 'Community');
      expect([c.canStartTrip, c.canHostGroup, c.isPaid, c.isCommunity], [true, false, false, true]);
      expect(PlanAccess.community.canStartTrip, isTrue);
    });

    test('legacy Road Captain shows its own name until its end date', () {
      final a = PlanAccess.fromJson({
        'source': 'legacy', 'category': 'group_large', 'name': 'Road Captain', 'seats': 12,
        'validUntil': dec12, 'legacyTier': 'roadCaptain',
      });
      expect(a.isLegacy, isTrue);
      expect(a.statusLine(now: now), 'Road Captain · up to 12 riders · until 12 Dec');
    });

    test('an ended plan reads as Community (free, solo rides)', () {
      final a = PlanAccess(source: 'legacy', category: 'group_large', name: 'Road Captain', seats: 12,
          validUntil: DateTime.now().millisecondsSinceEpoch - 1000);
      expect(a.hasPlan, isFalse);
      expect(a.statusLine(groupFromPrice: 49), startsWith('Community'));
      expect(a.current.canStartTrip, isTrue);
      expect(a.current.canHostGroup, isFalse);
    });

    test('an older gateway without `plan` falls back to the owned membership', () {
      final o = MyMembershipOverview.fromJson({
        'owned': {
          'membershipId': 'm1', 'ownerUserId': 'u1', 'category': 'group_large', 'categoryName': 'Large Group (7–12)',
          'capacity': 12, 'priceInr': 99, 'status': 'ACTIVE', 'validUntil': DateTime.now().millisecondsSinceEpoch + 86400000,
        },
      });
      expect(o.planAccess.seats, 12);
      expect(o.planAccess.canHostGroup, isTrue);
      // Without any plan: Community (every rider can start a solo ride).
      expect(MyMembershipOverview.fromJson(const {}).planAccess.source, 'community');
      expect(MyMembershipOverview.fromJson(const {}).planAccess.canStartTrip, isTrue);
    });
  });

  group('ride capacity comes from the host membership', () {
    test('count over seats from the snapshot (was 1/100 from a global cap)', () {
      final c = ConvoyModel.fromJson({
        'groupId': 'GRP-1', 'name': 'Six pack', 'joinCode': '123456', 'createdByUserId': 'h', 'createdByUserName': 'Host',
        'tripStatus': 'STARTED', 'createdAtEpochMs': 1, 'capacity': 6, 'riders': {'h': _rider('h')},
      });
      expect(c.capacity, 6);
      expect(c.riderCountLabel, '1/6');
      expect(c.isFull, isFalse);
      final full = ConvoyModel.fromJson({
        'groupId': 'GRP-2', 'name': 'Full', 'joinCode': '123457', 'createdByUserId': 'h', 'createdByUserName': 'Host',
        'tripStatus': 'STARTED', 'createdAtEpochMs': 1, 'capacity': 2, 'riders': {'h': _rider('h'), 'r': _rider('r')},
      });
      expect(full.riderCountLabel, '2/2');
      expect(full.isFull, isTrue);
      // An upgrade during the ride (CONFIG capacity) raises the seats.
      expect(full.copyWith(capacity: 12).riderCountLabel, '2/12');
    });

    test('unknown seats (older gateway): only the count, never a made-up cap', () {
      final c = ConvoyModel.fromJson({
        'groupId': 'GRP-3', 'name': 'Old', 'joinCode': '123458', 'createdByUserId': 'h', 'createdByUserName': 'Host',
        'tripStatus': 'STARTED', 'createdAtEpochMs': 1, 'riders': {'h': _rider('h')},
      });
      expect(c.riderCountLabel, '1');
      expect(c.isFull, isFalse);
      expect(c.toJson().containsKey('capacity'), isFalse);
    });
  });

  group('gating map', () {
    test('safety features are never gated; no feature is sold on its own', () {
      for (final f in Feature.values) {
        expect(FeatureGates.isUnlocked(f), isTrue, reason: f.name);
      }
      for (final f in [Feature.guardianLiveShare, Feature.sirenAcousticDetector, Feature.biometricTraumaPulse, Feature.satelliteSosRelay, Feature.smartAirbagVest]) {
        expect(FeatureGates.accessOf(f), FeatureAccess.safety, reason: f.name);
      }
      expect(FeatureGates.accessOf(Feature.priorityIntercomDucking), FeatureAccess.groupRide);
      expect(FeatureGates.accessOf(Feature.multiBikeGarage), FeatureAccess.personal);
    });
  });

  group('home status chip', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> pump(WidgetTester tester, MembershipService ms) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider<MembershipService?>.value(value: ms, child: const MembershipStatusChip()),
          ),
        ));

    testWidgets('shows the membership, not a tier badge', (tester) async {
      final until = DateTime.now().add(const Duration(days: 20)).millisecondsSinceEpoch;
      final access = PlanAccess(source: 'membership', category: 'group_small', name: 'Small Group (2–6)', seats: 6, validUntil: until);
      await pump(tester, _FakeMembership(access));
      expect(find.text('Small Group · up to 6 riders · until ${PlanAccess.untilLabel(until)}'), findsOneWidget);
      expect(find.textContaining('COMMUNITY'), findsNothing);
      expect(find.textContaining('Convoy limit'), findsNothing);
    });

    testWidgets('no plan: join free, host from ₹49', (tester) async {
      await pump(tester, _FakeMembership(PlanAccess.none));
      expect(find.text('No plan · Join rides free · Host a group from ₹49'), findsOneWidget);
    });

    testWidgets('hidden when payments are off', (tester) async {
      await pump(tester, _FakeMembership(PlanAccess.none, payments: false));
      expect(find.byKey(const Key('home_membership_status')), findsNothing);
    });
  });
}
