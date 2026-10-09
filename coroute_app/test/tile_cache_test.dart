import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/core/theme/map_tiles.dart';
import 'package:coroute_app/data/services/tile_cache_service.dart';

const int day = 86400000;

Uint8List bytes(int n, [int fill = 1]) => Uint8List.fromList(List<int>.filled(n, fill));

/// A straight line of [km] kilometres heading north from Hyderabad, one point per km.
List<(double, double)> route(int km) => [for (var i = 0; i <= km; i++) (17.385 + i * 0.009, 78.4867)];

void main() {
  late Directory tmp;
  late int now;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('coroute_tiles_');
    // Real time: a reopened cache reads file times from the disk.
    now = DateTime.now().millisecondsSinceEpoch;
  });

  tearDown(() async {
    TileCache.instance = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<TileCache> open() async => (await TileCache.open('${tmp.path}/tiles', clock: () => now))!;

  group('TileCache', () {
    test('store, lookup, index after reopening, age limit', () async {
      final c = await open();
      expect(c.lookup(14, 1, 2), isNull);
      await c.store(14, 1, 2, bytes(100));
      final f = c.lookup(14, 1, 2);
      expect(f, isNotNull);
      expect(await f!.readAsBytes(), hasLength(100));
      expect(c.approxBytes, 100);
      expect(c.count, 1);

      final again = await open();
      expect(again.count, 1, reason: 'indexed from the folder');
      expect(again.lookup(14, 1, 2), isNotNull);

      now += 31 * day;
      expect(again.lookup(14, 1, 2), isNull, reason: 'older than 30 days');
      await again.prune();
      expect(again.count, 0);
      expect(await File('${tmp.path}/tiles/14_1_2.png').exists(), isFalse);
    });

    test('prunes the least recently used tiles over the size cap', () async {
      final c = await open();
      for (var i = 0; i < 5; i++) {
        await c.store(12, i, 0, bytes(1000));
        now += 1000;
      }
      c.lookup(12, 0, 0); // the oldest is used again
      now += 1000;
      await c.prune(maxBytes: 2500);
      expect(c.count, 2);
      expect(c.lookup(12, 0, 0), isNotNull, reason: 'recently used');
      expect(c.lookup(12, 4, 0), isNotNull, reason: 'newest');
      expect(c.lookup(12, 1, 0), isNull);
      expect(c.approxBytes, 2000);
    });

    test('a bad folder gives null (maps then use the network) and empty bytes are not stored', () async {
      final file = File('${tmp.path}/not_a_dir');
      await file.writeAsString('x');
      expect(await TileCache.open('${file.path}/tiles'), isNull);
      final c = await open();
      await c.store(1, 1, 1, Uint8List(0));
      expect(c.count, 0);
    });
  });

  group('tilesAlong', () {
    test('tiles of every 200 m sample at z12 and z14 with z14 neighbours, deduped', () {
      final tiles = TilePrefetcher.tilesAlong(route(2));
      expect(tiles.where((t) => t.$1 == 12).length, inInclusiveRange(1, 3));
      final z14 = tiles.where((t) => t.$1 == 14).toList();
      expect(z14.length, greaterThanOrEqualTo(9), reason: 'at least the 3x3 block of the first sample');
      expect(tiles.length, tiles.toSet().length);
      final centre = TilePrefetcher.tileOf(17.385, 78.4867, 14);
      expect(tiles.contains((14, centre.$1, centre.$2)), isTrue);
      expect(tiles.contains((14, centre.$1 + 1, centre.$2 - 1)), isTrue);
    });

    test('capped at 600 by dropping z14 tiles from the far end first', () {
      final tiles = TilePrefetcher.tilesAlong(route(500));
      expect(tiles.length, SafetyConstants.prefetchMaxTiles);
      final z12 = tiles.where((t) => t.$1 == 12).toList();
      final all12 = TilePrefetcher.tilesAlong(route(500), zooms: const [12]);
      expect(z12.length, greaterThan(0));
      expect(z12.every((t) => all12.contains(t)), isTrue, reason: 'the overview survives');
      // The kept z14 tiles are near the start.
      final startTile = TilePrefetcher.tileOf(17.385, 78.4867, 14);
      final endTile = TilePrefetcher.tileOf(17.385 + 500 * 0.009, 78.4867, 14);
      expect(tiles.contains((14, startTile.$1, startTile.$2)), isTrue);
      expect(tiles.contains((14, endTile.$1, endTile.$2)), isFalse);
      expect(TilePrefetcher.tilesAlong(const []), isEmpty);
    });

    test('tileOf matches the standard Web Mercator formula', () {
      expect(TilePrefetcher.tileOf(0, 0, 1), (1, 1));
      expect(TilePrefetcher.tileOf(17.385, 78.4867, 12), (2941, 1847));
    });
  });

  group('TilePrefetcher', () {
    test('downloads with the app User-Agent, skips cached tiles, reports progress, prunes after', () async {
      final c = await open();
      final urls = <String>[];
      final client = MockClient((req) async {
        urls.add(req.url.toString());
        expect(req.headers['User-Agent'], AppConstants.osmUserAgent);
        return http.Response.bytes(bytes(50), 200);
      });
      final p = TilePrefetcher(c, client: client, clock: () => now, spacing: Duration.zero);
      final tiles = TilePrefetcher.tilesAlong(route(1)).toList();
      await c.store(tiles.first.$1, tiles.first.$2, tiles.first.$3, bytes(10));
      var notified = 0;
      p.addListener(() {
        notified++;
        now += 600; // every progress step is spaced out in time
      });
      await p.start(route(1), label: 'Nandi');
      expect(p.running, isFalse);
      expect(p.total, tiles.length);
      expect(p.done, tiles.length);
      expect(p.saved, tiles.length - 1);
      expect(p.error, isNull);
      expect(p.complete, isTrue);
      expect(p.label, 'Nandi');
      expect(urls, hasLength(tiles.length - 1));
      expect(urls.first, startsWith('https://tile.openstreetmap.org/'));
      expect(notified, greaterThan(1));
      expect(c.count, tiles.length);
    });

    test('stops after 5 failures in a row with error network; cancel stops early', () async {
      final c = await open();
      var calls = 0;
      final failing = MockClient((req) async {
        calls++;
        return http.Response('no', 503);
      });
      final p = TilePrefetcher(c, client: failing, clock: () => now, spacing: Duration.zero);
      await p.start(route(20), label: 'x');
      expect(p.error, 'network');
      expect(calls, inInclusiveRange(5, 7));
      expect(p.complete, isFalse);

      var served = 0;
      late TilePrefetcher q;
      final slow = MockClient((req) async {
        served++;
        if (served == 2) q.cancel();
        return http.Response.bytes(bytes(10), 200);
      });
      q = TilePrefetcher(c, client: slow, clock: () => now, spacing: Duration.zero);
      await q.start(route(20), label: 'y');
      expect(q.running, isFalse);
      expect(q.done, lessThan(q.total));
      expect(q.error, isNull);
    });

    test('without a cache the job ends at once with error storage', () async {
      final p = TilePrefetcher(null, client: MockClient((_) async => http.Response('', 200)), clock: () => now, spacing: Duration.zero);
      await p.start(route(3), label: 'z');
      expect(p.error, 'storage');
      expect(p.total, 0);
    });
  });

  group('appTileProvider', () {
    test('network provider without a cache, cached provider with one; both carry the User-Agent', () async {
      TileCache.instance = null;
      final net = appTileProvider();
      expect(net, isA<NetworkTileProvider>());
      expect(net.headers['User-Agent'], AppConstants.osmUserAgent);
      TileCache.instance = await open();
      final cached = appTileProvider();
      expect(cached, isA<CachedTileProvider>());
      expect(cached.headers['User-Agent'], AppConstants.osmUserAgent);
      final layer = appTileLayer();
      expect(layer.urlTemplate, AppConstants.osmTileUrl);
      expect(layer.tileProvider, isA<CachedTileProvider>());
      net.dispose();
      cached.dispose();
    });
  });
}
