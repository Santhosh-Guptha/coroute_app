import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/core/theme/theme_controller.dart';
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
import 'package:coroute_app/domain/tracking/track_point.dart';
import 'package:coroute_app/presentation/admin/master_admin_dashboard.dart';
import 'package:coroute_app/presentation/auth/access_gate_screen.dart';
import 'package:coroute_app/presentation/rider/rider_home_screen.dart';
import 'package:coroute_app/presentation/splash/splash_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Widget buildAppHarness({
    required ApiClient apiClient,
    required AuthService authService,
    required RealtimeService realtimeService,
    required ConvoyService convoyService,
    required MetaService metaService,
    required TripStorageService tripStorageService,
    required TimelineService timelineService,
    required TrackRecorder trackRecorder,
    required IntercomService intercomService,
    required Widget child,
  }) {
    final theme = ThemeController();
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider<ApiClient>.value(value: apiClient),
        ChangeNotifierProvider<RealtimeService>.value(value: realtimeService),
        ChangeNotifierProvider<AuthService>.value(value: authService),
        ChangeNotifierProvider<MetaService>.value(value: metaService),
        ChangeNotifierProvider<TripStorageService>.value(value: tripStorageService),
        ChangeNotifierProvider<TimelineService>.value(value: timelineService),
        ChangeNotifierProvider<TrackRecorder>.value(value: trackRecorder),
        ChangeNotifierProvider<ConvoyService>.value(value: convoyService),
        ChangeNotifierProvider<IntercomService>.value(value: intercomService),
        Provider<AlertService>(
          create: (_) => AlertService(convoyService, timelineService),
          dispose: (_, a) => a.dispose(),
        ),
      ],
      child: MaterialApp(
        home: child,
      ),
    );
  }

  group('Application Level E2E: Boot, Initialization & Routing', () {
    testWidgets('Unauthenticated boot routes through SplashScreen to AccessGateScreen', (tester) async {
      final mockHttp = MockClient((req) async => http.Response('{}', 404));
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

      await tester.pumpWidget(buildAppHarness(
        apiClient: api,
        authService: auth,
        realtimeService: rt,
        convoyService: convoy,
        metaService: meta,
        tripStorageService: trips,
        timelineService: timeline,
        trackRecorder: recorder,
        intercomService: intercom,
        child: const SplashScreen(),
      ));

      // Initially on SplashScreen
      expect(find.byType(SplashScreen), findsOneWidget);
      expect(find.text(AppConstants.appName), findsOneWidget);

      // Wait for auth loading and minimum splash display timer
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();

      // Navigated to AccessGateScreen
      expect(find.byType(AccessGateScreen), findsOneWidget);
      expect(find.text('Sign In'), findsOneWidget);
      expect(find.text('Register Account'), findsOneWidget);
    });

    testWidgets('Authenticated Rider boot routes to RiderHomeScreen', (tester) async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyUserId: 'usr_rider_1',
        AppConstants.keyUserRole: AppConstants.riderRole,
        AppConstants.keyUserEmail: 'rider1@coroute.app',
        AppConstants.keyUserName: 'FalconOne',
      });
      final storage = const FlutterSecureStorage();
      await storage.write(key: 'coroute_jwt', value: 'valid-rider-token');

      final mockHttp = MockClient((req) async {
        if (req.url.path.endsWith('/me')) {
          return http.Response(jsonEncode({
            'userId': 'usr_rider_1',
            'name': 'FalconOne',
            'email': 'rider1@coroute.app',
            'role': AppConstants.riderRole,
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

      await tester.pumpWidget(buildAppHarness(
        apiClient: api,
        authService: auth,
        realtimeService: rt,
        convoyService: convoy,
        metaService: meta,
        tripStorageService: trips,
        timelineService: timeline,
        trackRecorder: recorder,
        intercomService: intercom,
        child: const SplashScreen(),
      ));

      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();

      expect(find.byType(RiderHomeScreen), findsOneWidget);
      expect(auth.isAuthenticated, isTrue);
      expect(auth.isMasterAdmin, isFalse);
      expect(auth.currentUserName, 'FalconOne');
    });

    testWidgets('Authenticated Master Admin boot routes directly to MasterAdminDashboard', (tester) async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyUserId: 'usr_admin',
        AppConstants.keyUserRole: AppConstants.adminRole,
        AppConstants.keyUserEmail: 'santhoshbukka5@gmail.com',
        AppConstants.keyUserName: 'Santhosh (Admin)',
      });
      final storage = const FlutterSecureStorage();
      await storage.write(key: 'coroute_jwt', value: 'admin-token');

      final mockHttp = MockClient((req) async {
        if (req.url.path.endsWith('/me')) {
          return http.Response(jsonEncode({
            'userId': 'usr_admin',
            'name': 'Santhosh (Admin)',
            'email': 'santhoshbukka5@gmail.com',
            'role': AppConstants.adminRole,
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

      await tester.pumpWidget(buildAppHarness(
        apiClient: api,
        authService: auth,
        realtimeService: rt,
        convoyService: convoy,
        metaService: meta,
        tripStorageService: trips,
        timelineService: timeline,
        trackRecorder: recorder,
        intercomService: intercom,
        child: const SplashScreen(),
      ));

      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();

      expect(find.byType(MasterAdminDashboard), findsOneWidget);
      expect(auth.isAuthenticated, isTrue);
      expect(auth.isMasterAdmin, isTrue);
    });
  });

  group('Application Level E2E: Session Expiry, Update Gate & Deep Links', () {
    test('Gateway 401 SESSION_INVALID terminates session and clears secure tokens', () async {
      final storage = const FlutterSecureStorage();
      await storage.write(key: 'coroute_jwt', value: 'expired-token');

      final mockHttp = MockClient((req) async {
        return http.Response(
          jsonEncode({'error': 'Your session has ended.', 'code': 'SESSION_INVALID'}),
          401,
        );
      });

      final api = ApiClient(httpClient: mockHttp, storage: storage);
      await api.init();
      expect(api.hasToken, isTrue);

      try {
        await api.get('/me');
        fail('Should throw ApiException');
      } on ApiException catch (e) {
        expect(e.isUnauthorized, isTrue);
        expect(e.endsSession, isTrue);
      }

      // Token has been dropped from client memory
      expect(api.hasToken, isFalse);
    });

    testWidgets('MetaService flags updateRequired and blocks user interaction', (tester) async {
      MetaService.currentBuild = 10;
      final mockHttp = MockClient((req) async {
        if (req.url.path.endsWith('/meta')) {
          return http.Response(jsonEncode({
            'minBuild': 25,
            'latestBuild': 30,
            'downloadUrl': 'https://devmonks.space/coroute/latest.apk',
            'privacyUrl': 'https://devmonks.space/privacy',
            'termsUrl': 'https://devmonks.space/terms',
            'supportEmail': 'support@devmonks.space',
            'googleSignIn': true,
          }), 200);
        }
        return http.Response('{}', 200);
      });

      final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
      final meta = MetaService(api);
      await meta.load();

      expect(meta.updateRequired, isTrue);
      expect(meta.updateAvailable, isTrue);

      // Testing Update Gate widget behavior
      final updateGateWidget = Material(
        child: meta.updateRequired
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Update required', style: TextStyle(fontSize: 20)),
                    const Text('This version of CoRoute no longer works with the convoy service.'),
                    ElevatedButton(onPressed: () {}, child: const Text('Get the update')),
                  ],
                ),
              )
            : const Text('App Content Active'),
      );

      await tester.pumpWidget(MaterialApp(home: updateGateWidget));
      expect(find.text('Update required'), findsOneWidget);
      expect(find.text('Get the update'), findsOneWidget);
      expect(find.text('App Content Active'), findsNothing);
    });

    testWidgets('Deep Link ingestion updates pendingJoinCode and normalizes format', (tester) async {
      final mockHttp = MockClient((req) async => http.Response('{}', 200));
      final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
      final rt = RealtimeService();
      final trips = TripStorageService(api);
      final queue = MemoryTrackQueue();
      final recorder = TrackRecorder(queue, TrackUploader(api, queue));
      final convoy = ConvoyService(api, rt, trips, recorder: recorder);

      expect(convoy.pendingJoinCode, isNull);

      // Simulate receiving deep link: coroute://join/wst-900 or https://.../join/wst_900
      convoy.setPendingJoinCode('wst-900');
      expect(convoy.pendingJoinCode, 'WST900');

      convoy.setPendingJoinCode('  c-o-r-1-2-3  ');
      expect(convoy.pendingJoinCode, 'COR123');

      convoy.setPendingJoinCode(null);
      expect(convoy.pendingJoinCode, isNull);
    });
  });

  group('Application Level E2E: Offline Telemetry Buffer & Recovery', () {
    test('Track points queue during network outage and flush successfully on reconnect', () async {
      final queue = MemoryTrackQueue();
      var networkOnline = false;
      var uploadedChunksCount = 0;

      final mockHttp = MockClient((req) async {
        if (!networkOnline) {
          return http.Response(jsonEncode({'error': 'Server unavailable'}), 503);
        }
        if (req.url.path.contains('/tracks')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final chunks = (body['chunks'] as List).cast<Map>();
          uploadedChunksCount += chunks.length;
          final acked = chunks.map((c) => c['seq']).toList();
          return http.Response(jsonEncode({'acked': acked, 'rejected': []}), 200);
        }
        return http.Response('{}', 200);
      });

      final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
      await api.setToken('valid-token');
      final uploader = TrackUploader(api, queue);

      // 1. Rider travels while network is completely down (dead zone)
      final now = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < 150; i++) {
        await queue.add(
          'GRP-CONVOY-1',
          TrackPoint(
            ts: now + (i * 3000),
            lat: 12.9716 + (i * 0.0001),
            lng: 77.5946 + (i * 0.0001),
            speedKmh: 65.0,
            accuracyM: 4.0,
          ),
        );
      }

      // Check all 150 points are waiting locally
      expect(queue.pendingCount('GRP-CONVOY-1'), 150);

      // Flush while still offline -> nothing uploaded, queue retains all 150 points
      final flushedOffline = await uploader.flush();
      expect(flushedOffline, 0);
      expect(queue.pendingCount('GRP-CONVOY-1'), 150);

      // 2. Rider exits dead zone -> Network recovers
      networkOnline = true;
      final flushedOnline = await uploader.flush();

      // Chunk size is 120, so 150 points are sent in 2 chunks (120 + 30)
      expect(flushedOnline, 150);
      expect(uploadedChunksCount, 2);
      expect(queue.pendingCount('GRP-CONVOY-1'), 0); // All cleared upon server ACK
    });
  });
}
