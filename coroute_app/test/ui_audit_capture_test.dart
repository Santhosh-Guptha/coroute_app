import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
import 'package:coroute_app/presentation/splash/splash_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() => AppTheme.use(AppPalette.dark));

  testWidgets('Capture test verifying mock harness and PNG output', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final storage = const FlutterSecureStorage();
    final mockHttp = MockClient((req) async {
      return http.Response(jsonEncode({'status': 'ok'}), 200);
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

    final key = GlobalKey();

    await tester.pumpWidget(
      MultiProvider(
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
        child: RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.themeFor(AppPalette.dark),
            home: const SplashScreen(),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 100));

    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData!.buffer.asUint8List();

      final file = File('../docs/ui-audit/screenshots/01_app_entry/SCR-001_splash_initial.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
    });

    await tester.pumpAndSettle();

    final file = File('../docs/ui-audit/screenshots/01_app_entry/SCR-001_splash_initial.png');
    expect(file.existsSync(), isTrue);
    debugPrint('AUDIT_CAPTURE_TEST_SUCCESS: ${file.path} (${file.lengthSync()} bytes)');
  });
}
