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
import 'package:coroute_app/data/models/trip_history_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/report/trip_report_screen.dart';
import 'package:coroute_app/presentation/rider/trip_history_screen.dart';

const int t0 = 1800000000000;
const int min = 60000;

Map<String, dynamic> tripJson() => {
      'tripId': 'T1',
      'tripName': 'Hyderabad to Srisailam',
      'startLocationName': 'Gachibowli',
      'destinationName': 'Srisailam',
      'groupId': 'GRP-1',
      'source': 'server',
      'startTimeEpochMs': t0,
      'endTimeEpochMs': t0 + 240 * min,
      'totalDistanceKm': 142.0,
      'topSpeedKmh': 96.0,
      'avgSpeedKmh': 45.0,
      'riderCount': 3,
      'stopCount': 2,
      'movingMs': 190 * min,
      'restMs': 50 * min,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  Widget harness({required ApiClient api, required TripStorageService trips, required Widget child, double textScale = 1.0}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeController>.value(value: ThemeController()),
        ChangeNotifierProvider<ApiClient>.value(value: api),
        ChangeNotifierProvider<AuthService>.value(value: AuthService(api)),
        ChangeNotifierProvider<TripStorageService>.value(value: trips),
      ],
      child: MaterialApp(
        theme: AppTheme.themeFor(AppPalette.dark),
        builder: (context, c) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: c!,
        ),
        home: child,
      ),
    );
  }

  ApiClient apiReturning(Map<String, dynamic> body) =>
      ApiClient(httpClient: MockClient((req) async => http.Response(jsonEncode(body), 200)), storage: const FlutterSecureStorage());

  group('Trips tab', () {
    testWidgets('no trips: guides to start a ride, no back button when embedded', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final api = apiReturning({});
      final trips = TripStorageService(api);
      await tester.pumpWidget(harness(api: api, trips: trips, child: const TripHistoryScreen(embedded: true)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('No trips yet'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Start Ride'), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      expect(find.byTooltip('Sync with cloud'), findsNothing, reason: 'pull to refresh only');
    });

    testWidgets('one clean row per trip with totals on top, delete asks first (320 dp, text x1.3)', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      SharedPreferences.setMockInitialValues({AppConstants.keyTripHistory: jsonEncode([tripJson()])});
      final api = apiReturning({});
      final trips = TripStorageService(api);
      await tester.pumpWidget(harness(api: api, trips: trips, textScale: 1.3, child: const TripHistoryScreen(embedded: true)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
      expect(find.text('Trips'), findsOneWidget);
      expect(find.text('Hyderabad to Srisailam'), findsOneWidget);
      expect(find.text('142 km · 3 h 10 min riding'), findsOneWidget);
      expect(find.text('Ride'), findsOneWidget);
      expect(find.text('Riding time'), findsOneWidget);
      // No five-colour stat wrap any more.
      expect(find.text('Top speed'), findsNothing);

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete trip'));
      await tester.pumpAndSettle();
      expect(find.text('Delete trip?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Hyderabad to Srisailam'), findsOneWidget);
      await tester.binding.setSurfaceSize(null);
    });
  });

  group('Trip report', () {
    testWidgets('key stats show at once from the saved trip, no blocking spinner, two tabs', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 760));
      SharedPreferences.setMockInitialValues({});
      final api = apiReturning({'report': null, 'events': [], 'members': []});
      final trips = TripStorageService(api);
      await tester.pumpWidget(harness(api: api, trips: trips, child: TripReportScreen(trip: TripHistoryModel.fromJson(tripJson()))));

      // Before the report arrives.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Distance'), findsOneWidget);
      expect(find.text('142 km'), findsOneWidget);
      expect(find.text('Duration'), findsOneWidget);
      expect(find.text('4 h'), findsOneWidget);
      expect(find.text('Riding time'), findsOneWidget);
      expect(find.text('3 h 10 min'), findsOneWidget);
      expect(find.text('Rest time'), findsOneWidget);
      expect(find.text('50 min'), findsOneWidget);
      expect(find.text('Stops'), findsOneWidget);
      expect(find.text('Average speed'), findsOneWidget);
      expect(find.text('45 km/h'), findsOneWidget);
      expect(find.text('Longest stop'), findsOneWidget);
      expect(find.text('Summary'), findsOneWidget);
      expect(find.text('Route'), findsOneWidget);
      expect(find.text('Timeline'), findsNothing);
      // The rest waits behind "More details".
      expect(find.text('More details'), findsOneWidget);
      expect(find.text('Top speed'), findsNothing);

      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('More details'));
      await tester.pumpAndSettle();
      expect(find.text('Top speed'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
    });
  });
}
