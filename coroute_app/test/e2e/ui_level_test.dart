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
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/presentation/admin/master_admin_dashboard.dart';
import 'package:coroute_app/presentation/auth/access_gate_screen.dart';
import 'package:coroute_app/presentation/ride/riders_ladder.dart';
import 'package:coroute_app/presentation/rider/rider_home_screen.dart';
import 'package:coroute_app/presentation/widgets/intercom_dock.dart';

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
      expect(find.textContaining('EMERGENCY CONTACT'), findsOneWidget);
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
  group('UI Level E2E: Active ride sheet, riders ladder, trip progress and intercom', () {
    testWidgets('An active convoy shows its riders, stops and the talk-to picker', (tester) async {
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

      Widget rideParts() => Consumer<ConvoyService>(builder: (context, service, _) {
            final c = service.activeConvoy;
            if (c == null) return const SizedBox.shrink();
            final nowMs = DateTime.now().millisecondsSinceEpoch;
            final me = c.riders['usr_me']!;
            return Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(c.name),
                        Text('Code ${c.joinCode}'),
                        RidersLadder(
                          rungs: RideFacts.ladder(c, 'usr_me'),
                          colors: const {},
                          statuses: {for (final r in c.riders.values) r.userId: riderStatusOf(r, c, isMe: r.userId == 'usr_me', nowMs: nowMs)},
                          nowMs: nowMs,
                          onTap: (_) {},
                        ),
                        TripProgress(stops: [
                          for (final st in c.plannedStops)
                            TripProgressStop(name: st.name, kind: StopKind.fromCategory(st.category), done: st.isVisited),
                        ]),
                      ],
                    ),
                  ),
                ),
                IntercomDock(convoy: c, me: me),
              ],
            );
          });

      await tester.pumpWidget(createUiHarness(
        api: api,
        auth: auth,
        rt: rt,
        convoy: convoy,
        meta: meta,
        trips: trips,
        timeline: timeline,
        intercom: intercom,
        child: rideParts(),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      // Convoy loaded from the session
      expect(find.text('Western Ghats Monsoon Express'), findsOneWidget);
      expect(find.textContaining('WST900'), findsOneWidget);

      // Riders ladder: everyone, with me marked
      expect(find.text('Captain Jack'), findsOneWidget);
      expect(find.text('Tail Sweep'), findsOneWidget);
      expect(find.textContaining('Phoenix (Me)'), findsOneWidget);

      // Trip progress lists the planned stops
      expect(find.text('Shell Fuel Stop'), findsOneWidget);
      expect(find.text('Hilltop Cafe'), findsOneWidget);

      // Intercom dock: one row, no mode toggle and no SOS (SOS is the hold button on the map)
      expect(find.text('Talk to: Everyone'), findsOneWidget);
      expect(find.text('HOLD TO TALK'), findsOneWidget);
      expect(find.text('PTT'), findsNothing);
      expect(find.text('VOX'), findsNothing);
      expect(find.text('SOS'), findsNothing);

      // Open Intercom Talk-To Channel Picker
      await tester.tap(find.text('Talk to: Everyone'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final sheet = find.byType(BottomSheet);
      expect(find.text('Everyone in the convoy'), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Captain Jack')), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Tail Sweep')), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.textContaining('Phoenix (Me)')), findsNothing);

      // Select Captain Jack for Private 1:1 Radio
      await tester.tap(find.widgetWithText(ListTile, 'Captain Jack'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Private: Captain Jack'), findsOneWidget);

      // Clean up session and background timers
      await convoy.endSession();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('UI Level E2E: Cockpit HUD Dynamics & Master Admin Controls', () {
    // 3.12: the HUD is only the speed card; compass, heading and speed category are gone.
    testWidgets('CockpitHud shows the speed and, without a group limit, the label Speed', (tester) async {
      // 1. 45 km/h (heading and battery are still accepted, no longer shown)
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(AppPalette.dark),
        home: const Scaffold(
          body: CockpitHud(speedKmh: 45.0, heading: 90.0, batteryLevel: 95),
        ),
      ));
      // RideMetric draws the number and unit as one rich text.
      expect(find.text('45 km/h'), findsOneWidget);

      // 2. 80 km/h
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(AppPalette.dark),
        home: const Scaffold(
          body: CockpitHud(speedKmh: 80.0, heading: 315.0, batteryLevel: 80),
        ),
      ));
      // RideMetric draws the number and unit as one rich text.
      expect(find.text('80 km/h'), findsOneWidget);

      // 3. 115 km/h, no limit set: label 'Speed', no compass text
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(AppPalette.dark),
        home: const Scaffold(
          body: CockpitHud(speedKmh: 115.0, heading: 180.0, batteryLevel: 65),
        ),
      ));
      // RideMetric draws the number and unit as one rich text.
      expect(find.text('115 km/h'), findsOneWidget);
      expect(find.text('Speed'), findsOneWidget);
      expect(find.text('180° S'), findsNothing);
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
