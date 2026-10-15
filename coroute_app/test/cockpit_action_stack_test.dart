import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/route_essential.dart';
import 'package:coroute_app/data/models/stop_point_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/route_essentials_service.dart';
import 'package:coroute_app/presentation/rider/widgets/cockpit_action_stack.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final me = RiderModel(
    userId: 'user_me',
    name: 'Me',
    lat: 12.9716,
    lng: 77.5946,
    lastSeenEpochMs: 1000,
  );

  group('CockpitActionStack Tests', () {
    testWidgets('High fuel range (600km) suppresses proactive NEXT FUEL in 150m card', (tester) async {
      final client = MockClient((request) async => http.Response('{}', 200));
      final api = ApiClient(httpClient: client);
      final essentialsService = RouteEssentialsService(api);

      // Inject a fuel station 150m ahead
      essentialsService.snapshot = EssentialsSnapshot(
        category: 'FUEL',
        routeKey: 'route_blr',
        attribution: 'OSM',
        fromM: 0,
        toM: 50000,
        fetchedAt: 1000,
        complete: true,
        stale: false,
        places: [
          RouteEssential(
            placeId: 'st_1',
            visitId: 'v_1',
            name: 'Shell Petrol Pump',
            category: 'FUEL',
            source: 'OSM',
            lat: 12.9720,
            lng: 77.5950,
            routePositionM: 150,
            entryM: 140,
            exitM: 160,
            accessDistanceM: 10,
            detourDistanceM: 20,
            detourDurationS: 30,
          ),
        ],
      );

      final convoy = ConvoyModel(
        groupId: 'grp_1',
        name: 'Bangalore Riders',
        joinCode: 'BLR01',
        createdByUserId: 'user_me',
        createdByUserName: 'Me',
        createdAtEpochMs: 1000,
        riders: {'user_me': me},
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CockpitActionStack(
              convoy: convoy,
              me: me,
              essentialsService: essentialsService,
              estimatedUsableKm: 600.0, // Plenty of fuel!
              isLead: true,
            ),
          ),
        ),
      );

      await tester.pump();

      // Ensure the unsolicited "NEXT FUEL in 150 m" pill is NOT displayed
      expect(find.textContaining('NEXT FUEL'), findsNothing);
      expect(find.textContaining('LOW FUEL'), findsNothing);

      // Verify the dedicated right-side fuel button shows 600 km
      expect(find.textContaining('600 km'), findsOneWidget);
    });

    testWidgets('Low fuel (<= 60km) displays urgent LOW FUEL card and indicates LOW on button', (tester) async {
      final client = MockClient((request) async => http.Response('{}', 200));
      final api = ApiClient(httpClient: client);
      final essentialsService = RouteEssentialsService(api);

      essentialsService.snapshot = EssentialsSnapshot(
        category: 'FUEL',
        routeKey: 'route_blr',
        attribution: 'OSM',
        fromM: 0,
        toM: 50000,
        fetchedAt: 1000,
        complete: true,
        stale: false,
        places: [
          RouteEssential(
            placeId: 'st_1',
            visitId: 'v_1',
            name: 'IndianOil',
            category: 'FUEL',
            source: 'OSM',
            lat: 12.9750,
            lng: 77.5980,
            routePositionM: 1200,
            entryM: 1100,
            exitM: 1300,
            accessDistanceM: 10,
            detourDistanceM: 20,
            detourDurationS: 30,
          ),
        ],
      );

      final convoy = ConvoyModel(
        groupId: 'grp_1',
        name: 'Bangalore Riders',
        joinCode: 'BLR01',
        createdByUserId: 'user_me',
        createdByUserName: 'Me',
        createdAtEpochMs: 1000,
        riders: {'user_me': me},
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CockpitActionStack(
              convoy: convoy,
              me: me,
              essentialsService: essentialsService,
              estimatedUsableKm: 42.0, // Low fuel!
              isLead: true,
            ),
          ),
        ),
      );

      await tester.pump();

      // Verify urgent low fuel alert card is displayed
      expect(find.textContaining('LOW FUEL · 42 km left'), findsOneWidget);
      expect(find.textContaining('IndianOil'), findsOneWidget);

      // Verify side button indicates LOW
      expect(find.textContaining('LOW (42 km)'), findsOneWidget);
    });

    testWidgets('Multiple stop suggestions from teammates stack line-by-line one on another', (tester) async {
      final convoy = ConvoyModel(
        groupId: 'grp_1',
        name: 'Bangalore Riders',
        joinCode: 'BLR01',
        createdByUserId: 'user_me',
        createdByUserName: 'Me',
        createdAtEpochMs: 1000,
        riders: {'user_me': me},
        stopPoints: [
          StopPointModel(
            stopId: 'stop_food',
            name: 'Royal Dhaba',
            category: 'FOOD',
            status: 'SUGGESTED',
            lat: 13.0000,
            lng: 77.6000,
            suggestedBy: 'user_rahul',
            suggestedByName: 'Rahul Sharma',
          ),
          StopPointModel(
            stopId: 'stop_coffee',
            name: 'Highway Chai',
            category: 'COFFEE',
            status: 'SUGGESTED',
            lat: 13.0100,
            lng: 77.6100,
            suggestedBy: 'user_kiran',
            suggestedByName: 'Kiran V',
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CockpitActionStack(
              convoy: convoy,
              me: me,
              estimatedUsableKm: 550.0,
              isLead: true,
            ),
          ),
        ),
      );

      await tester.pump();

      // Verify both stop suggestions stack line-by-line
      expect(find.textContaining('Rahul: Royal Dhaba'), findsOneWidget);
      expect(find.textContaining('FOOD stop suggested'), findsOneWidget);

      expect(find.textContaining('Kiran: Highway Chai'), findsOneWidget);
      expect(find.textContaining('COFFEE stop suggested'), findsOneWidget);

      // Verify side fuel button is also present at bottom
      expect(find.textContaining('550 km'), findsOneWidget);
    });
  });
}
