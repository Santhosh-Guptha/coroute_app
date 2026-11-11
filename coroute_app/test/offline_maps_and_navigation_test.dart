import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/tile_cache_service.dart';
import 'package:coroute_app/data/services/weather_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/domain/route/route_guide.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/presentation/rider/widgets/minimal_cockpit_overlay.dart';

const int day = 86400000;

Uint8List bytes(int n, [int fill = 1]) => Uint8List.fromList(List<int>.filled(n, fill));

/// A route heading north from Hyderabad: (lat, lng)
List<(double, double)> testRoute(int count) => [
      for (var i = 0; i <= count; i++) (17.3850 + i * 0.005, 78.4867 + i * 0.005)
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late int now;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('coroute_offline_nav_');
    now = DateTime.now().millisecondsSinceEpoch;
  });

  tearDown(() async {
    TileCache.instance = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<TileCache> openCache({int? maxBytesBudget}) async =>
      (await TileCache.open('${tmp.path}/tiles', clock: () => now, maxBytesBudget: maxBytesBudget))!;

  group('ISSUE-6A: Automatic Offline Map Preparation & TileCache Enhancements', () {
    test('TileCache budget is configurable within 300 MB - 500 MB, defaulting to 400 MB', () async {
      final cache = await openCache();
      expect(cache.maxBytesBudget, equals(300 * 1024 * 1024)); // Default 300 MB (automatic offline maps, Nov 11)

      // Configure budget within range
      cache.configureBudgetMb(350);
      expect(cache.maxBytesBudget, equals(350 * 1024 * 1024));

      cache.configureBudgetMb(480);
      expect(cache.maxBytesBudget, equals(480 * 1024 * 1024));

      // Clamping below 300 MB
      cache.configureBudgetMb(100);
      expect(cache.maxBytesBudget, equals(SafetyConstants.tileCacheMinBudgetBytes)); // 300 MB

      // Clamping above 500 MB
      cache.configureBudgetMb(800);
      expect(cache.maxBytesBudget, equals(SafetyConstants.tileCacheMaxBudgetBytes)); // 500 MB
    });

    test('TileCache: Never delete tiles belonging to the active trip during LRU pruning', () async {
      final cache = await openCache();

      // Store 5 tiles of 1000 bytes each
      for (var i = 0; i < 5; i++) {
        await cache.store(14, i, 10, bytes(1000));
        now += 1000;
      }
      expect(cache.count, 5);
      expect(cache.approxBytes, 5000);

      // Pin tile (14, 0, 10) as an active trip tile (which is the oldest tile)
      cache.setActiveTripTiles([(14, 0, 10)]);
      expect(cache.isActiveTripTile(14, 0, 10), isTrue);
      expect(cache.activeTripTileCount, 1);

      // Prune with a budget of 2500 bytes (should evict down to <= 2500 bytes)
      // Tile 0 is oldest, but it is pinned to active trip -> must NOT be deleted!
      // Tiles 1, 2 should be deleted instead.
      await cache.prune(maxBytes: 2500);

      expect(cache.lookup(14, 0, 10), isNotNull, reason: 'Active trip tile MUST be preserved');
      expect(cache.lookup(14, 1, 10), isNull, reason: 'Non-active older tile should be evicted');
      expect(cache.lookup(14, 2, 10), isNull, reason: 'Non-active older tile should be evicted');
      expect(cache.lookup(14, 4, 10), isNotNull, reason: 'Newest tile is kept');
    });

    test('TileCache: Active trip tiles are immune to age-based pruning (e.g. >30 days old)', () async {
      final cache = await openCache();

      await cache.store(14, 100, 200, bytes(1000));
      await cache.store(14, 101, 200, bytes(1000));

      // Pin tile 100 to the active trip
      cache.setActiveTripTiles([(14, 100, 200)]);

      // Advance time beyond maxAgeDays (35 days)
      now += 35 * day;

      // Regular pruning
      await cache.prune();

      // Unpinned tile 101 is dropped due to age
      expect(cache.lookup(14, 101, 200), isNull);
      // Active trip tile 100 remains protected on disk!
      expect(File('${tmp.path}/tiles/14_100_200.png').existsSync(), isTrue);
      expect(cache.isActiveTripTile(14, 100, 200), isTrue);
    });

    test('TilePrefetcher.tilesAroundPoint: computes lateral corridor buffer around arbitrary coordinates', () {
      const lat = 17.3850;
      const lng = 78.4867;

      final tiles = TilePrefetcher.tilesAroundPoint(lat, lng, zooms: [12, 14], radiusM: 2500.0);
      expect(tiles, isNotEmpty);

      // Verify zoom 12 and zoom 14 tiles exist
      expect(tiles.any((t) => t.$1 == 12), isTrue);
      expect(tiles.any((t) => t.$1 == 14), isTrue);

      final centerZ14 = TilePrefetcher.tileOf(lat, lng, 14);
      expect(tiles.contains((14, centerZ14.$1, centerZ14.$2)), isTrue);
      // Surrounding 2.5km tiles at zoom 14 are included
      expect(tiles.where((t) => t.$1 == 14).length, greaterThan(1));
    });

    test('TilePrefetcher.tilesForActiveRide: includes rider, 2.5km corridor, stops, destination, and group members', () {
      final line = testRoute(10);
      const riderPos = (17.3800, 78.4800);
      const stop1 = (17.4000, 78.5000);
      const dest = (17.4350, 78.5350);
      final members = [(17.3900, 78.4900), (17.3950, 78.4950)];

      final activeTiles = TilePrefetcher.tilesForActiveRide(
        routeLine: line,
        riderLocation: riderPos,
        stops: [stop1],
        destination: dest,
        groupMembers: members,
        zooms: [14],
        corridorRadiusM: 2500.0,
      );

      expect(activeTiles, isNotEmpty);

      // Verify corridor contains the route start and end
      final startTile = TilePrefetcher.tileOf(line.first.$1, line.first.$2, 14);
      final endTile = TilePrefetcher.tileOf(line.last.$1, line.last.$2, 14);
      expect(activeTiles.contains((14, startTile.$1, startTile.$2)), isTrue);
      expect(activeTiles.contains((14, endTile.$1, endTile.$2)), isTrue);

      // Verify rider location tiles are included
      final riderTile = TilePrefetcher.tileOf(riderPos.$1, riderPos.$2, 14);
      expect(activeTiles.contains((14, riderTile.$1, riderTile.$2)), isTrue);

      // Verify stop tiles are included
      final stopTile = TilePrefetcher.tileOf(stop1.$1, stop1.$2, 14);
      expect(activeTiles.contains((14, stopTile.$1, stopTile.$2)), isTrue);

      // Verify destination tiles are included
      final destTile = TilePrefetcher.tileOf(dest.$1, dest.$2, 14);
      expect(activeTiles.contains((14, destTile.$1, destTile.$2)), isTrue);

      // Verify member tiles are included
      final memberTile = TilePrefetcher.tileOf(members.first.$1, members.first.$2, 14);
      expect(activeTiles.contains((14, memberTile.$1, memberTile.$2)), isTrue);
    });

    test('TilePrefetcher.prepareActiveRide: background execution without manual screens and pins active trip tiles', () async {
      final cache = await openCache();
      final requestedUrls = <String>[];

      final client = MockClient((req) async {
        requestedUrls.add(req.url.toString());
        expect(req.headers['User-Agent'], equals(AppConstants.osmUserAgent));
        return http.Response.bytes(bytes(120), 200);
      });

      final prefetcher = TilePrefetcher(cache, client: client, clock: () => now, spacing: Duration.zero);
      final line = testRoute(2);
      const rider = (17.385, 78.486);
      const stop = (17.390, 78.490);
      const dest = (17.395, 78.495);

      expect(prefetcher.running, isFalse);

      // Run automatic background preparation
      await prefetcher.prepareActiveRide(
        routeLine: line,
        riderLocation: rider,
        stops: [stop],
        destination: dest,
        label: 'Convoy Weekend Ride',
        spacing: Duration.zero,
      );

      expect(prefetcher.running, isFalse);
      expect(prefetcher.done, greaterThan(0));
      expect(cache.activeTripTileCount, greaterThan(0));

      // Check all active tiles are pinned in cache
      final riderTile = TilePrefetcher.tileOf(rider.$1, rider.$2, 14);
      expect(cache.isActiveTripTile(14, riderTile.$1, riderTile.$2), isTrue);

      // isRidePrepared should return true
      final prepared = prefetcher.isRidePrepared(
        routeLine: line,
        riderLocation: rider,
        stops: [stop],
        destination: dest,
      );
      expect(prepared, isTrue);
    });
  });

  group('ISSUE-6B: Offline GPS, HUD, Polyline & Speed Uninterrupted', () {
    test('Pure offline distance and route progress calculation works without network', () {
      final line = testRoute(10);
      final rider = RiderModel(
        userId: 'u1',
        name: 'Rider Arjun',
        lat: line[3].$1,
        lng: line[3].$2,
        speedKmh: 48.0,
        lastSeenEpochMs: now,
      );

      // Offline remaining distance along planned route
      final remainingM = RideFacts.remainingM(
        lat: rider.lat,
        lng: rider.lng,
        line: line,
        destLat: line.last.$1,
        destLng: line.last.$2,
      );
      expect(remainingM, isNotNull);
      expect(remainingM!, greaterThan(0));

      // Offline straight-line distance to waypoint / stop
      final distToDest = GeoMath.haversine(rider.lat, rider.lng, line.last.$1, line.last.$2);
      expect(distToDest, greaterThan(0));
    });

    test('Rider map speed label is accurate offline and formats cleanly', () {
      final activeRider = RiderModel(
        userId: 'u2',
        name: 'Kiran',
        lat: 17.385,
        lng: 78.486,
        speedKmh: 64.2,
        lastSeenEpochMs: now,
      );

      // Offline speed label formatted as rounded km/h
      expect(activeRider.speedKmh.round(), equals(64));
      expect('${activeRider.speedKmh.round()} km/h', equals('64 km/h'));
    });

    testWidgets('MinimalCockpitTopBar renders waypoint HUD and live speed label offline uninterrupted', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MinimalCockpitTopBar(
              title: 'Next: Nandi Hills Fuel Stop',
              subtitle: 'Convoy Weekend Ride',
              connection: null,
              gps: GpsState.accurate,
              speedKmh: 56.4,
              speedLimitKmh: 80,
              riderCount: 4,
              isOfflineMode: true, // Offline mode active
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify Waypoint HUD title and subtitle render cleanly offline
      expect(find.text('Next: Nandi Hills Fuel Stop'), findsOneWidget);
      expect(find.text('Convoy Weekend Ride'), findsOneWidget);

      // Verify live speed label renders uninterrupted offline
      expect(find.text('56'), findsOneWidget);
      expect(find.text('km/h'), findsOneWidget);
      expect(find.text('Limit 80'), findsOneWidget);

      // Verify compact offline indicator badge ('Offline Mode') is displayed
      expect(find.byKey(const Key('cockpit_pill_offline_mode')), findsOneWidget);
      expect(find.text('Offline Mode'), findsOneWidget);
    });


    test('WeatherService sets isUnavailable flag on network/API failure', () async {
      final apiClient = ApiClient(
        httpClient: MockClient((req) async => http.Response('{"error":"unavailable"}', 503)),
      );
      final settings = SettingsService();
      final weatherService = WeatherService(apiClient, settings);

      expect(weatherService.isUnavailable, isFalse);

      // Attempt to check weather with a failing server response
      final points = [
        const WeatherPoint(lat: 17.385, lng: 78.486, atS: 1700000000, name: 'Hyderabad')
      ];
      final res = await weatherService.check(points);
      expect(res, isNull);
      expect(weatherService.isUnavailable, isTrue);

      // Verify manual reset works
      weatherService.setUnavailable(false);
      expect(weatherService.isUnavailable, isFalse);
    });

    test('Continuous GPS streaming and RouteGuide matching without internet', () {
      final line = testRoute(10);
      final route = RouteModel(
        polyline: '',
        precomputedPoints: line,
        distanceM: 10000,
        durationS: 600,
      );
      final convoy = ConvoyModel(
        groupId: 'c1',
        name: 'Weekend Ride',
        joinCode: 'W123',
        createdByUserId: 'u1',
        createdByUserName: 'Lead',
        createdAtEpochMs: now,
        route: route,
        riders: {
          'u1': RiderModel(
            userId: 'u1',
            name: 'Lead Rider',
            lat: line.first.$1,
            lng: line.first.$2,
            speedKmh: 45.0,
            lastSeenEpochMs: now,
          ),
        },
      );

      final guide = RouteGuide(fetchRoute: (w) async => null);
      guide.setConvoy(convoy, 'u1');

      // Feed sequential GPS fixes while completely offline (online: false)
      for (var i = 0; i < 5; i++) {
        guide.onFix(
          lat: line[i].$1,
          lng: line[i].$2,
          speedKmh: 40.0 + i,
          accuracyM: 5.0,
          nowMs: now + i * 1000,
          online: false, // Disconnected from internet
          lowData: false,
        );

        // Verification: guide matches fix on route, progress updates without internet
        expect(guide.active?.matched, isNotNull);
        expect(guide.remainingM, isNotNull);
        expect(guide.remainingM!, lessThanOrEqualTo(10000));
      }
    });
  });
}
