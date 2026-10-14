import 'dart:async';
import 'dart:convert' show base64Decode;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
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
  TileCache._(this.dir, this._clock);

  /// Set once by main.dart after [open]; null means maps use the plain network provider.
  static TileCache? instance;

  final Directory dir;
  final int Function() _clock;
  final Map<String, _TileEntry> _index = {};
  int _bytes = 0;
  bool _pruning = false;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// Opens (creates) the folder, indexes what is there and prunes. Null when the
  /// folder cannot be used; the caller then leaves [instance] null.
  static Future<TileCache?> open(String dir, {int Function()? clock}) async {
    try {
      final d = Directory(dir);
      await d.create(recursive: true);
      final c = TileCache._(d, clock ?? _wallClock);
      await c._scan();
      await c.prune();
      return c;
    } catch (e) {
      debugPrint('tile cache note: ${e.runtimeType}');
      return null;
    }
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
  Future<void> deleteTiles(Iterable<(int, int, int)> tiles) async {
    for (final t in tiles) {
      await _delete(nameOf(t.$1, t.$2, t.$3));
    }
  }

  /// The saved tile, when it exists and is not older than [maxAgeDays]. Cheap (memory index).
  File? lookup(int z, int x, int y, {int maxAgeDays = SafetyConstants.tileMaxAgeDays}) {
    final name = nameOf(z, x, y);
    final e = _index[name];
    if (e == null) return null;
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
      if (_bytes > SafetyConstants.tileCacheMaxBytes + SafetyConstants.tileCacheMaxBytes ~/ 10) prune().ignore();
    } catch (e) {
      debugPrint('tile store note: ${e.runtimeType}');
    }
  }

  /// Drops tiles older than [maxAgeDays], then the least recently used until under [maxBytes].
  Future<void> prune({int maxBytes = SafetyConstants.tileCacheMaxBytes, int maxAgeDays = SafetyConstants.tileMaxAgeDays}) async {
    if (_pruning) return;
    _pruning = true;
    try {
      final now = _clock();
      final doomed = <String>[];
      _index.forEach((name, e) {
        if (now - e.storedAt > maxAgeDays * 86400000) doomed.add(name);
      });
      if (_bytes - _sizeOf(doomed) > maxBytes) {
        final rest = _index.keys.where((n) => !doomed.contains(n)).toList()..sort((a, b) => _index[a]!.usedAt.compareTo(_index[b]!.usedAt));
        var bytes = _bytes - _sizeOf(doomed);
        for (final n in rest) {
          if (bytes <= maxBytes) break;
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
        _client = client ?? http.Client(),
        _ownsClient = client == null,
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

  static final Uint8List _transparentPng = base64Decode(
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
      return await decode(await ui.ImmutableBuffer.fromUint8List(_transparentPng));
    }
    final uri = Uri.parse(url);
    final res = await client.get(uri, headers: headers).timeout(SafetyConstants.prefetchTimeout);
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
      throw NetworkImageLoadException(statusCode: res.statusCode, uri: uri);
    }
    cache?.store(z, x, y, res.bodyBytes).ignore();
    return decode(await ui.ImmutableBuffer.fromUint8List(res.bodyBytes));
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
        _spacing = spacing ?? SafetyConstants.prefetchSpacing;

  final TileCache? _cache;
  final http.Client _client;
  final int Function() _clock;
  final Duration _spacing;

  bool _running = false;
  bool _cancel = false;
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

  /// Checks whether all tiles along [line] are already saved in the local cache.
  bool isRouteCached(List<(double, double)> line, {bool highDetail = false}) {
    final cache = _cache;
    if (cache == null || line.isEmpty) return false;
    final tiles = tilesAlong(line, highDetail: highDetail);
    if (tiles.isEmpty) return false;
    for (final t in tiles) {
      if (cache.lookup(t.$1, t.$2, t.$3) == null) {
        return false;
      }
    }
    return true;
  }

  /// Counts how many tiles along [line] are already saved in the local cache.
  int countCachedTiles(List<(double, double)> line, {bool highDetail = false}) {
    final cache = _cache;
    if (cache == null || line.isEmpty) return 0;
    final tiles = tilesAlong(line, highDetail: highDetail);
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

  /// The tiles to save: for every point sampled each [SafetyConstants.prefetchSampleM]
  /// along [line], its tile at each zoom plus corridor neighbours.
  /// When [highDetail] is true, includes zooms 16 & 17 for street names, junction labels,
  /// and landmarks up to [SafetyConstants.prefetchMaxTilesHighDetail].
  static Set<(int, int, int)> tilesAlong(
    List<(double, double)> line, {
    List<int>? zooms,
    int? maxTiles,
    bool highDetail = false,
  }) {
    final effectiveZooms = zooms ?? (highDetail ? SafetyConstants.prefetchZoomsHighDetail : SafetyConstants.prefetchZooms);
    final effectiveMaxTiles = maxTiles ?? (highDetail ? SafetyConstants.prefetchMaxTilesHighDetail : SafetyConstants.prefetchMaxTiles);
    if (line.isEmpty || effectiveZooms.isEmpty) return <(int, int, int)>{};
    final detail = effectiveZooms.reduce(math.max);
    final samples = _sample(line, SafetyConstants.prefetchSampleM);
    final out = <(int, int, int)>{};
    for (var i = 0; i < samples.length; i++) {
      final p = samples[i];
      final isKeyPoint = i == 0 || i == samples.length - 1 || (i % 5 == 0);
      for (final z in effectiveZooms) {
        final t = tileOf(p.$1, p.$2, z);
        out.add((z, t.$1, t.$2));

        final shouldExpandNeighbors = (!highDetail && z == detail) ||
            (highDetail && z == 14) ||
            (highDetail && z == 16 && isKeyPoint) ||
            (highDetail && z == 17 && (i == 0 || i == samples.length - 1));

        if (shouldExpandNeighbors) {
          final n = 1 << z;
          for (var dx = -1; dx <= 1; dx++) {
            for (var dy = -1; dy <= 1; dy++) {
              if (dx == 0 && dy == 0) continue;
              final x = t.$1 + dx, y = t.$2 + dy;
              if (x < 0 || y < 0 || x >= n || y >= n) continue;
              out.add((z, x, y));
            }
          }
        }
      }
    }
    if (out.length <= effectiveMaxTiles) return out;
    // Keep the overview everywhere; drop detail tiles from the far end until it fits.
    final list = out.toList();
    for (var i = list.length - 1; i >= 0 && list.length > effectiveMaxTiles; i--) {
      if (list[i].$1 == detail) list.removeAt(i);
    }
    if (highDetail) {
      for (var i = list.length - 1; i >= 0 && list.length > effectiveMaxTiles; i--) {
        if (list[i].$1 == 16) list.removeAt(i);
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
    final cache = _cache;
    _label = label;
    _cancel = false;
    _done = 0;
    _saved = 0;
    _failed = 0;
    _error = cache == null ? 'storage' : null;
    final tiles = cache == null ? const <(int, int, int)>[] : tilesAlong(line, highDetail: highDetail).toList();
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
        if (_cancel || consecutive >= SafetyConstants.prefetchMaxFailures) break;
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
