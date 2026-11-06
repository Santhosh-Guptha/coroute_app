import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

import '../../domain/places/fuel_ahead.dart';
import '../../domain/places/fuel_match.dart';
import '../../domain/places/place_poi.dart';
import '../../domain/places/poi_category.dart';
import '../../domain/places/poi_declutter.dart';
import '../../domain/places/route_corridor.dart';
import '../../domain/tracking/geo_math.dart';
import 'api_client.dart';
import 'garage_service.dart';
import 'safety_native.dart';

/// Places of one grid cell, as fetched at [at] (epoch ms).
class PoiCellData {
  const PoiCellData(this.at, this.pois);
  final int at;
  final List<PlacePoi> pois;

  static PoiCellData? fromWire(Object? j) {
    if (j is! Map || j['at'] is! num || j['p'] is! List) return null;
    final pois = <PlacePoi>[];
    for (final e in j['p'] as List) {
      final poi = PlacePoi.fromWire(e);
      if (poi != null) pois.add(poi);
    }
    return PoiCellData((j['at'] as num).toInt(), pois);
  }

  Map<String, Object> toWire() => {'at': at, 'p': [for (final x in pois) x.toWire()]};
}

/// Where cells live on the phone between rides.
abstract class PoiCellStore {
  Future<PoiCellData?> read(String key);
  Future<void> write(String key, PoiCellData data);
}

class MemoryPoiCellStore implements PoiCellStore {
  final Map<String, PoiCellData> data = {};
  int reads = 0, writes = 0;
  @override
  Future<PoiCellData?> read(String key) async {
    reads++;
    return data[key];
  }

  @override
  Future<void> write(String key, PoiCellData d) async {
    writes++;
    data[key] = d;
  }
}

/// One small JSON file per cell in the app's own storage, pruned to [maxFiles].
class FilePoiCellStore implements PoiCellStore {
  FilePoiCellStore({this.maxFiles = 800});
  final int maxFiles;
  Future<Directory?>? _dir;
  int _writes = 0;
  Future<void> _io = Future.value();

  Future<Directory?> _open() => _dir ??= () async {
        String? base;
        try {
          base = await getDatabasesPath();
        } catch (_) {
          base = await SafetyNative.cacheDir();
        }
        if (base == null) return null;
        final d = Directory(p.join(base, 'map_places'));
        await d.create(recursive: true);
        return d;
      }()
          .catchError((Object _) => null);

  String _name(String key) => '${key.replaceAll(':', '_')}.json';

  @override
  Future<PoiCellData?> read(String key) async {
    try {
      final d = await _open();
      if (d == null) return null;
      final f = File(p.join(d.path, _name(key)));
      if (!await f.exists()) return null;
      return PoiCellData.fromWire(jsonDecode(await f.readAsString()));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, PoiCellData data) {
    final run = _io.then((_) async {
      final d = await _open();
      if (d == null) return;
      await File(p.join(d.path, _name(key))).writeAsString(jsonEncode(data.toWire()), flush: false);
      if (++_writes % 40 == 0) await _prune(d);
    });
    _io = run.catchError((Object _) {});
    return _io;
  }

  Future<void> _prune(Directory d) async {
    final files = <(File, int)>[];
    await for (final e in d.list(followLinks: false)) {
      if (e is File && e.path.endsWith('.json')) files.add((e, (await e.stat()).modified.millisecondsSinceEpoch));
    }
    if (files.length <= maxFiles) return;
    files.sort((a, b) => a.$2.compareTo(b.$2));
    for (final (f, _) in files.take(files.length - maxFiles)) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }
}

typedef PoiCellFetch = Future<Object?> Function(List<String> keys);

/// Map places on the phone. Fetches by grid cell, only what the rider needs:
/// the route corridor (2 km each side) in 20 km chunks ahead, or a small area
/// around the rider without a route, or the cells on screen while planning.
/// Cells are kept on disk for 7 days so a repeat trip costs nothing. No timer:
/// work happens only when the rider enters a new chunk/cell (or a retry is due
/// at such a moment). Filtering, fuel matching, along-route distances and
/// decluttering all run here on the phone.
class MapPlacesService extends ChangeNotifier {
  MapPlacesService({required this.fetch, PoiCellStore? store, int Function()? clock, this.prefsKey = 'map_places_categories_v1'})
      : _store = store ?? MemoryPoiCellStore(),
        _clock = clock ?? _wall;

  static int _wall() => DateTime.now().millisecondsSinceEpoch;

  static MapPlacesService? _shared;

  /// The app-wide instance (one cache for the ride map and the trip planner).
  static MapPlacesService shared(ApiClient api) {
    final existing = _shared;
    if (existing != null) return existing;
    final s = _shared = MapPlacesService(
      fetch: (keys) => api.get('/geo/poi-cells?cells=${keys.join(',')}', timeout: const Duration(seconds: 50)),
      store: FilePoiCellStore(),
    );
    s.loadPrefs();
    // The active bike's fuel type (the ride also sets it from the safety service).
    GarageService.readActiveBike().then((b) {
      if (b != null) s.fuelType = b.fuelType;
    }).ignore();
    return s;
  }

  static const int freshMs = 7 * 24 * 3600 * 1000;
  static const int batchSize = 12;
  static const int maxMemoryCells = 600;
  static const int maxAttempts = 6;
  static const int retryMs = 90 * 1000;

  final PoiCellFetch fetch;
  final PoiCellStore _store;
  final int Function() _clock;
  final String prefsKey;

  // ---------------------------------------------------------------- categories
  Set<PoiCategory> _enabled = {...defaultPoiCategories};
  Set<PoiCategory> get enabled => UnmodifiableSetView(_enabled);
  bool isEnabled(PoiCategory c) => _enabled.contains(c);

  Future<void> loadPrefs() async {
    try {
      final list = (await SharedPreferences.getInstance()).getStringList(prefsKey);
      if (list == null) return;
      _enabled = list.map(PoiCategoryInfo.byName).whereType<PoiCategory>().toSet();
      _visibleCache = null;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setEnabled(PoiCategory c, bool on) async {
    if (on == _enabled.contains(c)) return;
    on ? _enabled.add(c) : _enabled.remove(c);
    _visibleCache = null;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setStringList(prefsKey, [for (final x in _enabled) x.name]);
    } catch (_) {}
  }

  BikeFuelType _fuelType = BikeFuelType.petrol;
  BikeFuelType get fuelType => _fuelType;
  set fuelType(BikeFuelType t) {
    if (t == _fuelType) return;
    _fuelType = t;
    _visibleCache = null;
    notifyListeners();
  }

  /// Data saver: one chunk ahead, a smaller area, no browsing fetches.
  bool lowData = false;

  // ---------------------------------------------------------------- data
  final LinkedHashMap<String, PoiCellData> _cells = LinkedHashMap();
  final Set<String> _diskChecked = {};
  final Set<String> _pending = {};
  final Map<String, int> _attempts = {};
  int _version = 0;
  int get version => _version;
  List<PlacePoi>? _all;
  List<PlacePoi>? _visibleCache;

  bool hasCell(String key) => _cells.containsKey(key);
  int get cellCount => _cells.length;

  List<PlacePoi> get all {
    final cached = _all;
    if (cached != null) return cached;
    final seen = <String>{};
    final out = <PlacePoi>[];
    for (final c in _cells.values) {
      for (final x in c.pois) {
        if (seen.add(x.id)) out.add(x);
      }
    }
    return _all = out;
  }

  /// Whether a place is shown with the current chips and fuel type.
  bool shows(PlacePoi x) {
    switch (x.category) {
      case PoiCategory.ev:
        return _enabled.contains(PoiCategory.ev) || (_enabled.contains(PoiCategory.fuel) && _fuelType == BikeFuelType.ev);
      case PoiCategory.fuel:
        if (!_enabled.contains(PoiCategory.fuel) || _fuelType == BikeFuelType.ev) return false;
        return fuelMatch(x, _fuelType) != FuelMatch.noMatch;
      default:
        return _enabled.contains(x.category);
    }
  }

  /// Places shown with the current chips (all loaded cells).
  List<PlacePoi> get visible => _visibleCache ??= all.where(shows).toList(growable: false);

  // ---------------------------------------------------------------- route + rider
  RoutePath? _path;
  RouteCorridor? _corridor;
  RouteCursor? _cursor;
  String? _routeSig;
  List<ProjectedPoi>? _projected;
  List<({double lat, double lng, String name})> _groupStops = const [];
  List<({double alongM, String name})>? _groupProjected;
  int _lastChunk = -1;
  String? _lastAroundCell;
  double? lat, lng;

  bool get hasRoute => _corridor != null;
  double get progressM => _cursor?.progressM ?? 0;
  RoutePath? get path => _path;

  void setRoute(List<(double, double)>? line) {
    final sig = line == null || line.length < 2 ? null : '${line.length}|${line.first}|${line[line.length >> 1]}|${line.last}';
    if (sig == _routeSig) return;
    _routeSig = sig;
    final path = sig == null ? null : RoutePath(line!);
    _path = path != null && path.valid ? path : null;
    _corridor = _path == null ? null : RouteCorridor(_path!);
    _cursor = _path == null ? null : RouteCursor(_path!);
    _projected = null;
    _groupProjected = null;
    _lastChunk = -1;
    final la = lat, ln = lng;
    if (la != null && ln != null) onPosition(la, ln);
  }

  /// Planning: load the start of the route (two chunks) before the ride, so it is on the phone.
  void warmRouteStart() {
    final c = _corridor;
    if (c != null && !lowData) _want(c.cellsAhead(0, ahead: 1));
  }

  /// Planned group fuel stops (from the convoy), used by the fuel warning.
  void setGroupFuelStops(List<({double lat, double lng, String name})> stops) {
    if (listEquals(stops, _groupStops)) return;
    _groupStops = List.unmodifiable(stops);
    _groupProjected = null;
  }

  /// A new fix. Cheap: fetch work only when entering a new chunk or cell, or
  /// when a refused cell may be asked for again.
  void onPosition(double la, double ln) {
    if (!la.isFinite || !ln.isFinite || la.abs() > 90 || ln.abs() > 180 || (la == 0 && ln == 0)) return;
    lat = la;
    lng = ln;
    final c = _corridor, cur = _cursor;
    if (c != null && cur != null) {
      final m = cur.locate(la, ln);
      if (cur.offM <= 3000) {
        final chunk = c.chunkOf(m);
        if (chunk != _lastChunk || _retryDue()) {
          _lastChunk = chunk;
          _want(c.cellsAhead(m, ahead: lowData ? 1 : 2));
        }
        return;
      }
    }
    final cell = PoiCells.keyOf(la, ln);
    if (cell != _lastAroundCell || _retryDue()) {
      _lastAroundCell = cell;
      _want(PoiCells.around(la, ln, lowData ? 2500 : 5000));
    }
  }

  /// Browsing a map (trip planner): the cells on screen, nearest the centre first, one batch.
  void onViewport({required double s, required double w, required double n, required double e, required double zoom}) {
    if (zoom < PoiZoom.iconsFrom || lowData) return;
    final keys = PoiCells.inBox(s, w, n, e, cLat: (s + n) / 2, cLng: (w + e) / 2);
    if (keys.isEmpty) return;
    _want(keys.take(batchSize).toList());
  }

  // ---------------------------------------------------------------- fetching
  List<String> _wanted = const [];
  bool _busy = false, _again = false;
  int _nextRetryAt = 0, _blockedUntil = 0;
  bool offline = false;
  String? lastError;
  int requests = 0;

  bool _retryDue() => _pending.isNotEmpty && _clock() >= _nextRetryAt && _clock() >= _blockedUntil;

  void _want(List<String> keys) {
    _wanted = keys;
    if (_busy) {
      _again = true;
      return;
    }
    unawaited(_pump());
  }

  /// Resolves when the current fetch round is done (tests).
  @visibleForTesting
  Future<void> idle() async {
    while (_busy) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> _pump() async {
    _busy = true;
    try {
      final wanted = _wanted;
      _pending.removeWhere((k) => !wanted.contains(k)); // the rider moved on
      var changed = false;
      for (final k in wanted) {
        if (_cells.containsKey(k) || !_diskChecked.add(k)) continue;
        final d = await _store.read(k).catchError((Object _) => null);
        if (d != null && (!_cells.containsKey(k) || _cells[k]!.at < d.at)) {
          _put(k, d);
          changed = true;
        }
      }
      if (changed) _changed();
      final now = _clock();
      if (now < _blockedUntil) return;
      final need = wanted.where((k) {
        final c = _cells[k];
        if (c != null && now - c.at < freshMs) return false;
        if ((_attempts[k] ?? 0) < maxAttempts) return true;
        _pending.remove(k); // given up for this session
        return false;
      }).toList();
      var rounds = 0;
      while (need.isNotEmpty && rounds < 4) {
        rounds++;
        final keys = need.take(batchSize).toList();
        need.removeRange(0, keys.length);
        for (final k in keys) {
          _attempts[k] = (_attempts[k] ?? 0) + 1;
        }
        Object? res;
        try {
          requests++;
          res = await fetch(keys);
          offline = false;
          lastError = null;
        } catch (e) {
          _pending.addAll(keys); // asked again at a later fix, after the pause
          _onError(e);
          break;
        }
        final got = <String>{};
        if (res is Map && res['cells'] is Map) {
          for (final entry in (res['cells'] as Map).entries) {
            final k = entry.key;
            final d = PoiCellData.fromWire(entry.value);
            if (k is! String || d == null) continue;
            got.add(k);
            final fresh = !(entry.value is Map && (entry.value as Map)['stale'] == true);
            _put(k, d);
            if (fresh) {
              _attempts.remove(k);
              _pending.remove(k);
              unawaited(_store.write(k, d).catchError((Object _) {}));
            }
          }
        }
        final pend = res is Map && res['pending'] is List ? (res['pending'] as List).whereType<String>().toSet() : <String>{};
        for (final k in keys) {
          if (pend.contains(k) || !got.contains(k)) _pending.add(k);
        }
        if (got.isNotEmpty) _changed();
        if (pend.isNotEmpty) {
          _nextRetryAt = _clock() + retryMs; // the gateway's upstream budget: ask again later
          break;
        }
      }
    } finally {
      _busy = false;
      if (_again) {
        _again = false;
        unawaited(_pump());
      }
    }
  }

  void _onError(Object e) {
    final now = _clock();
    final code = e is ApiException ? e.statusCode : 0;
    offline = e is ApiException ? e.isOffline : true;
    lastError = offline ? 'Offline: showing saved places' : 'Places unavailable right now';
    _blockedUntil = now +
        (code == 429
            ? 2 * 60000
            : code == 503
                ? 15 * 60000
                : 5 * 60000);
    _nextRetryAt = _blockedUntil;
    notifyListeners();
  }

  void _put(String k, PoiCellData d) {
    _cells.remove(k);
    _cells[k] = d;
    while (_cells.length > maxMemoryCells) {
      final old = _cells.keys.first;
      _cells.remove(old);
      _diskChecked.remove(old);
    }
  }

  void _changed() {
    _version++;
    _all = null;
    _visibleCache = null;
    _projected = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------- fuel
  List<ProjectedPoi> _projectedFuel() {
    final path = _path;
    if (path == null) return const [];
    return _projected ??= projectOntoRoute(
        all.where((x) => x.category == PoiCategory.fuel || x.category == PoiCategory.ev), path);
  }

  /// Stations ahead on the route for this bike, nearest first.
  List<FuelStop> fuelStops({double? usableKm, double marginKm = 0, int limit = 12}) {
    if (_cursor == null || _cursor!.offM > 3000) return const [];
    return fuelStopsAhead(_projectedFuel(), progressM: progressM, type: _fuelType, usableKm: usableKm, marginKm: marginKm, limit: limit);
  }

  /// For the fuel warning: moves the rider to ([la], [ln]) and returns the
  /// stations ahead, how far ahead places are loaded and any group fuel stop.
  /// Null without a route (or far off it): the warning then uses range only.
  FuelAheadView? fuelAhead(double la, double ln, {double? usableKm, double marginKm = 0}) {
    onPosition(la, ln);
    final c = _corridor, cur = _cursor, path = _path;
    if (c == null || cur == null || path == null || cur.offM > 3000) return null;
    final stops = fuelStops(usableKm: usableKm, marginKm: marginKm);
    final covered = c.coveredAheadM(cur.progressM, hasCell) / 1000;
    var groups = _groupProjected;
    if (groups == null) {
      groups = <({double alongM, String name})>[];
      for (final g in _groupStops) {
        final h = path.project(g.lat, g.lng);
        if (h != null && h.off <= 1500) groups.add((alongM: h.along, name: g.name));
      }
      _groupProjected = groups;
    }
    ({double alongM, String name})? group;
    for (final g in groups) {
      if (g.alongM >= cur.progressM - 100 && (group == null || g.alongM < group.alongM)) group = g;
    }
    return FuelAheadView(
      type: _fuelType,
      stops: stops,
      coverageKm: covered,
      groupStopKm: group == null ? null : ((group.alongM - cur.progressM).clamp(0, double.infinity)) / 1000,
      groupStopName: group?.name,
    );
  }

  /// Along-route and straight-line distance to a place, for its card.
  ({double? aheadKm, double straightKm}) distanceTo(PlacePoi x) {
    final la = lat, ln = lng;
    final straight = la == null || ln == null ? double.nan : GeoMath.haversine(la, ln, x.lat, x.lng) / 1000;
    final path = _path, cur = _cursor;
    if (path == null || cur == null || cur.offM > 3000) return (aheadKm: null, straightKm: straight);
    final h = path.project(x.lat, x.lng);
    if (h == null || h.off > 1500 || h.along < cur.progressM - 100) return (aheadKm: null, straightKm: straight);
    return (aheadKm: ((h.along - cur.progressM).clamp(0, double.infinity) + h.off) / 1000, straightKm: straight);
  }

  @visibleForTesting
  void debugPut(String key, PoiCellData d) {
    _put(key, d);
    _changed();
  }
}
