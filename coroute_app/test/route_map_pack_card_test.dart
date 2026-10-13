import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/services/tile_cache_service.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/presentation/trip_planner/widgets/route_map_pack_card.dart';

Uint8List dummyBytes(int n) => Uint8List.fromList(List<int>.filled(n, 1));

List<(double, double)> testRoute(int km) => [
      for (var i = 0; i <= km; i++) (17.385 + i * 0.009, 78.4867),
    ];

class FakeTilePrefetcher extends TilePrefetcher {
  FakeTilePrefetcher({
    this.fakeRunning = false,
    this.fakeDone = 0,
    this.fakeTotal = 0,
    this.fakeError,
    this.fakeCached = false,
    this.fakeCachedCount = 0,
  }) : super(null);

  bool fakeRunning;
  int fakeDone;
  int fakeTotal;
  String? fakeError;
  bool fakeCached;
  int fakeCachedCount;
  bool startCalled = false;
  bool cancelCalled = false;

  @override
  bool get running => fakeRunning;

  @override
  int get done => fakeDone;

  @override
  int get total => fakeTotal;

  @override
  String? get error => fakeError;

  @override
  bool isRouteCached(List<(double, double)> line) => fakeCached;

  @override
  int countCachedTiles(List<(double, double)> line) => fakeCachedCount;

  @override
  Future<void> start(List<(double, double)> line, {required String label}) async {
    startCalled = true;
  }

  @override
  void cancel() {
    cancelCalled = true;
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('coroute_card_test_');
  });

  tearDown(() async {
    TileCache.instance = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<TileCache> openCache() async =>
      (await TileCache.open('${tmp.path}/tiles', clock: () => 1000000))!;

  group('TilePrefetcher isRouteCached & countCachedTiles Unit Tests', () {
    test('reports false and 0 on empty route or no cache', () {
      final pNoCache = TilePrefetcher(null);
      expect(pNoCache.isRouteCached([]), isFalse);
      expect(pNoCache.isRouteCached(testRoute(5)), isFalse);
      expect(pNoCache.countCachedTiles([]), 0);
      expect(pNoCache.countCachedTiles(testRoute(5)), 0);
    });

    test('correctly counts cached tiles and detects full coverage', () async {
      final cache = await openCache();
      final prefetcher = TilePrefetcher(cache);
      final line = testRoute(3);
      final tileList = TilePrefetcher.tilesAlong(line).toList();
      expect(tileList.isNotEmpty, isTrue);

      expect(prefetcher.isRouteCached(line), isFalse);
      expect(prefetcher.countCachedTiles(line), 0);

      // Store half of the tiles
      final half = (tileList.length / 2).floor();
      for (var i = 0; i < half; i++) {
        final t = tileList[i];
        await cache.store(t.$1, t.$2, t.$3, dummyBytes(50));
      }

      expect(prefetcher.countCachedTiles(line), half);
      expect(prefetcher.isRouteCached(line), isFalse);

      // Store remaining tiles
      for (var i = half; i < tileList.length; i++) {
        final t = tileList[i];
        await cache.store(t.$1, t.$2, t.$3, dummyBytes(50));
      }

      expect(prefetcher.countCachedTiles(line), tileList.length);
      expect(prefetcher.isRouteCached(line), isTrue);
    });
  });

  group('RouteMapPackCard Widget Tests', () {
    testWidgets('renders empty shrink widget when route is null or approximate', (tester) async {
      final prefetcher = FakeTilePrefetcher();

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<TilePrefetcher?>.value(
            value: prefetcher,
            child: const Scaffold(
              body: RouteMapPackCard(route: null),
            ),
          ),
        ),
      );

      expect(find.byType(RouteMapPackCard), findsOneWidget);
      expect(find.text('Download Route Map Pack'), findsNothing);

      // Approximate route
      final approxPts = [(17.385, 78.4867), (17.400, 78.500)];
      final approxRoute = RouteModel(
        distanceM: 5000,
        durationS: 600,
        polyline: GeoMath.encodePolyline(approxPts),
        approximate: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<TilePrefetcher?>.value(
            value: prefetcher,
            child: Scaffold(
              body: RouteMapPackCard(route: approxRoute),
            ),
          ),
        ),
      );

      expect(find.text('Download Route Map Pack'), findsNothing);
    });

    testWidgets('renders idle state with Download button and starts download on tap', (tester) async {
      final prefetcher = FakeTilePrefetcher();

      final pts = testRoute(5);
      final route = RouteModel(
        distanceM: 5000,
        durationS: 600,
        polyline: GeoMath.encodePolyline(pts),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<TilePrefetcher?>.value(
            value: prefetcher,
            child: Scaffold(
              body: RouteMapPackCard(route: route, tripName: 'Bangalore Run'),
            ),
          ),
        ),
      );

      expect(find.text('Download Route Map Pack'), findsOneWidget);
      expect(find.textContaining('tiles along route corridor'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Download'), findsOneWidget);

      // Tap Download
      await tester.tap(find.widgetWithText(FilledButton, 'Download'));
      await tester.pump();

      expect(prefetcher.startCalled, isTrue);
    });

    testWidgets('renders running state with progress bar and cancel button', (tester) async {
      final prefetcher = FakeTilePrefetcher(
        fakeRunning: true,
        fakeDone: 10,
        fakeTotal: 40,
      );

      final pts = testRoute(5);
      final route = RouteModel(
        distanceM: 5000,
        durationS: 600,
        polyline: GeoMath.encodePolyline(pts),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<TilePrefetcher?>.value(
            value: prefetcher,
            child: Scaffold(
              body: RouteMapPackCard(route: route),
            ),
          ),
        ),
      );

      expect(find.text('Downloading Map Pack...'), findsOneWidget);
      expect(find.text('10 of 40 tiles (25%)'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      // Tap cancel
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();

      expect(prefetcher.cancelCalled, isTrue);
    });

    testWidgets('renders SAVED state when route is cached', (tester) async {
      final prefetcher = FakeTilePrefetcher(fakeCached: true);

      final line = testRoute(3);
      final route = RouteModel(
        distanceM: 3000,
        durationS: 400,
        polyline: GeoMath.encodePolyline(line),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<TilePrefetcher?>.value(
            value: prefetcher,
            child: Scaffold(
              body: RouteMapPackCard(route: route),
            ),
          ),
        ),
      );

      expect(find.text('Route Map Pack Downloaded'), findsOneWidget);
      expect(find.text('SAVED'), findsOneWidget);
      expect(find.textContaining('OSM tiles saved · Offline ready for 30 days'), findsOneWidget);
      expect(find.byIcon(Icons.offline_pin_rounded), findsOneWidget);
    });

    testWidgets('renders error state and retries on button tap', (tester) async {
      final prefetcher = FakeTilePrefetcher(fakeError: 'network');

      final line = testRoute(3);
      final route = RouteModel(
        distanceM: 3000,
        durationS: 400,
        polyline: GeoMath.encodePolyline(line),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<TilePrefetcher?>.value(
            value: prefetcher,
            child: Scaffold(
              body: RouteMapPackCard(route: route),
            ),
          ),
        ),
      );

      expect(find.text('Download Interrupted'), findsOneWidget);
      expect(find.text('Network issue. Tap retry to resume.'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pump();

      expect(prefetcher.startCalled, isTrue);
    });
  });
}
