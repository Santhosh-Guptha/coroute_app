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
import 'package:coroute_app/core/ui/ui.dart';
import 'package:coroute_app/data/local/track_queue.dart';
import 'package:coroute_app/data/services/alert_service.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/meta_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/timeline_service.dart';
import 'package:coroute_app/data/services/track_recorder.dart';
import 'package:coroute_app/data/services/track_uploader.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/admin/master_admin_dashboard.dart';
import 'package:coroute_app/presentation/auth/access_gate_screen.dart';
import 'package:coroute_app/presentation/rider/rider_home_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Widget createUiHarness({
    required ApiClient api,
    required AuthService auth,
    required RealtimeService rt,
    required ConvoyService convoy,
    required MetaService meta,
    required TripStorageService trips,
    required TimelineService timeline,
    required IntercomService intercom,
    required Widget child,
    Size surfaceSize = const Size(600, 1200),
  }) {
    final theme = ThemeController();
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider<ApiClient>.value(value: api),
        ChangeNotifierProvider<RealtimeService>.value(value: rt),
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider<MetaService>.value(value: meta),
        ChangeNotifierProvider<TripStorageService>.value(value: trips),
        ChangeNotifierProvider<TimelineService>.value(value: timeline),
        ChangeNotifierProvider<ConvoyService>.value(value: convoy),
        ChangeNotifierProvider<IntercomService>.value(value: intercom),
        Provider<AlertService>(
          create: (_) => AlertService(convoy, timeline),
          dispose: (_, a) => a.dispose(),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.themeFor(AppPalette.dark),
        home: MediaQuery(
          data: MediaQueryData(size: surfaceSize),
          child: Scaffold(body: child),
        ),
      ),
    );
  }

  group('UI Level E2E: AccessGateScreen Form & Interaction Flows', () {
    testWidgets('AccessGateScreen renders tabs and switches between Sign In and Register', (tester) async {
      final mockHttp = MockClient((req) async => http.Response('{}', 200));
      final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
      final auth = AuthService(api);
      final rt = RealtimeService();
      final meta = MetaService(api);
      final trips = TripStorageService(api);
      final timeline = TimelineService(api, rt);
      final queue = MemoryTrackQueue();
      final recorder = TrackRecorder(queue, TrackUploader(api, queue));
      final convoy = ConvoyService(api, rt, trips, recorder: recorder, timeline: timeline);
      final intercom = IntercomService(rt);

      await tester.pumpWidget(createUiHarness(
        api: api,
        auth: auth,
        rt: rt,
        convoy: convoy,
        meta: meta,
        trips: trips,
        timeline: timeline,
        intercom: intercom,
        child: const AccessGateScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      // Sign In Tab Active by default
      expect(find.widgetWithText(Tab, 'Sign In'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Register Account'), findsOneWidget);
      expect(find.textContaining('Rider Callsign or Email'), findsOneWidget);
      expect(find.widgetWithText(DsButton, 'Continue'), findsOneWidget);

      // Validate Sign In Empty fields
      await tester.ensureVisible(find.widgetWithText(DsButton, 'Continue'));
      await tester.tap(find.widgetWithText(DsButton, 'Continue'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('Please enter your email or callsign'), findsOneWidget);

      // Switch to Register Account Tab
      await tester.ensureVisible(find.widgetWithText(Tab, 'Register Account'));
      await tester.tap(find.widgetWithText(Tab, 'Register Account'));
      await tester.pump(const Duration(milliseconds: 300));

      // Verify registration fields
      expect(find.textContaining('Callsign or Full Name'), findsOneWidget);
      expect(find.textContaining('Email Address'), findsOneWidget);
      expect(find.textContaining('Mobile Phone Number'), findsOneWidget);
      expect(find.textContaining('Vehicle Type'), findsOneWidget);
      expect(find.textContaining('Emergency Contact'), findsOneWidget);
      expect(find.textContaining('I accept the '), findsOneWidget);
      expect(find.text('Register Rider Account'), findsOneWidget);

      // Try creating account with empty fields
      await tester.ensureVisible(find.text('Register Rider Account'));
      await tester.tap(find.text('Register Rider Account'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('Please enter your callsign or full name'), findsOneWidget);
    });

    testWidgets('AccessGateScreen enforces terms acceptance and password confirmation', (tester) async {
      final mockHttp = MockClient((req) async => http.Response('{}', 200));
      final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
      final auth = AuthService(api);
      final rt = RealtimeService();
      final meta = MetaService(api);
      final trips = TripStorageService(api);
      final timeline = TimelineService(api, rt);
      final queue = MemoryTrackQueue();
      final recorder = TrackRecorder(queue, TrackUploader(api, queue));
      final convoy = ConvoyService(api, rt, trips, recorder: recorder, timeline: timeline);
      final intercom = IntercomService(rt);

      await tester.pumpWidget(createUiHarness(
        api: api,
        auth: auth,
        rt: rt,
        convoy: convoy,
        meta: meta,
        trips: trips,
        timeline: timeline,
        intercom: intercom,
        child: const AccessGateScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      // Switch to Register
      await tester.tap(find.text('Register Account'));
      await tester.pump(const Duration(milliseconds: 300));

      // In registration form:
      // index 0: Name, index 1: Email, index 2: Password, index 3: Confirm Password
      final textFields = find.byType(TextField);
      await tester.enterText(textFields.at(0), 'Maverick');
      await tester.enterText(textFields.at(1), 'mav@coroute.app');
      await tester.enterText(textFields.at(2), 'SecretPassword123');
      await tester.enterText(textFields.at(3), 'MismatchPassword999');

      await tester.ensureVisible(find.text('Register Rider Account'));
      await tester.tap(find.text('Register Rider Account'));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('Passwords do not match'), findsOneWidget);
    });
  });

  group('UI Level E2E: RiderHomeScreen Controls & Modals', () {
    testWidgets('RiderHomeScreen shell renders the Ride tab, the join sheet and the Profile tab', (tester) async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyUserId: 'usr_neo',
        AppConstants.keyUserName: 'Neo One',
        AppConstants.keyUserEmail: 'neo@example.com',
        AppConstants.keyUserRole: AppConstants.riderRole,
        AppConstants.keyVehicleType: 'Motorcycle (Adv)',
        AppConstants.keyVehicleNo: 'KA-05-EX-9999',
        AppConstants.keyPhone: '+91 9888877777',
        AppConstants.keyEmergencyContact: '+91 9999911111',
        AppConstants.keyEmergencyName: 'Morpheus',
      });
      final storage = const FlutterSecureStorage();
      await storage.write(key: 'coroute_jwt', value: 'token-neo');

      final mockHttp = MockClient((req) async {
        if (req.url.path.endsWith('/me')) {
          return http.Response(jsonEncode({
            'userId': 'usr_neo',
            'name': 'Neo One',
            'email': 'neo@example.com',
            'role': AppConstants.riderRole,
            'vehicleType': 'Motorcycle (Adv)',
            'vehicleNo': 'KA-05-EX-9999',
            'phone': '+91 9888877777',
            'emergencyContact': '+91 9999911111',
            'emergencyContactName': 'Morpheus',
          }), 200);
        }
        if (req.url.path.endsWith('/convoys/active')) {
          return http.Response(jsonEncode({'convoy': null}), 200);
        }
        return http.Response('{}', 200);
      });

      final api = ApiClient(httpClient: mockHttp, storage: storage);
      final auth = AuthService(api);
      final rt = RealtimeService();
      final meta = MetaService(api);
      final trips = TripStorageService(api);
      final timeline = TimelineService(api, rt);
      final queue = MemoryTrackQueue();
      final recorder = TrackRecorder(queue, TrackUploader(api, queue));
      final convoy = ConvoyService(api, rt, trips, recorder: recorder, timeline: timeline);
      final intercom = IntercomService(rt);

      await tester.pumpWidget(createUiHarness(
        api: api,
        auth: auth,
        rt: rt,
        convoy: convoy,
        meta: meta,
        trips: trips,
        timeline: timeline,
        intercom: intercom,
        child: const RiderHomeScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      // Ride tab (default): no active ride, so the start view with its two actions.
      // The drawer and the home profile card are gone (3.12 shell).
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('No active ride'), findsOneWidget);
      expect(find.text('Start Ride'), findsOneWidget);
      expect(find.text('Join Ride'), findsOneWidget);
      expect(find.byType(Drawer), findsNothing);

      // Join Ride opens the join sheet (not a dialog).
      await tester.tap(find.text('Join Ride'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Join a ride'), findsOneWidget);
      expect(find.text('Enter the code shared by the person who started the ride.'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Join'), findsOneWidget);

      // Close the sheet.
      Navigator.of(tester.element(find.text('Join a ride'))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Join a ride'), findsNothing);

      // The profile header now lives on the Profile tab.
      await tester.tap(find.widgetWithText(NavigationDestination, 'Profile'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Neo One'), findsOneWidget);
      expect(find.textContaining('Motorcycle (Adv)'), findsOneWidget);
      expect(find.textContaining('KA-05-EX-9999'), findsOneWidget);
      expect(find.text('Emergency contact: set'), findsOneWidget);
    });
  });

  // The dashboard screen is gone (3.12): the ride is one map with one sheet. The map itself
  // loads network tiles, so this test drives the ride sheet parts with the live service data
  // instead of the whole screen (A's ui_widgets_test covers each part at 320 dp).

  group('UI Level E2E: Cockpit HUD Dynamics & Master Admin Controls', () {
    // 3.12: the HUD is only the speed card; compass, heading and speed category are gone.

    testWidgets('MasterAdminDashboard displays fleet counters and Global Broadcast modal', (tester) async {
      final mockHttp = MockClient((req) async {
        if (req.url.path.endsWith('/admin/broadcast')) {
          return http.Response(jsonEncode({'success': true}), 200);
        }
        return http.Response('{}', 200);
      });

      final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
      final auth = AuthService(api);
      final rt = RealtimeService();
      final meta = MetaService(api);
      final trips = TripStorageService(api);
      final timeline = TimelineService(api, rt);
      final queue = MemoryTrackQueue();
      final recorder = TrackRecorder(queue, TrackUploader(api, queue));
      final convoy = ConvoyService(api, rt, trips, recorder: recorder, timeline: timeline);
      final intercom = IntercomService(rt);

      await tester.pumpWidget(createUiHarness(
        api: api,
        auth: auth,
        rt: rt,
        convoy: convoy,
        meta: meta,
        trips: trips,
        timeline: timeline,
        intercom: intercom,
        child: const MasterAdminDashboard(),
        surfaceSize: const Size(600, 1000),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      // Fleet Dashboard Verification
      // 3.13 admin home: labels changed with the admin console redesign (WP-ADM).
      expect(find.text('Admin'), findsOneWidget);
      expect(find.text('Live rides'), findsWidgets);
      expect(find.text('Riders online'), findsOneWidget);
      expect(find.text('Open SOS'), findsOneWidget);

      // Open the safety broadcast sheet
      expect(find.byTooltip('Safety broadcast'), findsOneWidget);
      await tester.tap(find.byTooltip('Safety broadcast'));
      await tester.pump(); // the route animation starts on this frame
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Safety broadcast'), findsOneWidget);
      expect(find.text('Every rider in a live ride sees this alert on their map right away.'), findsOneWidget);
      expect(find.text('Send to all live rides'), findsOneWidget);

      // Enter Broadcast Message and Send
      final broadcastInput = find.byType(TextField);
      await tester.enterText(broadcastInput, 'Heavy Fog Warning on NH48. Reduce speed.');
      await tester.pump();
      await tester.tap(find.text('Send to all live rides'));
      await tester.pump(); // the route animation starts on this frame
      await tester.pump(const Duration(milliseconds: 300));

      // Sheet closed after dispatch
      expect(find.text('Every rider in a live ride sees this alert on their map right away.'), findsNothing);
    });
  });
}
