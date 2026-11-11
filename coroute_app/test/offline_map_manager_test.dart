import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/data/local/saved_map_pack_store.dart';
import 'package:coroute_app/data/models/saved_map_pack.dart';
import 'package:coroute_app/data/services/tile_cache_service.dart';

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
}
