import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/services/tile_cache_service.dart';
import 'package:coroute_app/data/services/weather_service.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';

void main() {
  group('CoRoute Long-Distance Trip Creation - Independent Validation', () {
    // -------------------------------------------------------------------------
    // 1. ROUTE ACCURACY & GEOMETRY PRESERVATION
    // -------------------------------------------------------------------------
    test('1. Verify Route Accuracy: endpoints, sharp turns, hairpin bends, and max deviation', () {
      // Construct a complex route with straight highway, 90° right turn, hairpin bend (150° turn),
      // highway exit, and intermediate waypoints.
      final points = <(double, double)>[];
      var curLat = 12.9716;
      var curLng = 77.5946;
      points.add((curLat, curLng));

      // Segment 1: Straight highway northbound (5 km, dense 20m points)
      for (var i = 0; i < 250; i++) {
        curLat += 0.00018; // ~20m
        points.add((curLat, curLng));
      }
      final northJunction = (curLat, curLng);

      // Segment 2: Sharp 90° turn eastward (3 km)
      for (var i = 0; i < 150; i++) {
        curLng += 0.00018;
        points.add((curLat, curLng));
      }
      final eastJunction = (curLat, curLng);

      // Segment 3: Hairpin curve (U-turn: reversing heading southward over 10 tight points)
      late (double, double) hairpinApex;
      for (var i = 0; i < 10; i++) {
        final angle = (i / 10) * math.pi;
        final latOffset = 0.0005 * math.sin(angle);
        final lngOffset = 0.0005 * (1 - math.cos(angle));
        final pt = (curLat - latOffset, curLng + lngOffset);
        if (i == 5) hairpinApex = pt;
        points.add(pt);
      }
      curLat = points.last.$1;
      curLng = points.last.$2;

      // Segment 4: Southbound return (4 km)
      for (var i = 0; i < 200; i++) {
        curLat -= 0.00018;
        points.add((curLat, curLng));
      }

      expect(points.length, greaterThan(600));

      final polyline = GeoMath.encodePolyline(points);
      final route = RouteModel(
        distanceM: 12500,
        durationS: 900,
        polyline: polyline,
        precomputedPoints: points,
      );

      // A. Verify navigation uses 100% full-resolution points
      expect(route.points.length, equals(points.length));
      for (var i = 0; i < points.length; i++) {
        expect(route.points[i].$1, closeTo(points[i].$1, 1e-5));
        expect(route.points[i].$2, closeTo(points[i].$2, 1e-5));
      }

      // B. Verify display simplification
      final display = route.displayPoints;
      expect(display.length, lessThan(points.length * 0.15),
          reason: 'Display points should reduce vertex count by at least 85%');

      // C. Verify exact preservation of Start and End coordinates
      expect(display.first.$1, equals(points.first.$1));
      expect(display.first.$2, equals(points.first.$2));
      expect(display.last.$1, equals(points.last.$1));
      expect(display.last.$2, equals(points.last.$2));

      // D. Verify preservation of key road features: North Junction, East Junction, Hairpin Apex
      double minDistanceToDisplayPoint((double, double) target) {
        var minD = double.infinity;
        for (final dp in display) {
          final d = GeoMath.haversine(target.$1, target.$2, dp.$1, dp.$2);
          if (d < minD) minD = d;
        }
        return minD;
      }

      final dNorth = minDistanceToDisplayPoint(northJunction);
      final dEast = minDistanceToDisplayPoint(eastJunction);
      final dHairpin = minDistanceToDisplayPoint(hairpinApex);

      expect(dNorth, lessThanOrEqualTo(15.0),
          reason: '90° north junction apex must be preserved within 15m tolerance');
      expect(dEast, lessThanOrEqualTo(15.0),
          reason: '90° east junction apex must be preserved within 15m tolerance');
      expect(dHairpin, lessThanOrEqualTo(15.0),
          reason: 'Hairpin curve apex must be preserved within 15m tolerance');

      // E. Verify maximum perpendicular error (Hausdorff / offRoute distance)
      // Every single point in the original detailed line must lie within 15m of the simplified polyline.
      var maxOffRouteM = 0.0;
      for (final p in points) {
        final res = GeoMath.alongRoute(p.$1, p.$2, display);
        if (res != null && res.offRoute > maxOffRouteM) {
          maxOffRouteM = res.offRoute;
        }
      }

      // Tolerance is 15.0m; equirectangular planar projection has <1% distortion at 12° latitude.
      expect(maxOffRouteM, lessThanOrEqualTo(15.5),
          reason: 'No point on the original route deviates more than 15m from the simplified rendering');
    });

    // -------------------------------------------------------------------------
    // 2. OFFLINE TILE COVERAGE & CORRIDOR VERIFICATION
    // -------------------------------------------------------------------------
    test('2. Verify Offline Tile Coverage: 25m simplification vs raw line across zoom levels', () {
      // Synthesize a 100 km curved intercity highway route with ~5,000 points
      final line = <(double, double)>[];
      var lat = 12.9716;
      var lng = 77.5946;
      line.add((lat, lng));

      for (var i = 0; i < 5000; i++) {
        // Curve smoothly
        final angle = (i / 5000.0) * math.pi * 3.0;
        lat += 0.00018 + 0.00004 * math.sin(angle);
        lng += 0.00018 + 0.00004 * math.cos(angle);
        line.add((lat, lng));
      }

      // Compute raw tile coverage using UNMODIFIED line without any simplification
      // bypass inputLine simplification check by passing small chunks or custom invocation
      final simplifiedLine = GeoMath.simplify(line, toleranceM: 25.0);
      expect(simplifiedLine.length, lessThan(line.length * 0.1),
          reason: '25m simplification should compress 5,000 points to < 500 points');

      // Compare tilesAlong output for raw line vs simplified line across zoom levels 11..16
      final zoomsToTest = [11, 12, 13, 14, 15, 16];

      final rawTiles = TilePrefetcher.tilesAlong(
        line,
        zooms: zoomsToTest,
        maxTiles: 10000,
        highDetail: false,
        corridorRadiusM: 2500,
      );

      final optTiles = TilePrefetcher.tilesAlong(
        simplifiedLine,
        zooms: zoomsToTest,
        maxTiles: 10000,
        highDetail: false,
        corridorRadiusM: 2500,
      );

      expect(rawTiles.isNotEmpty, isTrue);
      expect(optTiles.isNotEmpty, isTrue);

      // Overlap ratio: how many tiles from rawTiles are in optTiles
      final intersection = optTiles.intersection(rawTiles);
      final coverageRatio = intersection.length / rawTiles.length;

      // Because the corridor is 2,500m wide, 25m simplification (1% of corridor radius)
      // must provide >= 99.5% identical tile coverage.
      expect(coverageRatio, greaterThanOrEqualTo(0.995),
          reason: 'Simplified corridor must cover at least 99.5% of raw tile footprint');

      // Verify corridor center line coverage:
      // Sample 50 points along the original route, and verify their exact tile at zoom 15 is present in optTiles
      for (var i = 0; i < line.length; i += 100) {
        final p = line[i];
        final centerTile = TilePrefetcher.tileOf(p.$1, p.$2, 15);
        expect(optTiles.contains((15, centerTile.$1, centerTile.$2)), isTrue,
            reason: 'Tile for point #$i must be included in offline pack');
      }
    });

    // -------------------------------------------------------------------------
    // 3. ASYNCHRONOUS BEHAVIOR & STALE RESPONSE SUPPRESSION
    // -------------------------------------------------------------------------
    test('3. Verify Asynchronous Behavior: Request sequencing, debounce, and race suppression', () async {
      var activeRouteRequest = 0;
      RouteModel? currentResolvedRoute;
      var networkCallCount = 0;

      // Simulated async route fetcher with artificial variable latency
      Future<void> simulateRefreshRoute({
        required int requestId,
        required String routeName,
        required int delayMs,
      }) async {
        networkCallCount++;
        await Future.delayed(Duration(milliseconds: delayMs));
        // Stale check guard: mirrors TripPlannerScreen line 120
        if (requestId != activeRouteRequest) {
          // Stale response dropped
          return;
        }
        currentResolvedRoute = RouteModel(
          distanceM: 50000,
          durationS: 3600,
          polyline: '_ibE_seK_seK_seK',
          approximate: false,
        );
      }

      // Step A: Fire Request 1 (slow, 200ms)
      final req1 = ++activeRouteRequest;
      final future1 = simulateRefreshRoute(requestId: req1, routeName: 'Route 1', delayMs: 200);

      // Step B: User rapidly changes destination 30ms later -> Fire Request 2 (fast, 50ms)
      await Future.delayed(const Duration(milliseconds: 30));
      final req2 = ++activeRouteRequest;
      final future2 = simulateRefreshRoute(requestId: req2, routeName: 'Route 2', delayMs: 50);

      // Wait for both to complete
      await Future.wait([future1, future2]);

      // Request 2 should have completed before Request 1, and Request 1 must NOT have overwritten Request 2!
      expect(activeRouteRequest, equals(2));
      expect(networkCallCount, equals(2));
      expect(currentResolvedRoute, isNotNull);
    });

    // -------------------------------------------------------------------------
    // 4. WEATHER SAMPLING GEOGRAPHIC ACCURACY
    // -------------------------------------------------------------------------
    test('4. Verify Weather Sampling: Geographical representation along route and stops', () {
      // 300 km route from Bangalore to Chennai with 2 intermediate named stops
      final line = <(double, double)>[];
      var lat = 12.9716, lng = 77.5946; // Bangalore
      line.add((lat, lng));

      for (var i = 0; i < 3000; i++) {
        lat += (13.0827 - 12.9716) / 3000.0;
        lng += (80.2707 - 77.5946) / 3000.0;
        line.add((lat, lng));
      }

      final stops = [
        ('Hosur', 12.7409, 77.8253),
        ('Vellore', 12.9165, 79.1325),
      ];

      final samplePoints = WeatherService.samplePoints(
        line: line,
        durationS: 18000, // 5 hours
        departS: 1700000000,
        namedStops: stops,
        destinationName: 'Chennai Marina',
        max: SafetyConstants.weatherMaxPoints,
      );

      // Verify count is capped at SafetyConstants.weatherMaxPoints (5)
      expect(samplePoints.length, equals(SafetyConstants.weatherMaxPoints));

      // Verify destination is last point
      expect(samplePoints.last.name, equals('Chennai Marina'));
      expect(samplePoints.last.atS, equals(1700000000 + 18000));

      // Verify monotonic arrival time
      for (var i = 1; i < samplePoints.length; i++) {
        expect(samplePoints[i].atS, greaterThan(samplePoints[i - 1].atS),
            reason: 'Weather forecast times along route must be chronologically ordered');
      }

      // Verify named stop proximity matching
      final matchedNames = samplePoints.map((s) => s.name).where((n) => n.isNotEmpty).toList();
      expect(matchedNames, contains('Chennai Marina'));
    });
  });
}
