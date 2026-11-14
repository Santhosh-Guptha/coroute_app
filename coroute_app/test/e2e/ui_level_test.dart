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
import 'package:coroute_app/presentation/shell/coroute_nav_bar.dart';

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
    testWidgets('AccessGateScreen shows sign in and switches to create account', (tester) async {
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

      // Sign in is shown by default: one field pair, one primary button.
      expect(find.widgetWithText(DsButton, 'Sign in'), findsOneWidget);
      expect(find.text('Create account'), findsOneWidget);
      expect(find.text('Email or callsign'), findsOneWidget);

      // Validate Sign In Empty fields
      await tester.ensureVisible(find.widgetWithText(DsButton, 'Sign in'));
      await tester.tap(find.widgetWithText(DsButton, 'Sign in'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('Please enter your email or callsign'), findsOneWidget);

      // Switch to create account
      await tester.ensureVisible(find.text('Create account'));
      await tester.tap(find.text('Create account'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(); // the fade-out of the sign-in form has finished: it leaves the tree

      // Verify registration fields
      expect(find.text('Name or callsign'), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Phone'), findsOneWidget);
      expect(find.text('Vehicle type'), findsOneWidget);
      expect(find.text('Emergency contact'), findsOneWidget);
      expect(find.textContaining('I accept the '), findsOneWidget);
      expect(find.widgetWithText(DsButton, 'Create account'), findsOneWidget);

      // Try creating account with empty fields
      await tester.ensureVisible(find.widgetWithText(DsButton, 'Create account'));
      await tester.tap(find.widgetWithText(DsButton, 'Create account'));
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

      // Switch to create account
      await tester.ensureVisible(find.text('Create account'));
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Name or callsign'), 'Maverick');
      await tester.enterText(find.widgetWithText(TextField, 'Email'), 'mav@coroute.app');
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'SecretPassword123');
      await tester.enterText(find.widgetWithText(TextField, 'Confirm password'), 'MismatchPassword999');

      await tester.ensureVisible(find.widgetWithText(DsButton, 'Create account'));
      await tester.tap(find.widgetWithText(DsButton, 'Create account'));
      await tester.pumpAndSettle();

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

      // v3.58 shell: Home (no ride) with the new bottom bar; the drawer is still gone.
      expect(find.byType(CoRouteNavBar), findsOneWidget);
      expect(find.byKey(const Key('home_carousel')), findsOneWidget);
      expect(find.byKey(const Key('home_emergency')), findsOneWidget, reason: 'Emergency is visible on Home');
      expect(find.byType(Drawer), findsNothing);

      // "+" -> Join with a code opens the join sheet (not a dialog).
      await tester.tap(find.byKey(const Key('nav_plus')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('qa_join')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Join a ride'), findsOneWidget);
      expect(find.text('Enter the code shared by the person who started the ride.'), findsOneWidget);
      expect(find.text('Join'), findsOneWidget);

      // Close the sheet.
      Navigator.of(tester.element(find.text('Join a ride'))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Join a ride'), findsNothing);

      // Profile is behind the avatar on Home.
      await tester.tap(find.byKey(const Key('home_avatar')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Neo One'), findsWidgets);
      expect(find.byKey(const Key('profile_emergency')), findsOneWidget);
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
      expect(find.text('Active today'), findsOneWidget);
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
