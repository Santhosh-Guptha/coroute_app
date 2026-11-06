import 'package:coroute_app/core/config/feature_gates.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/data/services/tile_cache_service.dart';

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
  bool isRouteCached(List<(double, double)> line, {bool highDetail = false, Set<(int, int, int)>? precomputedTiles}) => fakeCached;

  @override
  int countCachedTiles(List<(double, double)> line, {bool highDetail = false, Set<(int, int, int)>? precomputedTiles}) => fakeCachedCount;

  @override
  Future<void> start(List<(double, double)> line, {required String label, bool highDetail = false}) async {
    startCalled = true;
  }

  @override
  void cancel() {
    cancelCalled = true;
  }
}

void main() {
  setUp(() => FeatureGates.forceAllUnlocked = true);
  tearDown(() => FeatureGates.forceAllUnlocked = false);
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

}
