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
import 'package:coroute_app/core/widgets/cockpit_hud.dart';
import 'package:coroute_app/data/local/track_queue.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/stop_point_model.dart';
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
import 'package:coroute_app/presentation/rider/convoy_dashboard_screen.dart';
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
      expect(find.text('Sign In'), findsOneWidget);
      expect(find.text('Register Account'), findsOneWidget);
      expect(find.textContaining('EMAIL OR CALLSIGN'), findsOneWidget);
      expect(find.text('SIGN IN'), findsOneWidget);

      // Validate Sign In Empty fields
      await tester.tap(find.text('SIGN IN'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('Please enter your email or callsign'), findsOneWidget);

      // Switch to Register Account Tab
      await tester.tap(find.text('Register Account'));
      await tester.pump(const Duration(milliseconds: 300));

      // Verify registration fields
      expect(find.textContaining('CALLSIGN / FULL NAME'), findsOneWidget);
      expect(find.textContaining('EMAIL ADDRESS'), findsOneWidget);
      expect(find.textContaining('MOBILE PHONE NUMBER'), findsOneWidget);
      expect(find.textContaining('VEHICLE TYPE'), findsOneWidget);
      expect(find.textContaining('EMERGENCY (ICE) CONTACT'), findsOneWidget);
      expect(find.textContaining('I accept the '), findsOneWidget);
      expect(find.text('REGISTER RIDER ACCOUNT'), findsOneWidget);

      // Try creating account with empty fields
      await tester.ensureVisible(find.text('REGISTER RIDER ACCOUNT'));
      await tester.tap(find.text('REGISTER RIDER ACCOUNT'));
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

      await tester.ensureVisible(find.text('REGISTER RIDER ACCOUNT'));
      await tester.tap(find.text('REGISTER RIDER ACCOUNT'));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('Passwords do not match'), findsOneWidget);
    });
  });

  group('UI Level E2E: RiderHomeScreen Controls & Modals', () {
    testWidgets('RiderHomeScreen renders rider profile card, actions, and Join Modal', (tester) async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyUserId: 'usr_neo',
        AppConstants.keyUserName: 'Neo One',
        AppConstants.keyUserRole: AppConstants.riderRole,
        AppConstants.keyVehicleType: 'Motorcycle (Adv)',
        AppConstants.keyVehicleNo: 'KA-05-EX-9999',
        AppConstants.keyPhone: '+91 9888877777',
      });
      final storage = const FlutterSecureStorage();
      await storage.write(key: 'coroute_jwt', value: 'token-neo');

      final mockHttp = MockClient((req) async {
        if (req.url.path.endsWith('/me')) {
          return http.Response(jsonEncode({
            'userId': 'usr_neo',
            'name': 'Neo One',
            'role': AppConstants.riderRole,
            'vehicleType': 'Motorcycle (Adv)',
            'vehicleNo': 'KA-05-EX-9999',
            'phone': '+91 9888877777',
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

      // Check Profile Header Card
      expect(find.text('Neo One'), findsOneWidget);
      expect(find.textContaining('Motorcycle (Adv)'), findsOneWidget);
      expect(find.textContaining('KA-05-EX-9999'), findsOneWidget);

      // Check Action Cards
      expect(find.text('Create Convoy'), findsOneWidget);
      expect(find.text('Join Convoy'), findsOneWidget);

      // Tap Join Convoy Card -> Opens Join with Code Dialog
      await tester.tap(find.text('Join Convoy'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Join with Code'), findsOneWidget);
      expect(find.text('Enter the 6-character room code shared by your convoy lead.'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Connect to Convoy'), findsOneWidget);

      // Cancel Dialog
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Join with Code'), findsNothing);
    });
  });

  group('UI Level E2E: ConvoyDashboardScreen Tabs, Intercom & Status', () {
    testWidgets('ConvoyDashboardScreen renders active convoy, tabs, intercom dock and status sheet', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final now = DateTime.now().millisecondsSinceEpoch;
      final riders = {
        'usr_me': RiderModel(
          userId: 'usr_me',
          name: 'Phoenix (Me)',
          lat: 12.9716,
          lng: 77.5946,
          speedKmh: 68.0,
          heading: 45.0,
          batteryLevel: 92,
          lastSeenEpochMs: now,
        ),
        'usr_lead': RiderModel(
          userId: 'usr_lead',
          name: 'Captain Jack',
          lat: 12.9740,
          lng: 77.5960,
          speedKmh: 72.0,
          heading: 45.0,
          batteryLevel: 85,
          lastSeenEpochMs: now,
        ),
        'usr_sweep': RiderModel(
          userId: 'usr_sweep',
          name: 'Tail Sweep',
          lat: 12.9690,
          lng: 77.5930,
          speedKmh: 65.0,
          heading: 45.0,
          batteryLevel: 78,
          lastSeenEpochMs: now,
        ),
      };

      final stops = [
        StopPointModel(stopId: 's1', name: 'Shell Fuel Stop', lat: 12.9800, lng: 77.6000, orderIndex: 1),
        StopPointModel(stopId: 's2', name: 'Hilltop Cafe', lat: 13.0100, lng: 77.6200, orderIndex: 2),
      ];

      final activeConvoy = ConvoyModel(
        groupId: 'GRP-GHATS-01',
        name: 'Western Ghats Monsoon Express',
        joinCode: 'WST900',
        createdByUserId: 'usr_lead',
        createdByUserName: 'Captain Jack',
        createdAtEpochMs: now - 3600000,
        destinationName: 'Coorg Valley Peak',
        destinationLat: 12.3375,
        destinationLng: 75.8069,
        riders: riders,
        stopPoints: stops,
      );

      final mockHttp = MockClient((req) async {
        if (req.url.path.endsWith('/convoys/active')) {
          return http.Response(jsonEncode({'convoy': activeConvoy.toJson()}), 200);
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

      await convoy.startSession(token: 'test-token', userId: 'usr_me');

      await tester.pumpWidget(createUiHarness(
        api: api,
        auth: auth,
        rt: rt,
        convoy: convoy,
        meta: meta,
        trips: trips,
        timeline: timeline,
        intercom: intercom,
        child: const ConvoyDashboardScreen(groupId: 'GRP-GHATS-01'),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      // Convoy Header Info
      expect(find.text('Western Ghats Monsoon Express'), findsOneWidget);
      expect(find.textContaining('WST900'), findsOneWidget);

      // Verify Tab bar headers
      expect(find.text('Riders (3)'), findsOneWidget);
      expect(find.text('Chat (0)'), findsOneWidget);
      expect(find.text('Stops (2)'), findsOneWidget);
      expect(find.text('⚙️ Settings'), findsOneWidget);

      // Verify Intercom Dock
      expect(find.text('Talk to: Everyone'), findsOneWidget);
      expect(find.text('PTT'), findsOneWidget);
      expect(find.text('VOX'), findsOneWidget);
      expect(find.text('HOLD TO TALK'), findsOneWidget);
      expect(find.text('SOS'), findsOneWidget);

      // Switch to Stops Tab
      await tester.tap(find.widgetWithText(Tab, 'Stops (2)'));
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Shell Fuel Stop'), findsOneWidget);
      expect(find.text('Hilltop Cafe'), findsOneWidget);

      // Switch to Chat Tab
      await tester.tap(find.widgetWithText(Tab, 'Chat (0)'));
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.textContaining('No group messages yet'), findsOneWidget);

      // Switch back to Riders Tab
      await tester.tap(find.widgetWithText(Tab, 'Riders (3)'));
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // Open Intercom Talk-To Channel Picker
      await tester.tap(find.text('Talk to: Everyone'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Everyone in the convoy'), findsOneWidget);
      expect(find.text('Captain Jack'), findsAtLeastNWidgets(1));
      expect(find.text('Tail Sweep'), findsAtLeastNWidgets(1));
      expect(find.text('Phoenix (Me)'), findsNothing);

      // Select Captain Jack for Private 1:1 Radio
      await tester.tap(find.widgetWithText(ListTile, 'Captain Jack'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Private: Captain Jack'), findsOneWidget);

      // Clean up session and background timers
      await convoy.endSession();
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('UI Level E2E: Cockpit HUD Dynamics & Master Admin Controls', () {
    testWidgets('CockpitHud dynamically adapts speed colors and cardinal directions', (tester) async {
      // 1. Cruising speed (45 km/h, East = 90 deg)
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(AppPalette.dark),
        home: const Scaffold(
          body: CockpitHud(speedKmh: 45.0, heading: 90.0, batteryLevel: 95),
        ),
      ));
      expect(find.text('45'), findsOneWidget);
      expect(find.text('km/h'), findsOneWidget);
      expect(find.text('90° E'), findsOneWidget);
      expect(find.text('City Cruising'), findsOneWidget);

      // 2. Highway pace (80 km/h, Northwest = 315 deg)
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(AppPalette.dark),
        home: const Scaffold(
          body: CockpitHud(speedKmh: 80.0, heading: 315.0, batteryLevel: 80),
        ),
      ));
      expect(find.text('80'), findsOneWidget);
      expect(find.text('km/h'), findsOneWidget);
      expect(find.text('315° NW'), findsOneWidget);
      expect(find.text('Highway Pace'), findsOneWidget);

      // 3. High speed warning (115 km/h, South = 180 deg)
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(AppPalette.dark),
        home: const Scaffold(
          body: CockpitHud(speedKmh: 115.0, heading: 180.0, batteryLevel: 65),
        ),
      ));
      expect(find.text('115'), findsOneWidget);
      expect(find.text('km/h'), findsOneWidget);
      expect(find.text('180° S'), findsOneWidget);
      expect(find.text('High Speed'), findsOneWidget);
    });

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
      expect(find.text('Master Admin Console'), findsOneWidget);
      expect(find.text('Active Convoys').first, findsOneWidget);
      expect(find.text('Riders Online'), findsOneWidget);
      expect(find.text('Emergency SOS'), findsOneWidget);

      // Open Global Safety Broadcast Modal
      expect(find.byIcon(Icons.campaign), findsOneWidget);
      await tester.tap(find.byIcon(Icons.campaign));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Global Safety Broadcast'), findsOneWidget);
      expect(find.text('This alert will be broadcasted to all active convoys immediately on their map HUD.'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Send to Fleet'), findsOneWidget);

      // Enter Broadcast Message and Send
      final broadcastInput = find.byType(TextField);
      await tester.enterText(broadcastInput, 'Heavy Fog Warning on NH48. Reduce speed.');
      await tester.tap(find.text('Send to Fleet'));
      await tester.pump(const Duration(milliseconds: 300));

      // Modal closed after dispatch
      expect(find.text('Global Safety Broadcast'), findsNothing);
    });
  });
}
