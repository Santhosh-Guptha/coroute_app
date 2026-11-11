// Automatic offline maps (Nov 11): a trip's saved map is kept 7 days after the trip, a map for a trip
// that never ended goes after 30 days, everything saved stays under 300 MB (least recently used first),
// and the map of the ride in progress is never deleted.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/local/saved_map_pack_store.dart';
import 'package:coroute_app/data/models/saved_map_pack.dart';
import 'package:coroute_app/data/services/offline_map_retention_service.dart';
import 'package:coroute_app/data/services/tile_cache_service.dart';
import 'package:coroute_app/domain/geo/offline_map_retention.dart';

const int _day = 86400000;
const int _mb = 1024 * 1024;

List<(double, double)> _route(double lat0, int km) => [for (var i = 0; i <= km; i++) (lat0 + i * 0.009, 78.4867)];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OfflineMapRetention.decide (pure)', () {
    const now = 100 * _day;

    test('defaults: 7 days after the trip, 30 days unridden, 300 MB', () {
      expect(OfflineMapRetention.keepAfterTrip, const Duration(days: 7));
      expect(OfflineMapRetention.keepUnridden, const Duration(days: 30));
      expect(OfflineMapRetention.maxBytes, 300 * _mb);
    });

    test('an ended trip is kept for 7 days, then deleted', () {
      final six = RetainedMap(id: 'a', createdAtMs: now - 10 * _day, completedAtMs: now - 6 * _day, bytes: _mb);
      final eight = RetainedMap(id: 'b', createdAtMs: now - 10 * _day, completedAtMs: now - 8 * _day, bytes: _mb);
      expect(OfflineMapRetention.decide([six, eight], nowMs: now), {'b': RetentionReason.tripEnded});
    });

    test('the retention time counts from the end of the trip, not from the download', () {
      final m = RetainedMap(id: 'a', createdAtMs: now - 40 * _day, completedAtMs: now - 1 * _day, bytes: _mb);
      expect(OfflineMapRetention.decide([m], nowMs: now), isEmpty);
    });

    test('a map for a trip that never ended goes after 30 days', () {
      final fresh = RetainedMap(id: 'a', createdAtMs: now - 29 * _day, bytes: _mb);
      final stale = RetainedMap(id: 'b', createdAtMs: now - 31 * _day, bytes: _mb);
      expect(OfflineMapRetention.decide([fresh, stale], nowMs: now), {'b': RetentionReason.neverRidden});
    });

    test('over 300 MB: least recently used first, until under the cap', () {
      final maps = [
        RetainedMap(id: 'old', createdAtMs: now - 5 * _day, completedAtMs: now - 1 * _day, lastUsedAtMs: now - 5 * _day, bytes: 150 * _mb),
        RetainedMap(id: 'mid', createdAtMs: now - 4 * _day, completedAtMs: now - 1 * _day, lastUsedAtMs: now - 4 * _day, bytes: 150 * _mb),
        RetainedMap(id: 'new', createdAtMs: now - 1 * _day, lastUsedAtMs: now - 1 * _day, bytes: 100 * _mb),
      ];
      expect(OfflineMapRetention.decide(maps, nowMs: now), {'old': RetentionReason.overBudget});
    });

    test('custom cap and retention (configurable constants)', () {
      final m = RetainedMap(id: 'a', createdAtMs: now - 3 * _day, completedAtMs: now - 3 * _day, bytes: 10 * _mb);
      expect(OfflineMapRetention.decide([m], nowMs: now, keepAfterTrip: const Duration(days: 2)), {'a': RetentionReason.tripEnded});
      expect(OfflineMapRetention.decide([m], nowMs: now, maxBytes: 5 * _mb), {'a': RetentionReason.overBudget});
    });

    test('the ride in progress is never deleted, even when old or over the cap', () {
      final active = RetainedMap(id: 'ride', createdAtMs: now - 60 * _day, lastUsedAtMs: now - 60 * _day, bytes: 400 * _mb);
      final other = RetainedMap(id: 'x', createdAtMs: now - 1 * _day, completedAtMs: now - 1 * _day, bytes: 10 * _mb);
      expect(OfflineMapRetention.decide([active, other], nowMs: now, activeIds: {'ride'}), {'x': RetentionReason.overBudget});
    });

    test('equal last use: an ended trip goes before one still to ride', () {
      final ended = RetainedMap(id: 'ended', createdAtMs: now - _day, completedAtMs: now - _day, lastUsedAtMs: now - _day, bytes: 200 * _mb);
      final ahead = RetainedMap(id: 'ahead', createdAtMs: now - _day, lastUsedAtMs: now - _day, bytes: 200 * _mb);
      expect(OfflineMapRetention.decide([ahead, ended], nowMs: now), {'ended': RetentionReason.overBudget});
    });
  });

  group('SavedMapPack trip fields', () {
    test('round-trip and retention view; packs from before Nov 11 count as ended when saved', () {
      final at = DateTime(2026, 11, 1);
      final pack = SavedMapPack(
        id: SavedMapPack.idForTrip('GRP-1'),
        name: 'Nandi',
        downloadedAt: at,
        tileCount: 10,
        estimatedBytes: 250 * 1024,
        polyline: _route(17.385, 2),
        tripId: 'GRP-1',
        completedAt: at.add(const Duration(hours: 3)),
      );
      final back = SavedMapPack.fromJson(pack.toJson());
      expect(back.tripId, 'GRP-1');
      expect(back.completedAt, pack.completedAt);
      expect(back.retained.completedAtMs, pack.completedAt!.millisecondsSinceEpoch);
      final legacy = SavedMapPack(id: 'pack_1', name: 'Old', downloadedAt: at, tileCount: 1, estimatedBytes: 1, polyline: const []);
      expect(legacy.retained.completedAtMs, at.millisecondsSinceEpoch);
    });
  });

  group('OfflineMapRetentionService (storage + tile cache)', () {
    late Directory tmp;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('coroute_retention');
    });
    tearDown(() async {
      TileCache.instance = null;
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('a trip ended 8 days ago loses its map and tiles; a trip ended yesterday keeps them, protected from pruning', () async {
      final now = DateTime(2026, 11, 11, 12);
      final cache = (await TileCache.open('${tmp.path}/tiles', clock: () => now.millisecondsSinceEpoch))!;
      final oldLine = _route(17.385, 3);
      final newLine = _route(12.97, 3);
      SavedMapPack pack(String trip, List<(double, double)> line, DateTime done) => SavedMapPack(
            id: SavedMapPack.idForTrip(trip),
            name: trip,
            downloadedAt: done.subtract(const Duration(hours: 2)),
            tileCount: 10,
            estimatedBytes: 10 * 25 * 1024,
            polyline: line,
            tripId: trip,
            completedAt: done,
          );
      await SavedMapPackStore.save(pack('GRP-OLD', oldLine, now.subtract(const Duration(days: 8))));
      await SavedMapPackStore.save(pack('GRP-NEW', newLine, now.subtract(const Duration(days: 1))));
      final oldTile = OfflineMapRetentionService.tilesOf((await SavedMapPackStore.loadAll()).firstWhere((p) => p.tripId == 'GRP-OLD')).first;
      final newTile = OfflineMapRetentionService.tilesOf((await SavedMapPackStore.loadAll()).firstWhere((p) => p.tripId == 'GRP-NEW')).first;
      await cache.store(oldTile.$1, oldTile.$2, oldTile.$3, Uint8List.fromList([1, 2, 3]));
      await cache.store(newTile.$1, newTile.$2, newTile.$3, Uint8List.fromList([1, 2, 3]));

      final deleted = await OfflineMapRetentionService.sweep(cache: cache, now: now);
      expect(deleted, {SavedMapPack.idForTrip('GRP-OLD')});
      expect(cache.has(oldTile.$1, oldTile.$2, oldTile.$3), isFalse);
      expect(cache.has(newTile.$1, newTile.$2, newTile.$3), isTrue);
      expect((await SavedMapPackStore.loadAll()).map((p) => p.tripId), ['GRP-NEW']);

      // The kept map's tiles survive the cache's own LRU pruning.
      await cache.prune(maxBytes: 0);
      expect(cache.has(newTile.$1, newTile.$2, newTile.$3), isTrue);
    });

    test('tripEnded starts the 7-day clock for that ride only', () async {
      final now = DateTime(2026, 11, 11, 12);
      await SavedMapPackStore.save(SavedMapPack(
        id: SavedMapPack.idForTrip('GRP-A'),
        name: 'A',
        downloadedAt: now.subtract(const Duration(days: 2)),
        tileCount: 1,
        estimatedBytes: 1,
        polyline: _route(17.385, 1),
        tripId: 'GRP-A',
      ));
      await SavedMapPackStore.save(SavedMapPack(
        id: SavedMapPack.idForTrip('GRP-B'),
        name: 'B',
        downloadedAt: now.subtract(const Duration(days: 1)),
        tileCount: 1,
        estimatedBytes: 1,
        polyline: _route(12.97, 1),
        tripId: 'GRP-B',
      ));
      await OfflineMapRetentionService.tripEnded('GRP-A', now: now);
      final packs = {for (final p in await SavedMapPackStore.loadAll()) p.tripId: p};
      expect(packs['GRP-A']!.completedAt, now);
      expect(packs['GRP-B']!.completedAt, isNull);
    });
  });
}
