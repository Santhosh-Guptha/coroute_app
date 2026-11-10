import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/membership_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/membership_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/presentation/subscription/membership_dashboard_screen.dart';
import 'package:coroute_app/presentation/trip_planner/trip_planner_screen.dart';
import 'package:coroute_app/presentation/trip_planner/trip_review_sheet.dart';

class _MockApiClient extends ApiClient {
  final List<String> calledEndpoints = [];
  final List<dynamic> calledBodies = [];
  dynamic mockGetResponses;
  dynamic mockPostResponses;
  bool shouldThrowNetworkError = false;

  _MockApiClient() : super();

  @override
  Future<dynamic> get(String path, {Duration timeout = const Duration(seconds: 10)}) async {
    calledEndpoints.add(path);
    if (shouldThrowNetworkError) {
      throw const ApiException(503, 'Network timeout: connection failed');
    }
    if (mockGetResponses is Map && mockGetResponses.containsKey(path)) {
      return mockGetResponses[path];
    }
    if (path == '/membership/catalog') {
      return {
        'categories': {
          'community': {'id': 'community', 'name': 'Community', 'monthlyPriceInr': 0, 'capacity': 1, 'purchasable': false},
          'group_small': {'id': 'group_small', 'name': 'Group Membership (2–6)', 'monthlyPriceInr': 49, 'capacity': 6},
          'group_large': {'id': 'group_large', 'name': 'Extended Group (7–12)', 'monthlyPriceInr': 99, 'capacity': 12},
        },
        'paymentsEnabled': true,
      };
    }
    if (path == '/membership/my') {
      return {
        'owned': null,
        'participating': [],
        'paymentsEnabled': true,
      };
    }
    return {};
  }

  @override
  Future<dynamic> post(String path, [Object? body, Duration timeout = const Duration(seconds: 12), bool auth = true]) async {
    calledEndpoints.add(path);
    calledBodies.add(body);
    if (shouldThrowNetworkError) {
      throw const ApiException(503, 'Network connection unavailable');
    }
    if (mockPostResponses is Map && mockPostResponses.containsKey(path)) {
      return mockPostResponses[path];
    }
    if (path == '/membership/order') {
      return {
        'orderId': 'order_rzp_${DateTime.now().millisecondsSinceEpoch}',
        'keyId': 'rzp_test_dummy',
        'amountInPaise': 900,
        'isFree': false,
      };
    }
    if (path == '/convoys') {
      return {
        'groupId': 'GRP-TEST-100',
        'name': 'Test Weekend Ride',
        'joinCode': 'COR123',
        'createdByUserId': 'lead_user',
        'tripOwnerUserId': 'lead_user',
        'tripHeadUserId': 'lead_user',
        'tripStatus': 'STARTED',
        'createdAtEpochMs': DateTime.now().millisecondsSinceEpoch,
        'members': {},
        'riders': {
          'lead_user': {'userId': 'lead_user', 'name': 'Lead Rider', 'role': 'LEAD'}
        },
      };
    }
    if (path == '/convoys/join') {
      return {
        'groupId': 'GRP-TEST-100',
        'name': 'Test Weekend Ride',
        'joinCode': 'COR123',
        'createdByUserId': 'lead_user',
        'tripOwnerUserId': 'lead_user',
        'tripStatus': 'STARTED',
        'createdAtEpochMs': DateTime.now().millisecondsSinceEpoch,
        'riders': {
          'lead_user': {'userId': 'lead_user', 'name': 'Lead Rider', 'role': 'LEAD'},
          'invited_user': {'userId': 'invited_user', 'name': 'Invited Rider', 'role': 'PACK'},
        },
      };
    }
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockApiClient mockApi;
  late SharedPreferences prefs;

  final now = DateTime.now().millisecondsSinceEpoch;
  final futureTime = now + (30 * 86400000); // 30 days valid
  final pastTime = now - (5 * 86400000);   // 5 days expired

  final individualMembership = UserMembership(
    membershipId: 'mem_solo_1',
    ownerUserId: 'test_user_1',
    category: 'individual',
    categoryName: 'Individual Solo Rider',
    capacity: 1,
    status: 'ACTIVE',
    validUntil: futureTime,
  );

  final smallGroupMembership = UserMembership(
    membershipId: 'mem_group_6',
    ownerUserId: 'test_user_1',
    category: 'group_small',
    categoryName: 'Group Membership (2–6)',
    capacity: 6,
    status: 'ACTIVE',
    validUntil: futureTime,
  );

  final largeGroupMembership = UserMembership(
    membershipId: 'mem_group_12',
    ownerUserId: 'test_user_1',
    category: 'group_large',
    categoryName: 'Extended Group (7–12)',
    capacity: 12,
    status: 'ACTIVE',
    validUntil: futureTime,
  );

  final expiredMembership = UserMembership(
    membershipId: 'mem_expired_1',
    ownerUserId: 'test_user_1',
    category: 'individual',
    categoryName: 'Individual Solo Rider',
    capacity: 1,
    status: 'ENDED',
    validUntil: pastTime,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    mockApi = _MockApiClient();
  });

  Widget buildTestHost({
    required Widget child,
    required MembershipService membershipService,
    AuthService? authService,
    ConvoyService? convoyService,
    SettingsService? settingsService,
  }) {
    AppTheme.use(AppPalette.dark);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<MembershipService>.value(value: membershipService),
        ChangeNotifierProvider<AuthService>.value(
          value: authService ?? AuthService(mockApi),
        ),
        ChangeNotifierProvider<ConvoyService>.value(
          value: convoyService ?? ConvoyService(mockApi, RealtimeService(), TripStorageService(mockApi)),
        ),
        ChangeNotifierProvider<SettingsService>.value(
          value: settingsService ?? SettingsService(),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.themeFor(AppPalette.dark),
        home: Scaffold(body: child),
      ),
    );
  }

  group('ISSUE-10: MembershipService Unit Tests', () {
    test('1. Authoritative entitlement recognition recognizes active plans and capacities', () {
      final ms = MembershipService(mockApi, prefs);

      // Null overview
      expect(ms.hasActivePlan, isFalse);

      // Active Individual: capacity 1 (Solo)
      mockApi.mockGetResponses = {
        '/membership/my': {
          'owned': individualMembership.toJson(),
          'participating': [],
          'paymentsEnabled': true,
        }
      };

      // Set directly in overview to test getters
      final activeSoloOverview = MyMembershipOverview(
        ownedMembership: individualMembership,
        plansEnforced: true,
      );
      expect(activeSoloOverview.hasValidEntitlement, isTrue);
      expect(activeSoloOverview.ownedMembership!.capacity, 1);
      expect(activeSoloOverview.ownedMembership!.isExpired, isFalse);

      // Small Group: capacity 6
      final activeSmallGroupOverview = MyMembershipOverview(
        ownedMembership: smallGroupMembership,
        plansEnforced: true,
      );
      expect(activeSmallGroupOverview.hasValidEntitlement, isTrue);
      expect(activeSmallGroupOverview.ownedMembership!.capacity, 6);

      // Large Group: capacity 12
      final activeLargeGroupOverview = MyMembershipOverview(
        ownedMembership: largeGroupMembership,
        plansEnforced: true,
      );
      expect(activeLargeGroupOverview.hasValidEntitlement, isTrue);
      expect(activeLargeGroupOverview.ownedMembership!.capacity, 12);

      // Expired plan
      final expiredOverview = MyMembershipOverview(
        ownedMembership: expiredMembership,
        plansEnforced: true,
      );
      expect(expiredOverview.hasValidEntitlement, isFalse);
      expect(expiredOverview.ownedMembership!.isExpired, isTrue);
    });

    test('2. Durable offline caching: preserves known active membership across transient network errors', () async {
      // 1. Initial online fetch saves to SharedPreferences
      mockApi.mockGetResponses = {
        '/membership/my': {
          'owned': smallGroupMembership.toJson(),
          'participating': [],
          'paymentsEnabled': true,
        }
      };

      final ms = MembershipService(mockApi, prefs);
      await ms.fetchMyMembership();

      expect(ms.hasActivePlan, isTrue);
      expect(ms.ownedMembership?.category, 'group_small');
      expect(ms.ownedMembership?.capacity, 6);

      // Verify written to SharedPreferences
      final cachedJson = prefs.getString(AppConstants.keyMembershipCache);
      expect(cachedJson, isNotNull);
      final decoded = jsonDecode(cachedJson!);
      expect(decoded['ownedMembership']['category'], 'group_small');

      // 2. Simulate transient network error / offline
      mockApi.shouldThrowNetworkError = true;

      // New service instance simulates app restart in offline mode
      final offlineMs = MembershipService(mockApi, prefs);
      // Explicitly fetch when offline: must NOT classify known membership as expired!
      await offlineMs.fetchMyMembership();

      expect(offlineMs.hasActivePlan, isTrue);
      expect(offlineMs.ownedMembership?.capacity, 6);
      expect(offlineMs.ownedMembership?.isExpired, isFalse);
      expect(offlineMs.lastError, contains('Network timeout'));
    });
  });

  group('ISSUE-10: Trip Creation Membership Gating Widget Tests', () {
    testWidgets('4. Active Individual Membership allows direct trip creation without payment sheet', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ms = MembershipService(mockApi, prefs);
      mockApi.mockGetResponses = {
        '/membership/my': {
          'owned': individualMembership.toJson(),
          'participating': [],
          'paymentsEnabled': true,
        }
      };
      await ms.fetchMyMembership();

      await tester.pumpWidget(buildTestHost(
        child: const TripPlannerScreen(),
        membershipService: ms,
      ));
      await tester.pumpAndSettle();

      // Enter a valid trip name
      await tester.enterText(find.byType(TextField).first, 'Solo Morning Commute');
      await tester.pumpAndSettle();

      // Tap Review button
      final reviewButton = find.text('Review');
      expect(reviewButton, findsOneWidget);
      await tester.tap(reviewButton);
      await tester.pumpAndSettle();

      expect(find.text('Membership Required'), findsNothing);

      // Verify TripReviewSheet is shown directly!
      expect(find.byType(TripReviewSheet), findsOneWidget);
      expect(find.text('Solo Morning Commute'), findsWidgets);
    });

    testWidgets('5. Active Small Group membership allows direct trip creation without payment prompt', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ms = MembershipService(mockApi, prefs);
      mockApi.mockGetResponses = {
        '/membership/my': {
          'owned': smallGroupMembership.toJson(),
          'participating': [],
          'paymentsEnabled': true,
        }
      };
      await ms.fetchMyMembership();

      await tester.pumpWidget(buildTestHost(
        child: const TripPlannerScreen(),
        membershipService: ms,
      ));
      await tester.pumpAndSettle();

      // Enter trip name
      await tester.enterText(find.byType(TextField).first, 'Weekend Ghats Group Ride');
      await tester.pumpAndSettle();

      // Tap Review
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();

      // No payment sheet
      expect(find.text('Membership Required'), findsNothing);

      // Direct review sheet
      expect(find.byType(TripReviewSheet), findsOneWidget);
      expect(find.text('Weekend Ghats Group Ride'), findsWidgets);
    });

    testWidgets('6. Active Large Group membership allows direct trip creation without payment prompt', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ms = MembershipService(mockApi, prefs);
      mockApi.mockGetResponses = {
        '/membership/my': {
          'owned': largeGroupMembership.toJson(),
          'participating': [],
          'paymentsEnabled': true,
        }
      };
      await ms.fetchMyMembership();

      await tester.pumpWidget(buildTestHost(
        child: const TripPlannerScreen(),
        membershipService: ms,
      ));
      await tester.pumpAndSettle();

      // Enter trip name
      await tester.enterText(find.byType(TextField).first, 'Mega Fleet Convoy');
      await tester.pumpAndSettle();

      // Tap Review
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();

      // No payment sheet
      expect(find.text('Membership Required'), findsNothing);

      // Direct review sheet
      expect(find.byType(TripReviewSheet), findsOneWidget);
      expect(find.text('Mega Fleet Convoy'), findsWidgets);
    });

    testWidgets('7. Offline mode with cached active membership allows direct trip creation without payment prompt', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // Seed local SharedPreferences cache
      final cachedOverview = MyMembershipOverview(
        ownedMembership: smallGroupMembership,
        plansEnforced: true,
      );
      await prefs.setString(AppConstants.keyMembershipCache, jsonEncode(cachedOverview.toJson()));

      // Mock API is offline
      mockApi.shouldThrowNetworkError = true;

      final ms = MembershipService(mockApi, prefs);

      await tester.pumpWidget(buildTestHost(
        child: const TripPlannerScreen(),
        membershipService: ms,
      ));
      await tester.pumpAndSettle();

      // Enter trip name
      await tester.enterText(find.byType(TextField).first, 'Offline Trail Trip');
      await tester.pumpAndSettle();

      // Tap Review
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();

      // Verify: Even with offline backend, cached entitlement allows trip creation directly!
      expect(find.text('Membership Required'), findsNothing);
      expect(find.byType(TripReviewSheet), findsOneWidget);
    });

    testWidgets('8. Expired membership: the rider is on Community and starts a solo ride, no payment asked', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ms = MembershipService(mockApi, prefs);
      mockApi.mockGetResponses = {
        '/membership/my': {
          'owned': expiredMembership.toJson(),
          'participating': [],
          'paymentsEnabled': true,
        }
      };
      await ms.fetchMyMembership();

      await tester.pumpWidget(buildTestHost(
        child: const TripPlannerScreen(),
        membershipService: ms,
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'Expired Plan Trip');
      await tester.pumpAndSettle();

      // Tap Review
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();

      // Community is free: no payment prompt, straight to the trip review.
      expect(find.text('Membership Required'), findsNothing);
      expect(find.byType(TripReviewSheet), findsOneWidget);
    });

    testWidgets('9. No membership: Community starts a solo ride, no payment asked', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ms = MembershipService(mockApi, prefs);
      mockApi.mockGetResponses = {
        '/membership/my': {
          'owned': null,
          'participating': [],
          'paymentsEnabled': true,
        }
      };
      await ms.fetchMyMembership();

      await tester.pumpWidget(buildTestHost(
        child: const TripPlannerScreen(),
        membershipService: ms,
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'New Rider Trip');
      await tester.pumpAndSettle();

      // Tap Review
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();

      // Every rider has Community (free, solo rides): no payment prompt.
      expect(find.text('Membership Required'), findsNothing);
      expect(find.byType(TripReviewSheet), findsOneWidget);
    });
  });

  group('ISSUE-10: MembershipDashboardScreen Verification & Upgrade Accordion', () {
    testWidgets('10. Clean verification state displayed while checking server entitlement', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final completer = Completer<dynamic>();
      mockApi.mockGetResponses = {
        '/membership/my': completer.future,
      };

      final ms = MembershipService(mockApi, prefs);

      await tester.pumpWidget(buildTestHost(
        child: const MembershipDashboardScreen(),
        membershipService: ms,
      ));
      await tester.pump();

      // When overview is null and ms is loading/verifying:
      // Clean verification state must be visible
      expect(find.byKey(const Key('membership_verification_state')), findsOneWidget);
      expect(find.text('Checking your plan'), findsOneWidget);

      completer.complete({
        'owned': null,
        'participating': [],
        'paymentsEnabled': true,
      });
      await tester.pumpAndSettle();
    });

    testWidgets('11. Active membership shows the read-only plan card, no pricing', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ms = MembershipService(mockApi, prefs);
      mockApi.mockGetResponses = {
        '/membership/my': {
          'owned': individualMembership.toJson(),
          'participating': [],
          'paymentsEnabled': true,
        }
      };
      await ms.fetchMyMembership();

      await tester.pumpWidget(buildTestHost(
        child: const MembershipDashboardScreen(),
        membershipService: ms,
      ));
      await tester.pumpAndSettle();

      // Read-only "Your plan" card (Play payments policy): name, what it includes, end date.
      expect(find.byKey(const Key('your_plan_card')), findsOneWidget);
      expect(find.text('Individual'), findsOneWidget);
      expect(find.text('Solo rides'), findsOneWidget);
      expect(find.textContaining('Ends on '), findsOneWidget);
      expect(find.text('Your plan is managed in your CoRoute account.'), findsOneWidget);
      // No prices, no plan lists, no buying buttons.
      expect(find.textContaining('₹'), findsNothing);
      expect(find.byKey(const Key('upgrade_capacity_expansion_tile')), findsNothing);
      expect(find.textContaining('Upgrade'), findsNothing);
      expect(find.textContaining('Group Membership'), findsNothing);
    });

    testWidgets('12. Expired membership: Community card names the plan that ended, no renewal', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ms = MembershipService(mockApi, prefs);
      mockApi.mockGetResponses = {
        '/membership/my': {
          'owned': expiredMembership.toJson(),
          'participating': [],
          'paymentsEnabled': true,
        }
      };
      await ms.fetchMyMembership();

      await tester.pumpWidget(buildTestHost(
        child: const MembershipDashboardScreen(),
        membershipService: ms,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Community'), findsOneWidget);
      expect(find.textContaining('Your Individual plan ended on '), findsOneWidget);
      expect(find.text('Solo riding and every safety feature are free.'), findsOneWidget);
      expect(find.textContaining('Renew'), findsNothing);
      expect(find.textContaining('₹'), findsNothing);
      expect(find.byType(ElevatedButton), findsNothing);
    });
  });

  group('ISSUE-10: Invited Riders Joining Trips', () {
    test('13. Invited riders join convoy without paying or tier gating', () async {
      final ms = MembershipService(mockApi, prefs);
      final convoyService = ConvoyService(mockApi, RealtimeService(), TripStorageService(mockApi));

      final rider = RiderModel(
        userId: 'invited_user',
        name: 'Invited Rider',
        lat: 17.43,
        lng: 78.37,
        lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
      );

      final joined = await convoyService.joinConvoyByCode(
        code: 'COR123',
        rider: rider,
      );

      expect(joined, isNotNull);
      expect(mockApi.calledEndpoints, contains('/convoys/join'));
      expect(convoyService.activeConvoy?.groupId, 'GRP-TEST-100');
      // Invited rider joins and participates free, without an owned group plan
      expect(ms.planAccess.isPaid, isFalse);
      expect(ms.planAccess.source, 'community');
    });
  });
}
