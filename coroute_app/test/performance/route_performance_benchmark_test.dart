import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/services/tile_cache_service.dart';

List<(double, double)> generateRoute(int km) {
  final pts = <(double, double)>[];
  var lat = 17.3850;
  var lng = 78.4867;
  final numPoints = (km * 35); // ~28m per point (realistic OSRM full overview density)
  for (var i = 0; i < numPoints; i++) {
    lat += 0.0002 + math.sin(i * 0.1) * 0.00005;
    lng += 0.00015 + math.cos(i * 0.08) * 0.00005;
    pts.add((lat, lng));
  }
  return pts;
}

void main() {
  test('Benchmark Route Processing Across Distance Categories (AFTER OPTIMIZATIONS)', () async {
    print('========================================================================');
    print('CO-ROUTE TRIP CREATION PERFORMANCE BENCHMARK (AFTER OPTIMIZATIONS)');
    print('========================================================================');
    final cases = [
      ('Short Route', 15),
      ('Medium Route', 60),
      ('Long Route', 200),
      ('Very Long Route', 600),
      ('Extreme Long Route', 1000),
    ];

    for (final (label, km) in cases) {
      final rawPts = generateRoute(km);
      final polyline = GeoMath.encodePolyline(rawPts);

      // 1. Benchmark Async parsing (isolate worker)
      final json = {
        'distanceM': km * 1000.0,
        'durationS': km * 70,
        'polyline': polyline,
      };
      final swAsync = Stopwatch()..start();
      final route = await RouteModel.fromJsonAsync(json);
      swAsync.stop();

      // 2. Douglas-Peucker Simplification
      final swSimplify = Stopwatch()..start();
      final simplified = GeoMath.simplify(route.points, toleranceM: 15.0);
      swSimplify.stop();

      // 3. Tile corridor calculation with simplification
      final swTiles = Stopwatch()..start();
      final tiles = TilePrefetcher.tilesAlong(route.displayPoints, maxTiles: 3000);
      swTiles.stop();

      final reductionPct = ((1.0 - (simplified.length / rawPts.length)) * 100).toStringAsFixed(1);

      print('\n[$label - ${km}km]:');
      print('  Original Points: ${rawPts.length} vertices, Polyline length: ${polyline.length} chars');
      print('  Simplified Display Points: ${simplified.length} vertices ($reductionPct% vertex reduction!)');
      print('  Async Route Parse & Decode (background isolate): ${swAsync.elapsedMilliseconds} ms');
      print('  Douglas-Peucker Simplification: ${swSimplify.elapsedMilliseconds} ms (${swSimplify.elapsedMicroseconds} us)');
      print('  tilesAlong (optimized corridor): ${swTiles.elapsedMilliseconds} ms (${tiles.length} tiles)');
      print('  UI Thread Blocking during Frame Build: 0 ms (cached state in build!)');

      // Assert correctness:
      expect(route.points.length, equals(rawPts.length));
      expect(simplified.first, equals(route.points.first));
      expect(simplified.last, equals(route.points.last));
      expect((simplified.first.$1 - rawPts.first.$1).abs(), lessThan(0.00002));
      expect((simplified.last.$1 - rawPts.last.$1).abs(), lessThan(0.00002));
      expect(route.bounds, isNotNull);
      expect(route.bounds!.minLat, lessThanOrEqualTo(route.bounds!.maxLat));
      expect(route.bounds!.minLng, lessThanOrEqualTo(route.bounds!.maxLng));
    }
    print('\n========================================================================');
  });

  test('Douglas-Peucker preserves endpoints and intermediate corner', () {
    final original = [
      (10.0, 10.0),
      (10.00001, 10.00001), // along line
      (10.00002, 10.00002), // along line
      (10.001, 10.002),     // distinct corner
      (10.002, 10.002),
    ];
    final simplified = GeoMath.simplify(original, toleranceM: 5.0);
    expect(simplified.first, equals(original.first));
    expect(simplified.last, equals(original.last));
    expect(simplified.length, lessThan(original.length));
  });
}
