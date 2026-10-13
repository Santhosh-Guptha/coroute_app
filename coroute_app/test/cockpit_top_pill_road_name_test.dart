import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/domain/route/route_guide.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/presentation/rider/widgets/minimal_cockpit_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RouteStep & RouteModel Road Name Logic', () {
    test('RouteStep roadLabel formats correctly for various ref and name combinations', () {
      const step1 = RouteStep(
        name: 'Outer Ring Road',
        ref: 'NH 44',
        distanceM: 5000,
        startM: 0,
        endM: 5000,
      );
      expect(step1.roadLabel, 'NH 44 · Outer Ring Road');

      const step2 = RouteStep(
        name: 'National Highway 44',
        ref: 'NH 44',
        distanceM: 5000,
        startM: 5000,
        endM: 10000,
      );
      // When name already includes ref (case-insensitive), it should not duplicate
      expect(step2.roadLabel, 'National Highway 44');

      const stepRefOnly = RouteStep(
        name: '',
        ref: 'NH 44',
        distanceM: 3000,
        startM: 10000,
        endM: 13000,
      );
      expect(stepRefOnly.roadLabel, 'NH 44');

      const stepNameOnly = RouteStep(
        name: 'Airport Road',
        ref: '',
        distanceM: 4000,
        startM: 13000,
        endM: 17000,
      );
      expect(stepNameOnly.roadLabel, 'Airport Road');
    });

    test('RouteModel parses steps and locates active step by alongM', () {
      final json = {
        'distanceM': 25000,
        'durationS': 1800,
        'polyline': GeoMath.encodePolyline([(17.40, 78.40), (17.50, 78.50)]),
        'steps': [
          {'name': 'Inner Ring Road', 'ref': '', 'distanceM': 5000, 'durationS': 360},
          {'name': 'Hyderabad - Bangalore Hwy', 'ref': 'NH 44', 'distanceM': 15000, 'durationS': 1000},
          {'name': 'Airport Approach Rd', 'ref': 'SH 1', 'distanceM': 5000, 'durationS': 440},
        ],
      };

      final route = RouteModel.fromJson(json);
      expect(route.steps.length, 3);
      expect(route.steps[0].startM, 0.0);
      expect(route.steps[0].endM, 5000.0);
      expect(route.steps[1].startM, 5000.0);
      expect(route.steps[1].endM, 20000.0);
      expect(route.steps[2].startM, 20000.0);
      expect(route.steps[2].endM, 25000.0);

      // Lookup by distance along route
      expect(route.roadNameAt(2500), 'Inner Ring Road');
      expect(route.roadNameAt(10000), 'NH 44 · Hyderabad - Bangalore Hwy');
      expect(route.roadNameAt(22000), 'SH 1 · Airport Approach Rd');
    });
  });

  group('RouteGuide Live Road Name & Geocoding Fallback', () {
    test('extractRoadName helper cleans and formats highway and road labels', () {
      expect(RouteGuide.extractRoadName('NH44, Shamshabad, Hyderabad'), 'NH 44');
      expect(RouteGuide.extractRoadName('SH 17, Ramanagara'), 'SH 17');
      expect(RouteGuide.extractRoadName('Outer Ring Road, Marathahalli, Bengaluru'), 'Outer Ring Road');
      expect(RouteGuide.extractRoadName('MG Road'), 'MG Road');
      expect(RouteGuide.extractRoadName(''), '');
    });

    test('RouteGuide resolves current road name from active route steps', () {
      final line = [(17.40, 78.40), (17.45, 78.45), (17.50, 78.50)];
      final poly = GeoMath.encodePolyline(line);
      final route = RouteModel(
        distanceM: 20000,
        durationS: 1200,
        polyline: poly,
        steps: const [
          RouteStep(name: 'Outer Ring Road', ref: 'NH 44', distanceM: 10000, startM: 0, endM: 10000),
          RouteStep(name: 'Airport Road', ref: '', distanceM: 10000, startM: 10000, endM: 20000),
        ],
      );

      final guide = RouteGuide(fetchRoute: (wp) async => null);
      final convoy = ConvoyModel(
        groupId: 'test-group',
        name: 'Western Ghats Convoy',
        joinCode: 'WEST44',
        createdByUserId: 'lead_1',
        createdByUserName: 'Lead Rider',
        createdAtEpochMs: 1000,
        route: route,
        tripStatus: 'STARTED',
        destinationLat: 17.50,
        destinationLng: 78.50,
        destinationName: 'Airport',
      );

      guide.setConvoy(convoy, 'me');

      // Before fixing, if steps exist, it exposes the starting road
      expect(guide.currentRoadName, 'NH 44 · Outer Ring Road');

      // Fix on the first segment
      guide.onFix(
        lat: 17.40,
        lng: 78.40,
        speedKmh: 45,
        nowMs: 1000,
        online: true,
        lowData: false,
      );
      expect(guide.currentRoadName, 'NH 44 · Outer Ring Road');
    });

    test('RouteGuide falls back to reverse geocode when route has no steps', () async {
      String? queriedLat;
      final guide = RouteGuide(
        fetchRoute: (wp) async => null,
        reverseGeocode: (lat, lng) async {
          queriedLat = '$lat,$lng';
          return 'NH 44, Shamshabad';
        },
      );

      final convoy = ConvoyModel(
        groupId: 'test-group-2',
        name: 'City Commute',
        joinCode: 'CITY99',
        createdByUserId: 'lead_2',
        createdByUserName: 'City Lead',
        createdAtEpochMs: 1000,
        tripStatus: 'STARTED',
      );

      guide.setConvoy(convoy, 'me');
      expect(guide.currentRoadName, isNull);

      // Supply fix to trigger background reverse geocode
      guide.onFix(
        lat: 17.25,
        lng: 78.45,
        speedKmh: 50,
        nowMs: 20000,
        online: true,
        lowData: false,
      );

      // Wait a microtask for reverseGeocode async callback to resolve
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(queriedLat, '17.25,78.45');
      expect(guide.currentRoadName, 'NH 44');
    });
  });

  group('MinimalCockpitTopBar Widget Road Name Pill Tests', () {
    testWidgets('Renders highway badge and icon when roadName is provided', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: Center(
              child: MinimalCockpitTopBar(
                title: 'To Nandi Hills, 32 km',
                connection: null,
                gps: GpsState.accurate,
                subtitle: 'Bangalore Sunday Riders',
                roadName: 'NH 44',
                speedKmh: 75.0,
                speedLimitKmh: 80,
              ),
            ),
          ),
        ),
      );

      // Verify title and speed
      expect(find.text('To Nandi Hills, 32 km'), findsOneWidget);
      expect(find.text('75'), findsOneWidget);
      expect(find.text('KM/H'), findsOneWidget);

      // Verify live road badge
      expect(find.text('NH 44'), findsOneWidget);
      expect(find.byIcon(Icons.edit_road_rounded), findsOneWidget);

      // Verify subtitle is rendered alongside
      expect(find.text('Bangalore Sunday Riders'), findsOneWidget);
    });

    testWidgets('Renders subtitle cleanly without badge when roadName is null or empty', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: Center(
              child: MinimalCockpitTopBar(
                title: 'To Nandi Hills, 32 km',
                connection: null,
                gps: GpsState.accurate,
                subtitle: 'Bangalore Sunday Riders',
                roadName: null,
                speedKmh: 60.0,
              ),
            ),
          ),
        ),
      );

      expect(find.text('To Nandi Hills, 32 km'), findsOneWidget);
      expect(find.text('Bangalore Sunday Riders'), findsOneWidget);
      expect(find.byIcon(Icons.edit_road_rounded), findsNothing);
    });
  });
}
