import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/data/local/saved_map_pack_store.dart';
import 'package:coroute_app/data/models/saved_map_pack.dart';
import 'package:coroute_app/data/services/tile_cache_service.dart';
import 'package:coroute_app/presentation/trip_planner/offline_map_manager_screen.dart';
import 'package:coroute_app/presentation/trip_planner/offline_tile_verification_screen.dart';

List<(double, double)> testCorridor(int km) => [
      for (var i = 0; i <= km; i++) (17.385 + i * 0.009, 78.4867),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TileCache.instance = null;
  });

  group('SavedMapPack & SavedMapPackStore Unit Tests', () {
    test('SavedMapPack model serializes and deserializes correctly', () {
      final pack = SavedMapPack(
        id: 'pack_123',
        name: 'Nandi Sunrise Corridor',
        downloadedAt: DateTime(2026, 10, 13, 10, 30),
        highDetail: true,
        zooms: const [12, 14, 16, 17],
        tileCount: 480,
        estimatedBytes: 12 * 1024 * 1024,
        polyline: testCorridor(5),
      );

      final json = pack.toJson();
      expect(json['id'], 'pack_123');
      expect(json['high_detail'], isTrue);
      expect(json['tile_count'], 480);
      expect(pack.sizeMb, '12.0');

      final reconstructed = SavedMapPack.fromJson(json);
      expect(reconstructed.id, 'pack_123');
      expect(reconstructed.name, 'Nandi Sunrise Corridor');
      expect(reconstructed.highDetail, isTrue);
      expect(reconstructed.zooms, const [12, 14, 16, 17]);
      expect(reconstructed.tileCount, 480);
      expect(reconstructed.polyline.length, 6);
    });

    test('SavedMapPackStore saves, lists, deletes, and clears packs in SharedPreferences', () async {
      expect(await SavedMapPackStore.loadAll(), isEmpty);

      final pack1 = SavedMapPack(
        id: 'p1',
        name: 'Coorg Express',
        downloadedAt: DateTime(2026, 10, 10),
        highDetail: false,
        tileCount: 120,
        estimatedBytes: 3 * 1024 * 1024,
        polyline: testCorridor(2),
      );

      final pack2 = SavedMapPack(
        id: 'p2',
        name: 'Mysore Highway High Detail',
        downloadedAt: DateTime(2026, 10, 12),
        highDetail: true,
        zooms: const [12, 14, 16, 17],
        tileCount: 520,
        estimatedBytes: 13 * 1024 * 1024,
        polyline: testCorridor(4),
      );

      await SavedMapPackStore.save(pack1);
      await SavedMapPackStore.save(pack2);

      final list = await SavedMapPackStore.loadAll();
      expect(list.length, 2);
      // Newest first
      expect(list.first.id, 'p2');
      expect(list.last.id, 'p1');

      await SavedMapPackStore.delete('p1');
      final listAfterDelete = await SavedMapPackStore.loadAll();
      expect(listAfterDelete.length, 1);
      expect(listAfterDelete.first.id, 'p2');

      await SavedMapPackStore.clear();
      expect(await SavedMapPackStore.loadAll(), isEmpty);
    });
  });

  group('High-Detail Corridor Prefetch Logic (Zooms 16 and 17)', () {
    test('tilesAlong in highDetail mode includes zooms 12, 14, 16, and 17', () {
      final line = testCorridor(5);
      final hdTiles = TilePrefetcher.tilesAlong(line, highDetail: true);

      final z12 = hdTiles.where((t) => t.$1 == 12);
      final z14 = hdTiles.where((t) => t.$1 == 14);
      final z16 = hdTiles.where((t) => t.$1 == 16);
      final z17 = hdTiles.where((t) => t.$1 == 17);

      expect(z12.isNotEmpty, isTrue, reason: 'Overview zoom 12 present');
      expect(z14.isNotEmpty, isTrue, reason: 'Corridor zoom 14 present');
      expect(z16.isNotEmpty, isTrue, reason: 'Street level zoom 16 present');
      expect(z17.isNotEmpty, isTrue, reason: 'Junction level zoom 17 present');

      expect(hdTiles.length, greaterThan(TilePrefetcher.tilesAlong(line, highDetail: false).length));
    });

    test('high detail tile set is bounded by SafetyConstants.prefetchMaxTilesHighDetail', () {
      final longRoute = testCorridor(400); // 400km long route
      final tiles = TilePrefetcher.tilesAlong(longRoute, highDetail: true);

      expect(tiles.length, lessThanOrEqualTo(SafetyConstants.prefetchMaxTilesHighDetail));
      expect(tiles.length, greaterThan(600)); // More than standard 600
    });
  });

  group('OfflineTileVerificationScreen Widget Tests', () {
    testWidgets('renders verification HUD, offline indicator, and zoom snap chips', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: OfflineTileVerificationScreen(
            packName: 'Bangalore to Mysore',
            routePoints: testCorridor(4),
            highDetail: true,
            showTileLayer: false,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Bangalore to Mysore'), findsOneWidget);
      expect(find.text('OFFLINE TILE VERIFICATION'), findsOneWidget);
      expect(find.text('Z12 Overview'), findsOneWidget);
      expect(find.text('Z14 Highways'), findsOneWidget);
      expect(find.text('Z16 Streets'), findsOneWidget);
      expect(find.text('Z17 Junctions'), findsOneWidget);
      expect(find.text('Offline Storage Ready'), findsOneWidget);
      expect(find.text('HIGH DETAIL'), findsOneWidget);

      // Tap Z12 Overview
      await tester.tap(find.text('Z12 Overview'));
      await tester.pump();

      expect(find.textContaining('Z 12.0'), findsOneWidget);
      expect(find.text('Regional corridor overview'), findsOneWidget);

      // Tap Z17 Junctions
      await tester.tap(find.text('Z17 Junctions'));
      await tester.pump();

      expect(find.textContaining('Z 17.0'), findsOneWidget);
      expect(find.text('Junction turns, landmark POIs & buildings'), findsOneWidget);
    });
  });

  group('OfflineMapManagerScreen Widget Tests', () {
    testWidgets('renders storage gauge, empty state when no packs', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: OfflineMapManagerScreen(initialPacks: []),
        ),
      );
      await tester.pump();

      expect(find.text('Offline Map Packs'), findsOneWidget);
      expect(find.text('Local Map Cache Storage'), findsOneWidget);
      expect(find.textContaining('of 200 MB used'), findsOneWidget);
      expect(find.text('No Downloaded Corridors'), findsOneWidget);
    });

    testWidgets('renders downloaded map packs with Verify and Delete actions', (tester) async {
      final pack = SavedMapPack(
        id: 'pack_nandi',
        name: 'Nandi Hills Sunrise Run',
        downloadedAt: DateTime.now(),
        highDetail: true,
        zooms: const [12, 14, 16, 17],
        tileCount: 480,
        estimatedBytes: 12 * 1024 * 1024,
        polyline: testCorridor(4),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: OfflineMapManagerScreen(initialPacks: [pack]),
        ),
      );
      await tester.pump();

      expect(find.text('Nandi Hills Sunrise Run'), findsOneWidget);
      expect(find.text('HIGH DETAIL'), findsOneWidget);
      expect(find.textContaining('480 tiles (~12.0 MB)'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Verify Offline'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);

      // Tap Verify Offline -> navigates to OfflineTileVerificationScreen
      await tester.tap(find.widgetWithText(OutlinedButton, 'Verify Offline'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(OfflineTileVerificationScreen), findsOneWidget);
      expect(find.text('Nandi Hills Sunrise Run'), findsWidgets);

      // Return
      await tester.tap(find.text('Return to Trip Planner'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(OfflineMapManagerScreen), findsOneWidget);
    });
  });
}
