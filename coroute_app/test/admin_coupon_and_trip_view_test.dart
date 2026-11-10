import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/trip_history_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/rider/trip_history_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => AppTheme.use(AppPalette.dark));

  group('Trip History View-Only Integrity', () {
    testWidgets('renders trips as view-only and contains NO delete options', (tester) async {
      final mockHttp = MockClient((req) async => http.Response('{}', 200, headers: {'content-type': 'application/json'}));
      final apiClient = ApiClient(httpClient: mockHttp);
      final authService = AuthService(apiClient);
      final tripStorage = TripStorageService(apiClient);

      final dummyTrip = TripHistoryModel(
        tripId: 'trip_view_only_123',
        tripName: 'Morning Ride to Nandi Hills',
        startTimeEpochMs: DateTime.now().subtract(const Duration(hours: 3)).millisecondsSinceEpoch,
        endTimeEpochMs: DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
        totalDistanceKm: 65.4,
        avgSpeedKmh: 42.0,
        topSpeedKmh: 78.0,
        riderCount: 4,
        breadcrumbTrail: const [],
      );

      await tripStorage.saveTrip(dummyTrip);

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ApiClient>.value(value: apiClient),
              ChangeNotifierProvider<AuthService>.value(value: authService),
              ChangeNotifierProvider<TripStorageService>.value(value: tripStorage),
            ],
            child: const TripHistoryScreen(embedded: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Trip is rendered
      expect(find.text('Morning Ride to Nandi Hills'), findsOneWidget);

      // CRITICAL SAFETY REQUIREMENT: NO Delete trip option exists for users
      expect(find.text('Delete trip'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);

      // View chevron affordance is present
      expect(find.byIcon(Icons.arrow_forward_ios_rounded), findsOneWidget);
    });
  });
}
