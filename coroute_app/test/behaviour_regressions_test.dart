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
import 'package:coroute_app/presentation/rider/rider_home_screen.dart';

/// 3.12 behaviour regressions found by the adversarial review (TEST_BEHAVIOUR.md).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpShell(WidgetTester tester) async {
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
    FlutterSecureStorage.setMockInitialValues({});
    final mockHttp = MockClient((req) async {
      if (req.url.path.endsWith('/convoys/active')) return http.Response(jsonEncode({'convoy': null}), 200);
      return http.Response('{}', 200);
    });
    final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
    final auth = AuthService(api);
    final rt = RealtimeService();
    final trips = TripStorageService(api);
    final timeline = TimelineService(api, rt);
    final queue = MemoryTrackQueue();
    final recorder = TrackRecorder(queue, TrackUploader(api, queue));
    final convoy = ConvoyService(api, rt, trips, recorder: recorder, timeline: timeline);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeController>.value(value: ThemeController()),
        ChangeNotifierProvider<ApiClient>.value(value: api),
        ChangeNotifierProvider<RealtimeService>.value(value: rt),
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider<MetaService>.value(value: MetaService(api)),
        ChangeNotifierProvider<TripStorageService>.value(value: trips),
        ChangeNotifierProvider<TimelineService>.value(value: timeline),
        ChangeNotifierProvider<ConvoyService>.value(value: convoy),
        ChangeNotifierProvider<IntercomService>.value(value: IntercomService(rt)),
        Provider<AlertService>(create: (_) => AlertService(convoy, timeline), dispose: (_, a) => a.dispose()),
      ],
      child: MaterialApp(
        theme: AppTheme.themeFor(AppPalette.dark),
        home: const RiderHomeScreen(),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('Android back on another tab returns to the Ride tab instead of leaving the app', (tester) async {
    await pumpShell(tester);
    expect(find.text('No active ride'), findsOneWidget);

    await tester.tap(find.widgetWithText(NavigationDestination, 'Profile'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, HomeTab.profile.index);

    // System back: the shell handles it (the route is not popped) and shows Ride again.
    final handled = await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 300));
    expect(handled, isTrue);
    expect(find.byType(RiderHomeScreen), findsOneWidget);
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, HomeTab.ride.index);
  });

  testWidgets('Without a ride, back on the Ride tab may leave the app (PopScope allows the pop)', (tester) async {
    await pumpShell(tester);
    final finder = find.descendant(of: find.byType(RiderHomeScreen), matching: find.byWidgetPredicate((w) => w is PopScope));
    final scope = tester.widget(finder.first) as PopScope;
    expect(scope.canPop, isTrue);
  });
}
