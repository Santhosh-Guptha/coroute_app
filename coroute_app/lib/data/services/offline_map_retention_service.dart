import 'package:flutter/foundation.dart';

import '../../domain/geo/offline_map_retention.dart';
import '../local/saved_map_pack_store.dart';
import '../models/saved_map_pack.dart';
import 'tile_cache_service.dart';

/// Automatic offline maps (Nov 11): applies [OfflineMapRetention] to the saved trip maps.
///
/// * [tripEnded] (SafetyService when a ride ends): unpins the ride's tiles, starts its map's
///   retention time, then sweeps.
/// * [sweep] (app start, after each ride): deletes the maps that are past their time or over the
///   300 MB cap, together with their tiles (a tile another kept map also uses stays), and protects
///   the tiles of the maps still kept from the cache's own age / LRU pruning.
///
/// No screen and no rider setting. Never throws.
class OfflineMapRetentionService {
  OfflineMapRetentionService._();

  static Future<void>? _running;

  /// The ride [tripId] ended at [now] (wall clock by default).
  static Future<void> tripEnded(String tripId, {TileCache? cache, DateTime? now}) async {
    try {
      final c = cache ?? TileCache.instance;
      c?.clearActiveTripTiles();
      await SavedMapPackStore.markCompleted(tripId, now ?? DateTime.now());
      await sweep(cache: c, now: now);
    } catch (e) {
      debugPrint('offline map retention note: ${e.runtimeType}');
    }
  }

  /// One pass of the retention rules; returns the ids of the maps deleted. Calls made while a
  /// pass runs wait for it (and return no ids).
  static Future<Set<String>> sweep({TileCache? cache, DateTime? now, Set<String> activeTripIds = const {}}) async {
    final busy = _running;
    if (busy != null) {
      await busy;
      return const {};
    }
    var deleted = const <String>{};
    final job = () async {
      deleted = await _sweep(cache ?? TileCache.instance, now ?? DateTime.now(), activeTripIds);
    }();
    _running = job;
    try {
      await job;
    } catch (e) {
      debugPrint('offline map retention note: ${e.runtimeType}');
    } finally {
      _running = null;
    }
    return deleted;
  }

  static Future<Set<String>> _sweep(TileCache? cache, DateTime now, Set<String> activeTripIds) async {
    final packs = await SavedMapPackStore.loadAll();
    if (packs.isEmpty) {
      cache?.setRetainedTiles(const []);
      return const {};
    }
    final activeIds = {for (final t in activeTripIds) SavedMapPack.idForTrip(t)};
    final decision = OfflineMapRetention.decide(
      [for (final p in packs) p.retained],
      nowMs: now.millisecondsSinceEpoch,
      activeIds: activeIds,
    );
    final kept = packs.where((p) => !decision.containsKey(p.id)).toList();
    final keptTiles = <(int, int, int)>{for (final p in kept) ...tilesOf(p)};
    if (cache != null && decision.isNotEmpty) {
      final doomedTiles = <(int, int, int)>{
        for (final p in packs)
          if (decision.containsKey(p.id)) ...tilesOf(p),
      }..removeAll(keptTiles);
      // Tiles of the ride in progress are skipped by deleteTiles (not forced).
      await cache.deleteTiles(doomedTiles);
    }
    cache?.setRetainedTiles(keptTiles);
    if (decision.isNotEmpty) {
      await SavedMapPackStore.deleteAll(decision.keys);
      debugPrint('offline maps: removed ${decision.length} saved trip map(s)');
    }
    return decision.keys.toSet();
  }

  /// The tiles a saved map covers (the same corridor the prefetch saved).
  static Set<(int, int, int)> tilesOf(SavedMapPack p) {
    if (p.polyline.isEmpty) return const {};
    return TilePrefetcher.tilesAlong(p.polyline, highDetail: p.highDetail);
  }
}
