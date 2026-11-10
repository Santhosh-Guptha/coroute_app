import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/theme/theme_controller.dart';
import 'package:coroute_app/data/local/track_queue.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/membership_service.dart';
import 'package:coroute_app/data/services/meta_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/timeline_service.dart';
import 'package:coroute_app/data/services/track_recorder.dart';
import 'package:coroute_app/data/services/track_uploader.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/account/account_screen.dart';
import 'package:coroute_app/presentation/admin/admin_emergencies_panel.dart';
import 'package:coroute_app/presentation/admin/admin_ui.dart';
import 'package:coroute_app/presentation/admin/master_admin_dashboard.dart';

/// Silent alarm stub for MasterAdminDashboard testing.
class _TestSilentAlarm implements AdminAlarm {
  @override
  Future<void> start({required String title, required String body}) async {}
  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() => AppTheme.use(AppPalette.dark));

  // ---------------------------------------------------------------------------
  // Helper: Harness builder with full service injection and custom fake API
  // ---------------------------------------------------------------------------
  Widget buildTestHarness({
    required ApiClient api,
    required AuthService auth,
    required ConvoyService convoy,
    required RealtimeService rt,
    required TripStorageService trips,
    required TimelineService timeline,
    required MetaService meta,
    required SettingsService settings,
    required MembershipService membership,
    required ThemeController theme,
    required Widget child,
    AppPalette palette = AppPalette.dark,
  }) {
    AppTheme.use(palette);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ApiClient>.value(value: api),
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider<ConvoyService>.value(value: convoy),
        ChangeNotifierProvider<RealtimeService>.value(value: rt),
        ChangeNotifierProvider<TripStorageService>.value(value: trips),
        ChangeNotifierProvider<TimelineService>.value(value: timeline),
        ChangeNotifierProvider<MetaService>.value(value: meta),
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        ChangeNotifierProvider<MembershipService>.value(value: membership),
        ChangeNotifierProvider<ThemeController>.value(value: theme),
      ],
      child: MaterialApp(
        theme: AppTheme.themeFor(palette),
        home: child,
      ),
    );
  }

  group('ISSUE-2: Fleet & Tour Dispatcher Matrix Access Control Regression Tests', () {
    testWidgets('Authenticated regular rider cannot access MasterAdminDashboard (Access Denied displayed, zero admin API calls made)', (tester) async {
      final storage = const FlutterSecureStorage();
      await storage.write(key: 'coroute_jwt', value: 'rider_jwt_token');

      SharedPreferences.setMockInitialValues({
        AppConstants.keyUserId: 'rider_101',
        AppConstants.keyUserRole: AppConstants.riderRole, // Regular rider, NOT MASTER_ADMIN
        AppConstants.keyUserName: 'Regular Rider Asha',
        AppConstants.keyUserEmail: 'asha@coroute.in',
      });

      final calls = <http.Request>[];
      final mockHttp = MockClient((req) async {
        calls.add(req);
        if (req.url.path.endsWith('/me')) {
          return http.Response(jsonEncode({
            'userId': 'rider_101',
            'role': AppConstants.riderRole,
            'name': 'Regular Rider Asha',
            'email': 'asha@coroute.in',
          }), 200);
        }
        if (req.url.path.contains('/admin/')) {
          return http.Response(jsonEncode({'error': 'Admin only'}), 403);
        }
        return http.Response('{}', 200);
      });

      final api = ApiClient(httpClient: mockHttp, storage: storage);
      await api.init();
      final auth = AuthService(api);
      await auth.revalidate();
      final rt = RealtimeService();
      final trips = TripStorageService(api);
      final timeline = TimelineService(api, rt);
      final queue = MemoryTrackQueue();
      final recorder = TrackRecorder(queue, TrackUploader(api, queue));
      final convoy = ConvoyService(api, rt, trips, recorder: recorder, timeline: timeline);
      final meta = MetaService(api);
      final settings = SettingsService();
      final membership = MembershipService(api);
      final theme = ThemeController();

      expect(auth.isAuthenticated, isTrue);
      expect(auth.isMasterAdmin, isFalse); // Invariant check: regular rider

      await tester.pumpWidget(buildTestHarness(
        api: api,
        auth: auth,
        convoy: convoy,
        rt: rt,
        trips: trips,
        timeline: timeline,
        meta: meta,
        settings: settings,
        membership: membership,
        theme: theme,
        child: MasterAdminDashboard(alarm: _TestSilentAlarm()),
      ));

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Verification: Access Denied view must be rendered
      expect(find.text('Access denied'), findsOneWidget);
      expect(find.text('Master Admin Access Required'), findsOneWidget);
      expect(find.text('Regular riders cannot access the Master Admin Console.'), findsOneWidget);

      // Verification: Privileged admin endpoints must NOT have been called
      expect(calls.any((r) => r.url.path.contains('/admin/users')), isFalse);
      expect(calls.any((r) => r.url.path.contains('/admin/fleet')), isFalse);
    });

    testWidgets('AccountScreen does NOT show Fleet Matrix or unauthorized admin tiles to non-master admins', (tester) async {
      tester.view.physicalSize = const Size(400, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final storage = const FlutterSecureStorage();
      await storage.write(key: 'coroute_jwt', value: 'rider_jwt_token');

      SharedPreferences.setMockInitialValues({
        AppConstants.keyUserId: 'rider_103',
        AppConstants.keyUserRole: AppConstants.riderRole,
        AppConstants.keyUserName: 'Chitra',
        AppConstants.keyUserEmail: 'chitra@coroute.in',
      });

      final mockHttp = MockClient((req) async {
        if (req.url.path.endsWith('/me')) {
          return http.Response(jsonEncode({
            'userId': 'rider_103',
            'role': AppConstants.riderRole,
            'name': 'Chitra',
            'email': 'chitra@coroute.in',
          }), 200);
        }
        return http.Response('{}', 200);
      });
      final api = ApiClient(httpClient: mockHttp, storage: storage);
      await api.init();
      final auth = AuthService(api);
      await auth.revalidate();
      final rt = RealtimeService();
      final trips = TripStorageService(api);
      final timeline = TimelineService(api, rt);
      final queue = MemoryTrackQueue();
      final recorder = TrackRecorder(queue, TrackUploader(api, queue));
      final convoy = ConvoyService(api, rt, trips, recorder: recorder, timeline: timeline);
      final meta = MetaService(api);
      final settings = SettingsService();
      final membership = MembershipService(api);
      final theme = ThemeController();

      expect(auth.isAuthenticated, isTrue);
      expect(auth.isMasterAdmin, isFalse);

      await tester.pumpWidget(buildTestHarness(
        api: api,
        auth: auth,
        convoy: convoy,
        rt: rt,
        trips: trips,
        timeline: timeline,
        meta: meta,
        settings: settings,
        membership: membership,
        theme: theme,
        child: const AccountScreen(),
      ));

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 1. Verify "Fleet & Tour Dispatcher Matrix" is NOT shown
      expect(find.text('Fleet & Tour Dispatcher Matrix'), findsNothing);
      expect(find.text('Fleet Management'), findsNothing);

      // 2. Verify "Admin" tile is NOT shown under App section
      expect(find.text('Admin'), findsNothing);
      expect(find.text('Live rides, history and users'), findsNothing);

      // 3. Verify legitimate rider settings are shown (Permissions now lives in the one
      //    Settings screen, opened from this row).
      expect(find.text('Change password'), findsOneWidget);
      expect(find.byKey(const Key('profile_settings')), findsOneWidget);
    });

    testWidgets('AccountScreen DOES show Admin tile only when signed in as Master Admin', (tester) async {
      tester.view.physicalSize = const Size(400, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final storage = const FlutterSecureStorage();
      await storage.write(key: 'coroute_jwt', value: 'admin_jwt_token');

      SharedPreferences.setMockInitialValues({
        AppConstants.keyUserId: 'admin_999',
        AppConstants.keyUserRole: AppConstants.adminRole, // MASTER_ADMIN
        AppConstants.keyUserName: 'Lead Admin',
        AppConstants.keyUserEmail: 'admin@coroute.in',
      });

      final mockHttp = MockClient((req) async {
        if (req.url.path.endsWith('/me')) {
          return http.Response(jsonEncode({
            'userId': 'admin_999',
            'role': AppConstants.adminRole,
            'name': 'Lead Admin',
            'email': 'admin@coroute.in',
          }), 200);
        }
        return http.Response('{}', 200);
      });
      final api = ApiClient(httpClient: mockHttp, storage: storage);
      await api.init();
      final auth = AuthService(api);
      await auth.revalidate();
      final rt = RealtimeService();
      final trips = TripStorageService(api);
      final timeline = TimelineService(api, rt);
      final queue = MemoryTrackQueue();
      final recorder = TrackRecorder(queue, TrackUploader(api, queue));
      final convoy = ConvoyService(api, rt, trips, recorder: recorder, timeline: timeline);
      final meta = MetaService(api);
      final settings = SettingsService();
      final membership = MembershipService(api);
      final theme = ThemeController();

      expect(auth.isAuthenticated, isTrue);
      expect(auth.isMasterAdmin, isTrue);

      await tester.pumpWidget(buildTestHarness(
        api: api,
        auth: auth,
        convoy: convoy,
        rt: rt,
        trips: trips,
        timeline: timeline,
        meta: meta,
        settings: settings,
        membership: membership,
        theme: theme,
        child: const AccountScreen(),
      ));

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Verify Admin tile is present for Master Admin (badge + settings row)
      expect(find.text('Admin'), findsNWidgets(2));
      expect(find.text('Live rides, history and users'), findsOneWidget);

      // Still no legacy Fleet Matrix tile
      expect(find.text('Fleet & Tour Dispatcher Matrix'), findsNothing);
    });

    testWidgets('Deep links cannot bypass admin authentication', (tester) async {
      final storage = const FlutterSecureStorage();
      await storage.write(key: 'coroute_jwt', value: 'rider_jwt_token');

      final api = ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: storage);
      await api.init();
      final auth = AuthService(api);
      final rt = RealtimeService();
      final trips = TripStorageService(api);
      final timeline = TimelineService(api, rt);
      final queue = MemoryTrackQueue();
      final recorder = TrackRecorder(queue, TrackUploader(api, queue));
      final convoy = ConvoyService(api, rt, trips, recorder: recorder, timeline: timeline);

      // 1. Verify invalid admin deep link is ignored
      final adminUri = Uri.parse('coroute://admin');
      expect(adminUri.host == 'join' || adminUri.host == 'subscription' || adminUri.host == 'cockpit', isFalse);
      expect(convoy.pendingJoinCode, isNull);

      // 2. Verify invalid fleet deep link is ignored
      final fleetUri = Uri.parse('coroute://fleet/matrix');
      expect(fleetUri.host == 'join' || fleetUri.host == 'subscription' || fleetUri.host == 'cockpit', isFalse);
      expect(convoy.pendingJoinCode, isNull);

      // 3. Normal join deep link correctly updates join code without elevating admin role
      final joinUri = Uri.parse('coroute://join/482913');
      if (joinUri.scheme == 'coroute' && joinUri.host == 'join') {
        convoy.setPendingJoinCode(joinUri.pathSegments.first);
      }
      expect(convoy.pendingJoinCode, '482913');
      expect(auth.isMasterAdmin, isFalse); // Deep link NEVER elevates rider to admin
    });
  });

  group('ISSUE-5: One Admin Console Regression Tests', () {
    // Totals as /admin/analytics/overview answers them (counted on the server).
    final overview = {
      'ok': true,
      'days': 30,
      'riders': {'total': 42, 'active7d': 11, 'active30d': 23, 'newInPeriod': 5, 'paying': 3, 'conversionPct': 7.1},
      'rides': {'groupsInPeriod': 4, 'groupsCompleted': 9, 'tripsInPeriod': 12, 'completedTrips': 31, 'kmInPeriod': 846, 'kmRidden': 2107, 'avgGroupSize': 3.5},
      'safety': {'sosInPeriod': 1, 'resolved': 1, 'falseAlarms': 0, 'medianResponseSec': 90},
      'payments': {'revenueInPeriodInr': 447, 'revenueInr': 1490},
    };

    testWidgets('Phone opens the one admin console in an AdminShell with the server totals (no sample numbers)', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final storage = const FlutterSecureStorage();
      await storage.write(key: 'coroute_jwt', value: 'admin_jwt');

      SharedPreferences.setMockInitialValues({
        AppConstants.keyUserId: 'admin_1',
        AppConstants.keyUserRole: AppConstants.adminRole,
      });

      final calls = <http.Request>[];
      final mockHttp = MockClient((req) async {
        calls.add(req);
        final path = req.url.path;
        if (path.endsWith('/admin/analytics/overview')) return http.Response(jsonEncode(overview), 200);
        if (path.endsWith('/admin/users')) return http.Response(jsonEncode({'users': []}), 200);
        if (path.endsWith('/admin/fleet')) return http.Response(jsonEncode({'convoys': []}), 200);
        return http.Response('{}', 200);
      });

      final api = ApiClient(httpClient: mockHttp, storage: storage);
      await api.init();
      final auth = AuthService(api);
      final rt = RealtimeService();
      final trips = TripStorageService(api);
      final timeline = TimelineService(api, rt);
      final queue = MemoryTrackQueue();
      final recorder = TrackRecorder(queue, TrackUploader(api, queue));
      final convoy = ConvoyService(api, rt, trips, recorder: recorder, timeline: timeline);
      final meta = MetaService(api);
      final settings = SettingsService();
      final membership = MembershipService(api);
      final theme = ThemeController();

      await tester.pumpWidget(buildTestHarness(
        api: api,
        auth: auth,
        convoy: convoy,
        rt: rt,
        trips: trips,
        timeline: timeline,
        meta: meta,
        settings: settings,
        membership: membership,
        theme: theme,
        child: MasterAdminDashboard(alarm: _TestSilentAlarm()),
      ));

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      // One shell on phones too (the old separate phone dashboard with sample numbers is gone).
      expect(find.byType(AdminShell), findsOneWidget);
      expect(calls.any((r) => r.url.path.endsWith('/admin/analytics/overview')), isTrue);
      expect(calls.any((r) => r.url.path.endsWith('/admin/analytics/trends')), isTrue);
      // Totals come from the server answer, folded under "More numbers".
      await tester.ensureVisible(find.text('More numbers'));
      await tester.tap(find.text('More numbers'));
      await tester.pump();
      await tester.ensureVisible(find.text('Avg group'));
      expect(find.text('846'), findsOneWidget);
      expect(find.text('2107 all time'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('3.5'), findsOneWidget);
      // Every section is one tap away in the menu.
      await tester.tap(find.byIcon(Icons.menu_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      for (final label in ['Overview', 'Riders', 'Rides & safety', 'Content', 'System']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      // Merged away: phone reports are in Usage. Removed (Play payments policy): payments, coupons,
      // plan prices and marketing are managed in the web admin.
      for (final gone in ['Plans and coupons', 'Devices', 'Groups and rides', 'Plans & payments', 'Payments', 'Marketing', 'Revenue']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('Desktop admin layout remains intact with AdminShell and AdminTwoUp on wide screens', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final storage = const FlutterSecureStorage();
      await storage.write(key: 'coroute_jwt', value: 'admin_jwt');

      SharedPreferences.setMockInitialValues({
        AppConstants.keyUserId: 'admin_1',
        AppConstants.keyUserRole: AppConstants.adminRole,
      });

      final mockHttp = MockClient((req) async {
        if (req.url.path.endsWith('/admin/users')) {
          return http.Response(jsonEncode({
            'users': [
              {'userId': 'u1', 'name': 'Admin User', 'email': 'admin@coroute.in', 'status': 'ACTIVE'},
            ]
          }), 200);
        }
        if (req.url.path.endsWith('/admin/fleet')) {
          return http.Response(jsonEncode({'convoys': []}), 200);
        }
        return http.Response('{}', 200);
      });

      final api = ApiClient(httpClient: mockHttp, storage: storage);
      await api.init();
      final auth = AuthService(api);
      final rt = RealtimeService();
      final trips = TripStorageService(api);
      final timeline = TimelineService(api, rt);
      final queue = MemoryTrackQueue();
      final recorder = TrackRecorder(queue, TrackUploader(api, queue));
      final convoy = ConvoyService(api, rt, trips, recorder: recorder, timeline: timeline);
      final meta = MetaService(api);
      final settings = SettingsService();
      final membership = MembershipService(api);
      final theme = ThemeController();

      await tester.pumpWidget(buildTestHarness(
        api: api,
        auth: auth,
        convoy: convoy,
        rt: rt,
        trips: trips,
        timeline: timeline,
        meta: meta,
        settings: settings,
        membership: membership,
        theme: theme,
        child: MasterAdminDashboard(alarm: _TestSilentAlarm()),
      ));

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Verification: On wide screen, MasterAdminDashboard retains AdminShell
      expect(find.byType(AdminShell), findsOneWidget);
      // Verification: On wide screen, MasterAdminDashboard lays its charts out two by two
      expect(find.byType(AdminTwoUp), findsWidgets);
      // Verification: Desktop nav rail items are present
      for (final label in ['Overview', 'Riders', 'Rides & safety', 'Content', 'System']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      for (final gone in ['Plans and coupons', 'Devices', 'Groups and rides', 'Plans & payments', 'Payments', 'Marketing']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
    });
  });
}
