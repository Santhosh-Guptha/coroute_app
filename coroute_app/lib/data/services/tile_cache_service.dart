import 'dart:async';
import 'dart:convert' show base64Decode;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import '../../core/config/feature_gates.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/safety_constants.dart';
import '../../domain/tracking/geo_math.dart';
import '../local/saved_map_pack_store.dart';
import '../models/saved_map_pack.dart';

/// Map tiles saved on the phone (3.16). Every map reads through it, so a tile
/// seen once (or saved along the planned route before the ride) shows again
/// without data, in a dead zone too. LRU by last use, capped at
/// [SafetyConstants.tileCacheMaxBytes], tiles older than
/// [SafetyConstants.tileMaxAgeDays] are dropped. Files live in the app's own
/// cache folder (`<cacheDir>/tiles/<z>_<x>_<y>.png`); nothing leaves the phone.
class TileCache {
  TileCache._(this.dir, this._clock, {int? maxBytesBudget})
      : maxBytesBudget = maxBytesBudget ?? SafetyConstants.tileCacheMaxBytes;
  int maxBytesBudget;
  final Set<String> _activeTripTiles = {};

  /// Sets the configurable cache budget in megabytes (clamped between 300 and 500 MB).
  void configureBudgetMb(int mb) {
    maxBytesBudget = (mb * 1024 * 1024).clamp(
      SafetyConstants.tileCacheMinBudgetBytes,
      SafetyConstants.tileCacheMaxBudgetBytes,
    );
  }

  /// Pinned tiles belonging to the active trip. These are NEVER pruned.
  Set<String> get activeTripTileKeys => Set.unmodifiable(_activeTripTiles);
  int get activeTripTileCount => _activeTripTiles.length;

  /// Registers tiles belonging to the active trip so they are protected from LRU pruning.
  void setActiveTripTiles(Iterable<(int, int, int)> tiles) {
    _activeTripTiles.clear();
    for (final t in tiles) {
      _activeTripTiles.add(nameOf(t.$1, t.$2, t.$3));
    }
  }

  /// Appends tiles belonging to the active trip so they are protected from LRU pruning.
  void registerActiveTripTiles(Iterable<(int, int, int)> tiles) {
    for (final t in tiles) {
      _activeTripTiles.add(nameOf(t.$1, t.$2, t.$3));
    }
  }

  /// Clears active trip tile pins (e.g. when a trip concludes).
  void clearActiveTripTiles() {
    _activeTripTiles.clear();
  }

  /// Checks if a tile is currently pinned as part of the active trip.
  bool isActiveTripTile(int z, int x, int y) => _activeTripTiles.contains(nameOf(z, x, y));

  /// Set once by main.dart after [open]; null means maps use the plain network provider.
  static TileCache? instance;

  /// Long-lived HTTP client shared across tile requests to avoid connection thrashing.
  static final http.Client sharedHttpClient = http.Client();

  final Directory dir;
  final int Function() _clock;
  final Map<String, _TileEntry> _index = {};
  int _bytes = 0;
  bool _pruning = false;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// Opens (creates) the folder, indexes what is there and prunes. Null when the
  /// folder cannot be used; the caller then leaves [instance] null.
  static Future<TileCache?> open(String dir, {int Function()? clock, bool syncScan = true, int? maxBytesBudget}) async {
    try {
      final d = Directory(dir);
      await d.create(recursive: true);
      final c = TileCache._(d, clock ?? _wallClock, maxBytesBudget: maxBytesBudget);
      if (syncScan) {
        await c._scan();
        await c.prune();
      } else {
        c._scanAndPruneBackground();
      }
      return c;
    } catch (e) {
      debugPrint('tile cache note: ${e.runtimeType}');
      return null;
    }
  }

  void _scanAndPruneBackground() {
    _scan().then((_) => prune()).catchError((_) {});
  }

  Future<void> _scan() async {
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.path.split(Platform.pathSeparator).last;
      if (!_validName(name)) continue;
      try {
        final st = await e.stat();
        final at = st.modified.millisecondsSinceEpoch;
        _index[name] = _TileEntry(size: st.size, storedAt: at, usedAt: at);
        _bytes += st.size;
      } catch (_) {}
    }
  }

  static final RegExp _namePattern = RegExp(r'^\d{1,2}_\d{1,7}_\d{1,7}\.png$');
  static bool _validName(String n) => _namePattern.hasMatch(n);
  static String nameOf(int z, int x, int y) => '${z}_${x}_$y.png';

  String _path(String name) => '${dir.path}${Platform.pathSeparator}$name';

  int get approxBytes => _bytes;
  double get approxMb => _bytes / (1024 * 1024);
  int get count => _index.length;

  /// Deletes a set of specific tiles from disk and the memory index.
  Future<void> deleteTiles(Iterable<(int, int, int)> tiles, {bool force = false}) async {
    for (final t in tiles) {
      final name = nameOf(t.$1, t.$2, t.$3);
      if (!force && _activeTripTiles.contains(name)) continue;
      await _delete(name);
    }
  }

  /// The saved tile, when it exists and is not older than [maxAgeDays]. Cheap (memory index).
  File? lookup(int z, int x, int y, {int maxAgeDays = SafetyConstants.tileMaxAgeDays}) {
    final name = nameOf(z, x, y);
    final e = _index[name];
    if (e == null) {
      final f = File(_path(name));
      return f.existsSync() ? f : null;
    }
    final now = _clock();
    if (now - e.storedAt > maxAgeDays * 86400000) return null;
    e.usedAt = now;
    return File(_path(name));
  }

  bool has(int z, int x, int y) => lookup(z, x, y) != null;

  Future<void> store(int z, int x, int y, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    final name = nameOf(z, x, y);
    try {
      await File(_path(name)).writeAsBytes(bytes, flush: false);
      final old = _index[name];
      if (old != null) _bytes -= old.size;
      final now = _clock();
      _index[name] = _TileEntry(size: bytes.length, storedAt: now, usedAt: now);
      _bytes += bytes.length;
      if (_bytes > maxBytesBudget + maxBytesBudget ~/ 10) prune(maxBytes: maxBytesBudget).ignore();
    } catch (e) {
      debugPrint('tile store note: ${e.runtimeType}');
    }
  }

  /// Drops tiles older than [maxAgeDays], then the least recently used until under [maxBytes].
  /// Active trip tiles pinned in [_activeTripTiles] are NEVER pruned.
  Future<void> prune({int? maxBytes, int maxAgeDays = SafetyConstants.tileMaxAgeDays}) async {
    if (_pruning) return;
    _pruning = true;
    try {
      final effectiveMaxBytes = maxBytes ?? maxBytesBudget;
      final now = _clock();
      final doomed = <String>[];
      _index.forEach((name, e) {
        // Active trip tiles are never pruned regardless of age
        if (_activeTripTiles.contains(name)) return;
        if (now - e.storedAt > maxAgeDays * 86400000) doomed.add(name);
      });
      if (_bytes - _sizeOf(doomed) > effectiveMaxBytes) {
        final rest = _index.keys
            .where((n) => !_activeTripTiles.contains(n) && !doomed.contains(n))
            .toList()
          ..sort((a, b) => _index[a]!.usedAt.compareTo(_index[b]!.usedAt));
        var bytes = _bytes - _sizeOf(doomed);
        for (final n in rest) {
          if (bytes <= effectiveMaxBytes) break;
          doomed.add(n);
          bytes -= _index[n]!.size;
        }
      }
      for (final n in doomed) {
        await _delete(n);
      }
    } finally {
      _pruning = false;
    }
  }

  /// Removes every saved tile.
  Future<void> clear() async {
    for (final n in _index.keys.toList()) {
      await _delete(n);
    }
  }

  int _sizeOf(List<String> names) {
    var s = 0;
    for (final n in names) {
      s += _index[n]?.size ?? 0;
    }
    return s;
  }

  Future<void> _delete(String name) async {
    final e = _index.remove(name);
    if (e != null) _bytes -= e.size;
    try {
      final f = File(_path(name));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

class _TileEntry {
  final int size;
  final int storedAt;
  int usedAt;
  _TileEntry({required this.size, required this.storedAt, required this.usedAt});
}

/// flutter_map tile provider: the saved tile first, else the network (with the
/// app's User-Agent, as the OSM tile policy asks), saved after the download.
/// A failed download behaves like [NetworkTileProvider] (error tile path).
class CachedTileProvider extends TileProvider {
  CachedTileProvider({TileCache? cache, http.Client? client, this.offlineOnly = false})
      : _cache = cache ?? TileCache.instance,
        _client = client ?? TileCache.sharedHttpClient,
        _ownsClient = client != null && client != TileCache.sharedHttpClient,
        super(headers: {'User-Agent': AppConstants.osmUserAgent});

  final TileCache? _cache;
  final http.Client _client;
  final bool _ownsClient;
  final bool offlineOnly;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) => CachedTileImage(
        url: getTileUrl(coordinates, options),
        z: coordinates.z,
        x: coordinates.x,
        y: coordinates.y,
        cache: _cache,
        client: _client,
        headers: headers,
        offlineOnly: offlineOnly,
      );

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }
}

/// One tile image: disk, else HTTP GET then store. Equal by URL so Flutter's
/// memory image cache works as for network tiles.
class CachedTileImage extends ImageProvider<CachedTileImage> {
  const CachedTileImage({
    required this.url,
    required this.z,
    required this.x,
    required this.y,
    required this.cache,
    required this.client,
    required this.headers,
    this.offlineOnly = false,
  });

  final String url;
  final int z;
  final int x;
  final int y;
  final TileCache? cache;
  final http.Client client;
  final Map<String, String> headers;
  final bool offlineOnly;

  static final Uint8List transparentPngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
  );

  @override
  Future<CachedTileImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture<CachedTileImage>(this);

  @override
  ImageStreamCompleter loadImage(CachedTileImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1, debugLabel: url);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final saved = cache?.lookup(z, x, y);
    if (saved != null) {
      try {
        final bytes = await saved.readAsBytes();
        if (bytes.isNotEmpty) return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
      } catch (_) {
        // unreadable file: fetched again below
      }
    }
    if (offlineOnly) {
      return await decode(await ui.ImmutableBuffer.fromUint8List(transparentPngBytes));
    }
    try {
      final uri = Uri.parse(url);
      final res = await client.get(uri, headers: headers).timeout(SafetyConstants.prefetchTimeout);
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        cache?.store(z, x, y, res.bodyBytes).ignore();
        return await decode(await ui.ImmutableBuffer.fromUint8List(res.bodyBytes));
      }
    } catch (_) {}

    // Fallback: Check if lower-resolution parent tile is in cache to prevent blank flashing
    if (cache != null && z > 1) {
      final parentTile = cache!.lookup(z - 1, x >> 1, y >> 1);
      if (parentTile != null) {
        try {
          final parentBytes = await parentTile.readAsBytes();
          if (parentBytes.isNotEmpty) {
            return await decode(await ui.ImmutableBuffer.fromUint8List(parentBytes));
          }
        } catch (_) {}
      }
    }

    return decode(await ui.ImmutableBuffer.fromUint8List(transparentPngBytes));
  }

  @override
  bool operator ==(Object other) => other is CachedTileImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// Saves the tiles along the planned route before a ride (one bounded job:
/// at most [SafetyConstants.prefetchMaxTiles] tiles at zoom 12 and 14,
/// [SafetyConstants.prefetchParallel] in flight, [SafetyConstants.prefetchSpacing]
/// apart, with the app's User-Agent). Started by SafetyService on Wi-Fi or by
/// the rider's "Save route map" tap; cancellable; progress for the sheet line.
class TilePrefetcher extends ChangeNotifier {
  TilePrefetcher(this._cache, {http.Client? client, int Function()? clock, Duration? spacing})
      : _client = client ?? http.Client(),
        _clock = clock ?? TileCache._wallClock,
        _spacing = spacing ?? SafetyConstants.prefetchSpacing {
    TileCacheService.registerWorker(this);
  }

  final TileCache? _cache;
  final http.Client _client;
  final int Function() _clock;
  final Duration _spacing;

  bool _running = false;
  bool _cancel = false;
  bool _paused = false;
  bool _lowBattery = false;
  int _done = 0;
  int _total = 0;
  int _saved = 0;
  int _failed = 0;
  String? _error;
  String? _label;
  int _lastNotify = 0;
  int _finishedAt = 0;

  bool get running => _running;
  int get done => _done;
  int get total => _total;

  /// Whether prefetching is paused due to low battery or manual request.
  bool get isPaused => _paused;

  /// Whether low battery (< 20%) is detected and active.
  bool get isLowBattery => _lowBattery;

  /// Pauses active and background prefetching.
  void pause({String reason = 'paused'}) {
    _paused = true;
    _error = reason;
    if (_running) {
      _cancel = true;
    }
    notifyListeners();
  }

  /// Resumes prefetching when normal power conditions return.
  void resume() {
    if (!_paused && !_lowBattery) return;
    _paused = false;
    _lowBattery = false;
    if (_error == 'low_battery' || _error == 'paused') {
      _error = null;
    }
    notifyListeners();
  }

  /// Handles low battery state transitions (< 20%):
  /// Pauses nonessential tile prefetching when battery is critical.
  void handleLowBattery(bool lowBattery) {
    if (_lowBattery == lowBattery) return;
    _lowBattery = lowBattery;
    if (lowBattery) {
      pause(reason: 'low_battery');
    } else {
      resume();
    }
  }

  /// Tiles downloaded in the last job (the rest were already saved).
  int get saved => _saved;
  int get failed => _failed;

  /// 'network' when the job stopped after repeated failures, 'storage' without a cache, else null.
  String? get error => _error;

  /// The convoy the last job was for.
  String? get label => _label;

  /// A job finished (completely) at this time; 0 before the first one.
  int get finishedAt => _finishedAt;

  /// Finished without an error and not cancelled.
  bool get complete => !_running && _finishedAt > 0 && _error == null && _total > 0 && _done >= _total;

  /// Default lateral corridor buffering radius (2.5 km Minkowski corridor).
  static const double corridorLateralRadiusM = SafetyConstants.prefetchCorridorRadiusM;

  /// Hook for future Play Store / App Store IAP feature entitlements.
  /// Currently unlocked for all riders by default via [FeatureGates.isUnlocked].
  static bool get hasUnlimitedOfflinePacks =>
      FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks);

  /// Checks whether all tiles along [line] are already saved in the local cache.
  bool isRouteCached(
    List<(double, double)> line, {
    bool highDetail = false,
    Set<(int, int, int)>? precomputedTiles,
  }) {
    final cache = _cache;
    if (cache == null || line.isEmpty) return false;
    final tiles = precomputedTiles ?? tilesAlong(line, highDetail: highDetail);
    if (tiles.isEmpty) return false;
    for (final t in tiles) {
      if (cache.lookup(t.$1, t.$2, t.$3) == null) {
        return false;
      }
    }
    return true;
  }

  /// Counts how many tiles along [line] are already saved in the local cache.
  int countCachedTiles(
    List<(double, double)> line, {
    bool highDetail = false,
    Set<(int, int, int)>? precomputedTiles,
  }) {
    final cache = _cache;
    if (cache == null || line.isEmpty) return 0;
    final tiles = precomputedTiles ?? tilesAlong(line, highDetail: highDetail);
    var count = 0;
    for (final t in tiles) {
      if (cache.lookup(t.$1, t.$2, t.$3) != null) {
        count++;
      }
    }
    return count;
  }

  /// Web Mercator tile of a point.
  static (int, int) tileOf(double lat, double lng, int z) {
    final n = 1 << z;
    final x = ((lng + 180) / 360 * n).floor();
    final latR = lat.clamp(-85.05112878, 85.05112878) * math.pi / 180;
    final y = ((1 - math.log(math.tan(latR) + 1 / math.cos(latR)) / math.pi) / 2 * n).floor();
    return (x.clamp(0, n - 1).toInt(), y.clamp(0, n - 1).toInt());
  }

  /// Returns all tiles covering a circular lateral radius of [radiusM] around [lat, lng]
  /// for the specified [zooms] (defaults to [SafetyConstants.prefetchZooms]).
  static Set<(int, int, int)> tilesAroundPoint(
    double lat,
    double lng, {
    List<int>? zooms,
    double radiusM = corridorLateralRadiusM,
  }) {
    final effectiveZooms = zooms ?? SafetyConstants.prefetchZooms;
    final out = <(int, int, int)>{};
    final latRad = lat.clamp(-85.05112878, 85.05112878) * math.pi / 180;
    final cosLat = math.cos(latRad).abs();

    for (final z in effectiveZooms) {
      final t = tileOf(lat, lng, z);
      final n = 1 << z;
      out.add((z, t.$1, t.$2));

      // Conformal Web Mercator ground resolution at latitude (meters per tile):
      final metersPerTile = (40075016.686 * cosLat) / n;
      final radiusTiles = radiusM / metersPerTile;
      final r = math.max(1, radiusTiles.ceil());
      final maxDistM = radiusM + metersPerTile * 0.5;
      final maxDistSq = maxDistM * maxDistM;
      final mptSq = metersPerTile * metersPerTile;

      for (var dx = -r; dx <= r; dx++) {
        for (var dy = -r; dy <= r; dy++) {
          if (dx == 0 && dy == 0) continue;
          final distSq = (dx * dx + dy * dy) * mptSq;
          if (distSq <= maxDistSq) {
            final x = t.$1 + dx;
            final y = t.$2 + dy;
            if (x >= 0 && y >= 0 && x < n && y < n) {
              out.add((z, x, y));
            }
          }
        }
      }
    }
    return out;
  }

  /// Automatically computes the complete offline map tile footprint required for an active ride:
  /// 1. Active route corridor (2.5 km lateral corridor)
  /// 2. Rider current location (2.5 km lateral buffer)
  /// 3. Planned stops (2.5 km buffer around each)
  /// 4. Destination (2.5 km buffer)
  /// 5. Nearby group members / convoy riders (2.5 km buffer around each)
  static Set<(int, int, int)> tilesForActiveRide({
    required List<(double, double)> routeLine,
    (double, double)? riderLocation,
    List<(double, double)> stops = const [],
    (double, double)? destination,
    List<(double, double)> groupMembers = const [],
    List<int>? zooms,
    double corridorRadiusM = corridorLateralRadiusM,
    bool highDetail = false,
    int? maxTiles,
  }) {
    final effectiveZooms = zooms ??
        (highDetail
            ? SafetyConstants.prefetchZoomsHighDetail
            : SafetyConstants.prefetchZooms);

    final out = <(int, int, int)>{};

    // 1. Active route corridor (2.5 km lateral buffer)
    if (routeLine.isNotEmpty) {
      out.addAll(tilesAlong(
        routeLine,
        zooms: effectiveZooms,
        corridorRadiusM: corridorRadiusM,
        highDetail: highDetail,
        maxTiles: maxTiles,
      ));
    }

    // 2. Rider current location (2.5 km buffer)
    if (riderLocation != null && riderLocation.$1 != 0.0 && riderLocation.$2 != 0.0) {
      out.addAll(tilesAroundPoint(
        riderLocation.$1,
        riderLocation.$2,
        zooms: effectiveZooms,
        radiusM: corridorRadiusM,
      ));
    }

    // 3. Planned stops (2.5 km buffer)
    for (final s in stops) {
      if (s.$1 != 0.0 && s.$2 != 0.0) {
        out.addAll(tilesAroundPoint(
          s.$1,
          s.$2,
          zooms: effectiveZooms,
          radiusM: corridorRadiusM,
        ));
      }
    }

    // 4. Destination (2.5 km buffer)
    if (destination != null && destination.$1 != 0.0 && destination.$2 != 0.0) {
      out.addAll(tilesAroundPoint(
        destination.$1,
        destination.$2,
        zooms: effectiveZooms,
        radiusM: corridorRadiusM,
      ));
    }

    // 5. Nearby group members (2.5 km buffer)
    for (final m in groupMembers) {
      if (m.$1 != 0.0 && m.$2 != 0.0) {
        out.addAll(tilesAroundPoint(
          m.$1,
          m.$2,
          zooms: effectiveZooms,
          radiusM: corridorRadiusM,
        ));
      }
    }

    return out;
  }

  /// The tiles to save: 2.5 km lateral corridor buffering along [line] for offline prefetching.
  /// Covers intermediate zoom levels (11, 12, 13, 14, 15, 16) so riders zooming at speed
  /// do not hit blank tiles. When [highDetail] is true, includes zoom 17 for junction labels.
  /// Governed by [FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks)] for entitlement quotas.
  static Set<(int, int, int)> tilesAlong(
    List<(double, double)> line, {
    List<int>? zooms,
    int? maxTiles,
    bool highDetail = false,
    double corridorRadiusM = corridorLateralRadiusM,
  }) {
    final effectiveZooms = zooms ??
        (highDetail
            ? SafetyConstants.prefetchZoomsHighDetail
            : SafetyConstants.prefetchZooms);

    final isUnlimited = FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks);
    final defaultMax = isUnlimited
        ? (highDetail ? SafetyConstants.prefetchMaxTilesHighDetail : SafetyConstants.prefetchMaxTiles)
        : (highDetail ? SafetyConstants.prefetchMaxTiles : SafetyConstants.prefetchMaxTilesCommunity);
    final effectiveMaxTiles = maxTiles ?? defaultMax;
    if (line.isEmpty || effectiveZooms.isEmpty) return <(int, int, int)>{};

    // For long dense routes (e.g. 5,000 to 35,000 points), simplify with 25m tolerance
    // before computing corridor sampling. The corridor buffer is 2,500m wide, so 25m tolerance
    // (1% of corridor width) yields identical tile coverage while avoiding 35,000 haversine loops.
    final inputLine = line.length > 1500 ? GeoMath.simplify(line, toleranceM: 25.0) : line;
    final samples = _sample(inputLine, SafetyConstants.prefetchSampleM);
    final out = <(int, int, int)>{};

    for (var i = 0; i < samples.length; i++) {
      final p = samples[i];
      final isKeyPoint = i == 0 || i == samples.length - 1 || (i % 5 == 0);
      final latRad = p.$1.clamp(-85.05112878, 85.05112878) * math.pi / 180;
      final cosLat = math.cos(latRad).abs();

      for (final z in effectiveZooms) {
        final t = tileOf(p.$1, p.$2, z);
        final n = 1 << z;
        out.add((z, t.$1, t.$2));

        // Lateral 2.5 km corridor buffering
        // Conformal Web Mercator ground resolution at latitude (meters per tile):
        final metersPerTile = (40075016.686 * cosLat) / n;
        final radiusTiles = corridorRadiusM / metersPerTile;
        final r = math.max(1, radiusTiles.ceil());
        final maxDistM = corridorRadiusM + metersPerTile * 0.5;
        final maxDistSq = maxDistM * maxDistM;
        final mptSq = metersPerTile * metersPerTile;

        // Optimization: for extreme high-detail z17, expand on key points or endpoints
        if (z == 17 && !isKeyPoint) continue;

        for (var dx = -r; dx <= r; dx++) {
          for (var dy = -r; dy <= r; dy++) {
            if (dx == 0 && dy == 0) continue;
            final distSq = (dx * dx + dy * dy) * mptSq;
            if (distSq <= maxDistSq) {
              final x = t.$1 + dx;
              final y = t.$2 + dy;
              if (x >= 0 && y >= 0 && x < n && y < n) {
                out.add((z, x, y));
              }
            }
          }
        }
      }
    }

    if (out.length <= effectiveMaxTiles) return out;

    // Keep overview everywhere; drop detail tiles from the far end until it fits within budget.
    final list = out.toList();
    final detailZooms = effectiveZooms.where((z) => z >= 14).toList()
      ..sort((a, b) => b.compareTo(a));

    for (final dz in detailZooms) {
      for (var i = list.length - 1; i >= 0 && list.length > effectiveMaxTiles; i--) {
        if (list[i].$1 == dz) list.removeAt(i);
      }
    }
    while (list.length > effectiveMaxTiles) {
      list.removeLast();
    }
    return list.toSet();
  }

  /// Asynchronously computes tiles along route with periodic event loop yields
  /// to ensure the Flutter UI thread is NEVER blocked on dense routes.
  static Future<Set<(int, int, int)>> tilesAlongAsync(
    List<(double, double)> line, {
    List<int>? zooms,
    int? maxTiles,
    bool highDetail = false,
    double corridorRadiusM = corridorLateralRadiusM,
  }) async {
    if (line.isEmpty) return <(int, int, int)>{};
    if (line.length <= 300) {
      return tilesAlong(line, zooms: zooms, maxTiles: maxTiles, highDetail: highDetail, corridorRadiusM: corridorRadiusM);
    }

    final inputLine = line.length > 1500 ? GeoMath.simplify(line, toleranceM: 25.0) : line;
    final samples = _sample(inputLine, SafetyConstants.prefetchSampleM);
    final effectiveZooms = zooms ??
        (highDetail ? SafetyConstants.prefetchZoomsHighDetail : SafetyConstants.prefetchZooms);
    final isUnlimited = FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks);
    final defaultMax = isUnlimited
        ? (highDetail ? SafetyConstants.prefetchMaxTilesHighDetail : SafetyConstants.prefetchMaxTiles)
        : (highDetail ? SafetyConstants.prefetchMaxTiles : SafetyConstants.prefetchMaxTilesCommunity);
    final effectiveMaxTiles = maxTiles ?? defaultMax;

    final out = <(int, int, int)>{};

    for (var i = 0; i < samples.length; i++) {
      if (i > 0 && i % 150 == 0) {
        // Yield to UI event loop to preserve 60 fps rendering
        await Future<void>.delayed(Duration.zero);
      }
      final p = samples[i];
      final isKeyPoint = i == 0 || i == samples.length - 1 || (i % 5 == 0);
      final latRad = p.$1.clamp(-85.05112878, 85.05112878) * math.pi / 180;
      final cosLat = math.cos(latRad).abs();

      for (final z in effectiveZooms) {
        final t = tileOf(p.$1, p.$2, z);
        final n = 1 << z;
        out.add((z, t.$1, t.$2));

        final metersPerTile = (40075016.686 * cosLat) / n;
        final radiusTiles = corridorRadiusM / metersPerTile;
        final r = math.max(1, radiusTiles.ceil());
        final maxDistM = corridorRadiusM + metersPerTile * 0.5;
        final maxDistSq = maxDistM * maxDistM;
        final mptSq = metersPerTile * metersPerTile;

        if (z == 17 && !isKeyPoint) continue;

        for (var dx = -r; dx <= r; dx++) {
          for (var dy = -r; dy <= r; dy++) {
            if (dx == 0 && dy == 0) continue;
            final distSq = (dx * dx + dy * dy) * mptSq;
            if (distSq <= maxDistSq) {
              final x = t.$1 + dx;
              final y = t.$2 + dy;
              if (x >= 0 && y >= 0 && x < n && y < n) {
                out.add((z, x, y));
              }
            }
          }
        }
      }
    }

    if (out.length <= effectiveMaxTiles) return out;

    final list = out.toList();
    final detailZooms = effectiveZooms.where((z) => z >= 14).toList()
      ..sort((a, b) => b.compareTo(a));

    for (final dz in detailZooms) {
      for (var i = list.length - 1; i >= 0 && list.length > effectiveMaxTiles; i--) {
        if (list[i].$1 == dz) list.removeAt(i);
      }
    }
    while (list.length > effectiveMaxTiles) {
      list.removeLast();
    }
    return list.toSet();
  }

  static List<(double, double)> _sample(List<(double, double)> line, double everyM) {
    final out = <(double, double)>[line.first];
    var carry = 0.0;
    for (var i = 1; i < line.length; i++) {
      final a = line[i - 1], b = line[i];
      final seg = GeoMath.haversine(a.$1, a.$2, b.$1, b.$2);
      if (seg <= 0) continue;
      var d = everyM - carry;
      while (d <= seg) {
        final t = d / seg;
        out.add((a.$1 + (b.$1 - a.$1) * t, a.$2 + (b.$2 - a.$2) * t));
        d += everyM;
      }
      carry = seg - (d - everyM);
    }
    if (out.last != line.last) out.add(line.last);
    return out;
  }

  /// Saves the tiles along [line]. Returns when the job ends (done, cancelled or
  /// stopped after [SafetyConstants.prefetchMaxFailures] failures in a row).
  Future<void> start(
    List<(double, double)> line, {
    required String label,
    bool highDetail = false,
  }) async {
    if (_running) return;
    if (_paused || _lowBattery) {
      _error = _lowBattery ? 'low_battery' : 'paused';
      _finishedAt = _clock();
      notifyListeners();
      return;
    }

    // Check future IAP entitlement hook via FeatureGates
    if (!FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks)) {
      final existingPacks = await SavedMapPackStore.loadAll();
      if (existingPacks.length >= SafetyConstants.freeOfflinePacksLimit &&
          !existingPacks.any((p) => p.name == label)) {
        _error = 'entitlement_required';
        _finishedAt = _clock();
        notifyListeners();
        return;
      }
    }

    final cache = _cache;
    _label = label;
    _cancel = false;
    _done = 0;
    _saved = 0;
    _failed = 0;
    _error = cache == null ? 'storage' : null;
    final tiles = cache == null
        ? const <(int, int, int)>[]
        : tilesAlong(line, highDetail: highDetail).toList();
    if (cache != null && tiles.isNotEmpty) {
      cache.registerActiveTripTiles(tiles);
    }
    _total = tiles.length;
    if (cache == null || tiles.isEmpty) {
      _finishedAt = _clock();
      notifyListeners();
      return;
    }
    _running = true;
    notifyListeners();
    var consecutive = 0;
    final pending = <Future<void>>{};
    try {
      for (final t in tiles) {
        if (_cancel || _paused || _lowBattery || consecutive >= SafetyConstants.prefetchMaxFailures) break;
        if (cache.lookup(t.$1, t.$2, t.$3) != null) {
          _done++;
          _maybeNotify();
          continue;
        }
        while (pending.length >= SafetyConstants.prefetchParallel) {
          await Future.any(pending.toList());
        }
        late Future<void> f;
        f = _fetch(cache, t).then((ok) {
          if (ok) {
            consecutive = 0;
            _saved++;
          } else {
            consecutive++;
            _failed++;
          }
          _done++;
          pending.remove(f);
          _maybeNotify();
        });
        pending.add(f);
        if (_spacing > Duration.zero) await Future<void>.delayed(_spacing);
      }
      if (pending.isNotEmpty) await Future.wait(pending.toList());
      if (consecutive >= SafetyConstants.prefetchMaxFailures) _error = 'network';
      if (_error == null && !_cancel && _done >= _total) {
        try {
          final pack = SavedMapPack(
            id: 'pack_${DateTime.now().millisecondsSinceEpoch}',
            name: label,
            downloadedAt: DateTime.now(),
            highDetail: highDetail,
            zooms: highDetail ? SafetyConstants.prefetchZoomsHighDetail : SafetyConstants.prefetchZooms,
            tileCount: _total,
            estimatedBytes: _total * 25 * 1024,
            polyline: line,
          );
          SavedMapPackStore.save(pack).ignore();
        } catch (_) {}
      }
    } finally {
      _running = false;
      _finishedAt = _clock();
      cache.prune().ignore();
      notifyListeners();
    }
  }

  /// Automatically prepares map tiles around rider location, active route corridor (2.5 km),
  /// stops, destination, and nearby group members in a low-priority background process
  /// without manual download screens during normal riding.
  /// Tiles are registered in [TileCache] as active trip tiles so they are NEVER deleted by LRU pruning.
  Future<void> prepareActiveRide({
    required List<(double, double)> routeLine,
    (double, double)? riderLocation,
    List<(double, double)> stops = const [],
    (double, double)? destination,
    List<(double, double)> groupMembers = const [],
    required String label,
    bool highDetail = false,
    Duration spacing = const Duration(milliseconds: 150),
  }) async {
    final cache = _cache;
    if (cache == null) return;

    final allTiles = tilesForActiveRide(
      routeLine: routeLine,
      riderLocation: riderLocation,
      stops: stops,
      destination: destination,
      groupMembers: groupMembers,
      highDetail: highDetail,
    );

    // Register tiles as active trip tiles immediately to protect them from pruning
    cache.registerActiveTripTiles(allTiles);

    if (_running || _paused || _lowBattery) {
      // Background worker already running or low battery pauses nonessential prefetching
      return;
    }

    final uncached = allTiles.where((t) => cache.lookup(t.$1, t.$2, t.$3) == null).toList();
    if (uncached.isEmpty) {
      return;
    }

    _running = true;
    _label = label;
    _cancel = false;
    _total = uncached.length;
    _done = 0;
    _saved = 0;
    _failed = 0;
    _error = null;
    notifyListeners();

    var consecutive = 0;
    final pending = <Future<void>>{};

    try {
      for (final t in uncached) {
        if (_cancel || _paused || _lowBattery || consecutive >= SafetyConstants.prefetchMaxFailures) break;
        if (cache.lookup(t.$1, t.$2, t.$3) != null) {
          _done++;
          continue;
        }

        while (pending.length >= SafetyConstants.prefetchParallel) {
          await Future.any(pending.toList());
        }

        late Future<void> f;
        f = _fetch(cache, t).then((ok) {
          if (ok) {
            consecutive = 0;
            _saved++;
          } else {
            consecutive++;
            _failed++;
          }
          _done++;
          pending.remove(f);
          _maybeNotify();
        });
        pending.add(f);

        if (spacing > Duration.zero) {
          await Future<void>.delayed(spacing);
        }
      }

      if (pending.isNotEmpty) {
        await Future.wait(pending.toList());
      }
      if (consecutive >= SafetyConstants.prefetchMaxFailures) {
        _error = 'network';
      }
    } catch (_) {
      // Quiet background failure
    } finally {
      _running = false;
      _finishedAt = _clock();
      cache.prune(maxBytes: cache.maxBytesBudget).ignore();
      notifyListeners();
    }
  }

  /// Seamless invisible background route corridor tile prefetch (FEAT-MAP-01).
  /// Runs automatically after trip creation without blocking the UI or requiring
  /// separate manual download screens.
  /// Respects battery (< 20%) and network conditions.
  Future<void> prefetchCorridorBackground({
    required List<(double, double)> routeLine,
    required String label,
    (double, double)? riderLocation,
    List<(double, double)> stops = const [],
    (double, double)? destination,
    bool highDetail = false,
  }) async {
    // Check battery level (< 20%) before starting background prefetch
    try {
      final battery = Battery();
      final level = await battery.batteryLevel;
      if (level < 20) {
        handleLowBattery(true);
        return;
      }
    } catch (_) {}

    await prepareActiveRide(
      routeLine: routeLine,
      riderLocation: riderLocation,
      stops: stops,
      destination: destination,
      label: label,
      highDetail: highDetail,
    );
  }

  /// Checks whether all tiles for the active ride are already in the local cache.
  bool isRidePrepared({
    required List<(double, double)> routeLine,
    (double, double)? riderLocation,
    List<(double, double)> stops = const [],
    (double, double)? destination,
    List<(double, double)> groupMembers = const [],
    bool highDetail = false,
  }) {
    final cache = _cache;
    if (cache == null) return false;
    final tiles = tilesForActiveRide(
      routeLine: routeLine,
      riderLocation: riderLocation,
      stops: stops,
      destination: destination,
      groupMembers: groupMembers,
      highDetail: highDetail,
    );
    if (tiles.isEmpty) return false;
    for (final t in tiles) {
      if (cache.lookup(t.$1, t.$2, t.$3) == null) return false;
    }
    return true;
  }

  Future<bool> _fetch(TileCache cache, (int, int, int) t) async {
    final url = AppConstants.osmTileUrl.replaceAll('{z}', '${t.$1}').replaceAll('{x}', '${t.$2}').replaceAll('{y}', '${t.$3}');
    try {
      final res = await _client.get(Uri.parse(url), headers: {'User-Agent': AppConstants.osmUserAgent}).timeout(SafetyConstants.prefetchTimeout);
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return false;
      await cache.store(t.$1, t.$2, t.$3, res.bodyBytes);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _maybeNotify() {
    final now = _clock();
    if (now - _lastNotify < 500) return;
    _lastNotify = now;
    notifyListeners();
  }

  /// Stops the job after the tiles in flight.
  void cancel() {
    if (!_running) return;
    _cancel = true;
  }

  @override
  void dispose() {
    _cancel = true;
    _client.close();
    super.dispose();
  }
}

/// Convenient global handle to the prefetch worker for background operations (FEAT-MAP-01).
class TileCacheService {
  TileCacheService._();
  static TilePrefetcher? _worker;
  static TilePrefetcher? get prefetchWorker =>
      _worker ??
      (TileCache.instance != null ? (_worker = TilePrefetcher(TileCache.instance)) : null);

  static void registerWorker(TilePrefetcher worker) {
    _worker = worker;
  }
}
