import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/stop_point_model.dart';
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

class AuditEnvironment {
  final ApiClient api;
  final AuthService auth;
  final ConvoyService convoy;
  final RealtimeService rt;
  final TripStorageService trips;
  final TimelineService timeline;
  final MetaService meta;
  final SettingsService settings;
  final MembershipService membership;
  final ThemeController theme;

  AuditEnvironment({
    required this.api,
    required this.auth,
    required this.convoy,
    required this.rt,
    required this.trips,
    required this.timeline,
    required this.meta,
    required this.settings,
    required this.membership,
    required this.theme,
  });

  void dispose() {
    convoy.dispose();
  }

  static Future<AuditEnvironment> create({
    String role = AppConstants.riderRole,
    String userId = 'rider_dev_01',
    String userName = 'Santhosh Bukka',
    String userEmail = 'santhosh@coroute.in',
    bool isMasterAdmin = false,
  }) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/battery'), (call) async => 85);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/charging'), (call) async => 'discharging');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/permissions/methods'), (call) async => 1);

    FlutterError.onError = (FlutterErrorDetails details) {
      final msg = details.exceptionAsString();
      if (msg.contains('overflowed') || msg.contains('MissingPluginException')) return;
      FlutterError.presentError(details);
    };

    SharedPreferences.setMockInitialValues({
      AppConstants.keyUserId: userId,
      AppConstants.keyUserRole: isMasterAdmin ? AppConstants.adminRole : role,
      AppConstants.keyUserName: userName,
      AppConstants.keyUserEmail: userEmail,
      'user_callsign': 'RoadCaptain',
    });
    FlutterSecureStorage.setMockInitialValues({
      'coroute_jwt': 'mock_jwt_session_token_coroute',
    });

    final storage = const FlutterSecureStorage();
    final mockHttp = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/me')) {
        return http.Response(jsonEncode({
          'userId': userId,
          'role': isMasterAdmin ? AppConstants.adminRole : role,
          'name': userName,
          'email': userEmail,
          'callsign': 'RoadCaptain',
        }), 200);
      }
      if (p.contains('/membership')) {
        return http.Response(jsonEncode({
          'tier': 'pro',
          'status': 'active',
          'expiresAt': '2027-12-31T23:59:59Z',
        }), 200);
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

    return AuditEnvironment(
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
    );
  }
}

ConvoyModel createSampleConvoyModel() {
  final now = DateTime.now().millisecondsSinceEpoch;
  final r1 = RiderModel(
    userId: 'rider_dev_01',
    name: 'Santhosh Bukka',
    role: 'LEAD',
    speedKmh: 74.0,
    batteryLevel: 55,
    lat: 12.9716,
    lng: 77.5946,
    lastSeenEpochMs: now,
  );
  final r2 = RiderModel(
    userId: 'rider_dev_02',
    name: 'Asha Sharma',
    role: 'PACK',
    speedKmh: 72.5,
    batteryLevel: 88,
    lat: 12.9710,
    lng: 77.5940,
    lastSeenEpochMs: now,
  );
  final r3 = RiderModel(
    userId: 'rider_dev_03',
    name: 'Vikram Singh',
    role: 'PACK',
    speedKmh: 71.0,
    batteryLevel: 42,
    lat: 12.9702,
    lng: 77.5932,
    lastSeenEpochMs: now,
  );
  final r4 = RiderModel(
    userId: 'rider_dev_04',
    name: 'Rohan Mehta',
    role: 'SWEEP',
    speedKmh: 69.8,
    batteryLevel: 65,
    lat: 12.9690,
    lng: 77.5920,
    lastSeenEpochMs: now,
  );

  return ConvoyModel(
    groupId: 'trip_blr_goa_01',
    name: 'Bangalore to Goa Monsoon Run',
    joinCode: '650505',
    createdByUserId: 'rider_dev_01',
    createdByUserName: 'Santhosh Bukka',
    tripOwnerUserId: 'rider_dev_01',
    tripHeadUserId: 'rider_dev_01',
    startLocationName: 'Hebbal, Bangalore',
    destinationName: 'Panaji, Goa',
    destinationLat: 15.2993,
    destinationLng: 74.1240,
    tripStatus: 'STARTED',
    createdAtEpochMs: now - 3600000,
    speedLimitKmh: 80,
    riders: {
      'rider_dev_01': r1,
      'rider_dev_02': r2,
      'rider_dev_03': r3,
      'rider_dev_04': r4,
    },
    stopPoints: [
      StopPointModel(
        stopId: 'stop_1',
        name: 'Tumkur Fuel Stop',
        lat: 13.3409,
        lng: 77.1010,
        category: 'FUEL',
        orderIndex: 0,
      ),
      StopPointModel(
        stopId: 'stop_2',
        name: 'Chitradurga Breakfast Point',
        lat: 14.2251,
        lng: 76.4011,
        category: 'REST',
        orderIndex: 1,
      ),
    ],
  );
}

Future<void> renderAndSaveScreen({
  required WidgetTester tester,
  required AuditEnvironment env,
  required Widget widget,
  required String outputPath,
  Duration settleDuration = const Duration(milliseconds: 100),
  AppPalette palette = AppPalette.dark,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;

  final key = GlobalKey();

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ApiClient>.value(value: env.api),
        ChangeNotifierProvider<AuthService>.value(value: env.auth),
        ChangeNotifierProvider<ConvoyService>.value(value: env.convoy),
        ChangeNotifierProvider<RealtimeService>.value(value: env.rt),
        ChangeNotifierProvider<TripStorageService>.value(value: env.trips),
        ChangeNotifierProvider<TimelineService>.value(value: env.timeline),
        ChangeNotifierProvider<MetaService>.value(value: env.meta),
        ChangeNotifierProvider<SettingsService>.value(value: env.settings),
        ChangeNotifierProvider<MembershipService>.value(value: env.membership),
        ChangeNotifierProvider<ThemeController>.value(value: env.theme),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.themeFor(palette),
          home: Material(
            color: AppTheme.obsidianVoid,
            child: widget,
          ),
        ),
      ),
    ),
  );

  await tester.pump(settleDuration);

  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 3.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = byteData!.buffer.asUint8List();

    final file = File(outputPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  });

  await tester.pump();
}
