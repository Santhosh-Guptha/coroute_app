import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/membership_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/membership_service.dart';
import 'package:coroute_app/presentation/subscription/membership_dashboard_screen.dart';

class FakeMembershipService extends MembershipService {
  MyMembershipOverview? fakeOverview;
  MembershipCatalog? fakeCatalog;
  bool activateFreeCalled = false;
  String? lastActivatedCategory;
  String? lastActivatedCoupon;

  FakeMembershipService(super.api);

  @override
  MyMembershipOverview? get myOverview => fakeOverview;

  @override
  MembershipCatalog? get catalog => fakeCatalog;

  @override
  UserMembership? get ownedMembership => fakeOverview?.ownedMembership;

  @override
  List<UserMembership> get participating => fakeOverview?.participating ?? const [];

  @override
  ActiveTripLock? get activeTrip => fakeOverview?.activeTrip;

  @override
  Future<MembershipCatalog?> fetchCatalog() async => fakeCatalog;

  @override
  Future<MyMembershipOverview?> fetchMyMembership() async => fakeOverview;

  @override
  Future<UserMembership?> activateFreeMembership({
    required String categoryId,
    required String couponCode,
  }) async {
    activateFreeCalled = true;
    lastActivatedCategory = categoryId;
    lastActivatedCoupon = couponCode;
    return fakeOverview?.ownedMembership;
  }
}

class FakeApiClient extends ApiClient {
  final List<String> calledEndpoints = [];
  final List<dynamic> calledBodies = [];
  dynamic mockResponse;

  @override
  Future<dynamic> post(
    String path, [
    Object? body,
    Duration timeout = const Duration(seconds: 12),
    bool auth = true,
  ]) async {
    calledEndpoints.add(path);
    calledBodies.add(body);
    return mockResponse;
  }

  @override
  Future<dynamic> get(
    String path, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    calledEndpoints.add(path);
    return mockResponse;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeApiClient mockApi;
  late AuthService auth;
  late FakeMembershipService membershipService;

  final testCatalog = MembershipCatalog(
    categories: const [
      MembershipCategory(
        id: 'community',
        name: 'Community',
        priceRupees: 0,
        capacity: 1,
        purchasable: false,
        description: 'Free for every rider: solo rides with every safety feature.',
        features: ['Solo Ride Tracking', 'Essential Safety & Crash SOS'],
      ),
      MembershipCategory(
        id: 'group_small',
        name: 'Group Membership (2–6)',
        priceRupees: 49,
        capacity: 6,
        description: 'Convoy tracking and PTT intercom for your riding crew.',
        features: ['Convoy & Group Tracking', 'PTT Voice Intercom'],
      ),
      MembershipCategory(
        id: 'group_large',
        name: 'Extended Group (7–12)',
        priceRupees: 99,
        capacity: 12,
        description: 'Large motorcycle fleet coordination.',
        features: ['Large Fleet Matrix', '12 Covered Seats'],
      ),
    ],
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    mockApi = FakeApiClient();
    auth = AuthService(mockApi);
    membershipService = FakeMembershipService(mockApi);
    membershipService.fakeCatalog = testCatalog;
  });

  Widget buildTestHost(Widget child) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider<MembershipService>.value(value: membershipService),
      ],
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: child,
      ),
    );
  }

  group('ISSUE-4 Membership Dashboard Screen UI States', () {
    testWidgets('State 1: Active Group Membership shows details, seat count, invitations and collapsed upgrade section', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final now = DateTime.now().millisecondsSinceEpoch;
      final validUntil = now + (30 * 86400000); // 30 days in future

      membershipService.fakeOverview = MyMembershipOverview(
        ownedMembership: UserMembership(
          membershipId: 'mem_group_active',
          ownerUserId: 'user_001',
          category: 'group_small',
          categoryName: 'Group Membership (2–6)',
          capacity: 6,
          priceRupees: 49,
          status: 'ACTIVE',
          validUntil: validUntil,
          members: [
            MembershipMember(
              userId: 'rider_2',
              name: 'Arjun Rider',
              email: 'arjun@coroute.app',
              status: 'ACCEPTED',
              invitedAt: now,
            ),
            MembershipMember(
              userId: 'rider_3',
              name: 'Priya Rider',
              email: 'priya@coroute.app',
              status: 'ACCEPTED',
              invitedAt: now,
            ),
          ],
        ),
      );

      await tester.pumpWidget(buildTestHost(const MembershipDashboardScreen()));
      await tester.pumpAndSettle();

      // 1. Verify Active Membership Badge & Details
      expect(find.text('ACTIVE MEMBERSHIP'), findsOneWidget);
      expect(find.text('Group Membership (6 Riders Capacity)'), findsOneWidget);
      expect(find.text('Owner: You (Permanent & Non-transferable)'), findsOneWidget);
      expect(find.textContaining('Valid until:'), findsOneWidget);
      expect(find.text('₹49 / month'), findsOneWidget);
      expect(find.text('Seat Count: 3 / 6 seats'), findsOneWidget);

      // 2. Verify Seat Capacity Card & Member List Controls
      expect(find.text('Group Seat Capacity'), findsOneWidget);
      expect(find.text('3 / 6 Seats'), findsOneWidget);
      expect(find.text('Group Participants'), findsOneWidget);
      expect(find.text('Arjun Rider'), findsOneWidget);
      expect(find.text('Priya Rider'), findsOneWidget);
      expect(find.text('Invite'), findsOneWidget);

      // 3. Verify initial purchase selection cards & prompts are NOT unconditionally rendered
      // 'Select & Pay' should NOT be visible when section is collapsed
      expect(find.text('Select & Pay ₹49'), findsNothing);
      expect(find.text('Select & Pay ₹9'), findsNothing);
      expect(find.text('Select & Pay ₹99'), findsNothing);

      // 4. Verify explicit secondary expandable section ('Upgrade Capacity or Switch Plan') is present
      final expansionTileFinder = find.byKey(const Key('upgrade_capacity_expansion_tile'));
      expect(expansionTileFinder, findsOneWidget);
      expect(find.text('Change plan or seats'), findsOneWidget);

      // 5. Expand section and verify upgrade / switch options become available
      await tester.tap(expansionTileFinder);
      await tester.pumpAndSettle();

      // After expanding, options appear
      expect(find.text('Current Active Plan (Tap to Extend)'), findsOneWidget);
      expect(find.byKey(const Key('membership_community_card')), findsOneWidget);
      expect(find.textContaining('₹9)'), findsNothing, reason: 'the retired ₹9 Individual plan is not offered');
      expect(find.text('Upgrade to Extended Group (7–12) (₹99)'), findsOneWidget);
    });

    testWidgets('State 2: Active Solo Membership shows solo details and capacity', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final now = DateTime.now().millisecondsSinceEpoch;
      final validUntil = now + (20 * 86400000);

      membershipService.fakeOverview = MyMembershipOverview(
        ownedMembership: UserMembership(
          membershipId: 'mem_solo_active',
          ownerUserId: 'user_001',
          category: 'individual',
          categoryName: 'Individual Solo Rider',
          capacity: 1,
          priceRupees: 9,
          status: 'ACTIVE',
          validUntil: validUntil,
          members: const [],
        ),
      );

      await tester.pumpWidget(buildTestHost(const MembershipDashboardScreen()));
      await tester.pumpAndSettle();

      // Verify Solo Active Card
      expect(find.text('ACTIVE MEMBERSHIP'), findsOneWidget);
      expect(find.text('Individual Solo Membership'), findsOneWidget);
      expect(find.text('₹9 / month'), findsOneWidget);
      expect(find.text('Seat Count: 1 / 1 seat'), findsOneWidget);

      // Verify Seat Capacity & Rider Invitations cards
      expect(find.text('Seat Capacity'), findsOneWidget);
      expect(find.text('1 / 1 Seat'), findsOneWidget);
      expect(find.text('Rider Invitations'), findsOneWidget);

      // Verify no unconditional payment buttons
      expect(find.text('Select & Pay ₹9'), findsNothing);

      // Verify expandable upgrade section
      expect(find.text('Change plan or seats'), findsOneWidget);
    });

    testWidgets('State 3: Expired Membership prominently displays renewal options and catalog', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final now = DateTime.now().millisecondsSinceEpoch;
      final expiredUntil = now - (5 * 86400000); // Expired 5 days ago

      membershipService.fakeOverview = MyMembershipOverview(
        ownedMembership: UserMembership(
          membershipId: 'mem_expired',
          ownerUserId: 'user_001',
          category: 'group_small',
          categoryName: 'Group Membership (2–6)',
          capacity: 6,
          priceRupees: 49,
          status: 'EXPIRED',
          validUntil: expiredUntil,
          members: const [],
        ),
      );

      await tester.pumpWidget(buildTestHost(const MembershipDashboardScreen()));
      await tester.pumpAndSettle();

      // 1. Verify EXPIRED badge and reactivation button on card
      expect(find.text('EXPIRED'), findsOneWidget);
      expect(find.text('Reactivate Plan'), findsOneWidget);

      // 2. Verify Prominent Renewal Banner
      expect(find.text('Membership Expired'), findsOneWidget);
      expect(find.text('Renew Current Plan (₹49 / mo)'), findsOneWidget);

      // 3. Verify prominent renewal catalog section
      expect(find.text('Renew or Switch Plan'), findsOneWidget);
      expect(find.text('Renew Current Plan (₹49)'), findsOneWidget);
      expect(find.byKey(const Key('membership_community_card')), findsOneWidget);
    });

    testWidgets('State 4: No Membership displays catalog selection cards with Select & Pay', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      membershipService.fakeOverview = const MyMembershipOverview(
        ownedMembership: null,
        participating: [],
      );

      await tester.pumpWidget(buildTestHost(const MembershipDashboardScreen()));
      await tester.pumpAndSettle();

      // 1. Verify NO active card or seat cards
      expect(find.text('ACTIVE MEMBERSHIP'), findsNothing);
      expect(find.text('EXPIRED'), findsNothing);
      expect(find.text('Group Seat Capacity'), findsNothing);

      // 2. Verify Catalog selection cards with Select & Pay
      expect(find.text('Select Membership Plan'), findsOneWidget);
      // Community is free (no button); the paid plans are bought.
      expect(find.byKey(const Key('membership_community_card')), findsOneWidget);
      expect(find.text('Your plan · solo rides'), findsOneWidget);
      expect(find.text('Select & Pay ₹9'), findsNothing);
      expect(find.text('Select & Pay ₹49'), findsOneWidget);
      expect(find.text('Select & Pay ₹99'), findsOneWidget);
    });

    testWidgets('State 5: Zero-amount activation directly authorizes on backend without gateway', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      mockApi.mockResponse = {
        'ok': true,
        'membership': {
          'membershipId': 'mem_free_123',
          'ownerUserId': 'user_001',
          'category': 'individual',
          'capacity': 1,
          'priceRupees': 9,
          'status': 'ACTIVE',
          'validUntil': now + 86400000,
          'members': [],
          'offerApplied': 'RIDERFREE',
        },
      };

      final realService = MembershipService(mockApi);
      final mem = await realService.activateFreeMembership(
        categoryId: 'individual',
        couponCode: 'RIDERFREE',
      );

      // Verify backend was called at dedicated /membership/activate-free endpoint
      expect(mockApi.calledEndpoints, contains('/membership/activate-free'));
      final freeCallIndex = mockApi.calledEndpoints.indexOf('/membership/activate-free');
      expect(mockApi.calledBodies[freeCallIndex], {
        'category': 'individual',
        'couponCode': 'RIDERFREE',
      });
      // Verify Razorpay order endpoint was NOT invoked
      expect(mockApi.calledEndpoints, isNot(contains('/membership/order')));
      expect(mem, isNotNull);
      expect(mem?.status, 'ACTIVE');
      expect(mem?.offerApplied, 'RIDERFREE');
    });
  });
}
