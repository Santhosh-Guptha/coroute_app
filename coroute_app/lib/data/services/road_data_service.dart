import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

import '../../domain/road/road_cell.dart';
import '../../domain/road/road_matcher.dart';
import 'api_client.dart';
import 'safety_native.dart';
import 'sos_battery_reserve.dart';

/// Road cells on the phone (round 7; docs/features_355/curve_and_speed_limit.md).
///
/// Fetches geohash-6 road cells from the gateway (GET /api/geo/roads?cell=), keeps them on disk
/// in a least-recently-used store bounded in bytes ([maxBytes], 30 MB) and loads the ones around
/// the rider into the [matcher] that curve and speed-limit prediction read. Riding needs no
/// network: a cell that is on the phone is used from disk; a cell that is not is simply missing
/// and the predictions stay silent there.
///
/// Polite by design: one request at a time, a pause between requests, a cell the gateway
/// answers "pending" (202) is asked again only after its Retry-After, a network error pauses
/// all fetching for a minute, nothing is fetched in the SOS battery reserve.
/// Map data (C) OpenStreetMap contributors, ODbL.
class RoadDataService extends ChangeNotifier {
  RoadDataService({required this.api, RoadMatcher? matcher, int Function()? now, this.maxBytes = 30 * 1024 * 1024, this.persist = true})
      : matcher = matcher ?? RoadMatcher(),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _lru.maxBytes = maxBytes;
    shared = this;
  }

  /// The service of the running ride engine (for Settings: storage size and "Clear").
  static RoadDataService? shared;

  final ApiClient? Function() api;
  final RoadMatcher matcher;
  final int Function() _now;
  final int maxBytes;
  final bool persist;

  static const Duration fresh = Duration(days: 30);
  static const Duration refreshAfter = Duration(days: 7);
  static const Duration pauseBetween = Duration(milliseconds: 350);
  static const int maxQueue = 160;

  final RoadCellLru _lru = RoadCellLru();
  final List<String> _queue = <String>[];
  final Map<String, int> _notBefore = <String, int>{};
  final Set<String> _empty = <String>{}; // read this session, nothing usable
  Future<Directory?>? _dir;
  bool _indexLoaded = false;
  bool _fetching = false;
  int _pausedUntil = 0;
  int _lastPlanMs = 0;
  double _planLat = 0, _planLng = 0;
  Timer? _indexSave;
  int fetched = 0, failed = 0;

  int get storedBytes => _lru.usedBytes;
  int get storedCells => _lru.count;
  int get waiting => _queue.length;

  Future<Directory?> _open() => _dir ??= () async {
        String? base;
        try {
          base = await getDatabasesPath();
        } catch (_) {
          base = await SafetyNative.cacheDir();
        }
        if (base == null) return null;
        final d = Directory(p.join(base, 'road_cells'));
        await d.create(recursive: true);
        return d;
      }()
          .catchError((Object _) => null);

  Future<void> _loadIndex() async {
    if (_indexLoaded || !persist) {
      _indexLoaded = true;
      return;
    }
    _indexLoaded = true;
    try {
      final d = await _open();
      if (d == null) return;
      final f = File(p.join(d.path, 'index.json'));
      if (await f.exists()) _lru.load(jsonDecode(await f.readAsString()));
      notifyListeners();
    } catch (_) {}
  }

  void _saveIndexSoon() {
    if (!persist) return;
    _indexSave ??= Timer(const Duration(seconds: 5), () async {
      _indexSave = null;
      try {
        final d = await _open();
        if (d == null) return;
        await File(p.join(d.path, 'index.json')).writeAsString(jsonEncode(_lru.toJson()), flush: false);
      } catch (_) {}
    });
  }

  /// With each fix: the cells around me and ahead on my heading, at most every 150 m / 20 s.
  void onFix(double lat, double lng, {double? headingDeg}) {
    final now = _now();
    final moved = (lat - _planLat).abs() * 110540 + (lng - _planLng).abs() * 100000;
    if (_lastPlanMs != 0 && moved < 150 && now - _lastPlanMs < 20000) return;
    _lastPlanMs = now;
    _planLat = lat;
    _planLng = lng;
    ensure(RoadCellPlanner.around(lat, lng, headingDeg: headingDeg), front: true).ignore();
  }

  /// The cells of a planned route (at ride start, on a re-route, when offline maps are saved).
  Future<void> prefetchRoute(List<(double, double)> line, {double fromM = 0}) => ensure(RoadCellPlanner.alongRoute(line, fromM: fromM));

  /// Loads [cells] from disk into the matcher and queues the missing / old ones for fetching.
  Future<void> ensure(List<String> cells, {bool front = false}) async {
    await _loadIndex();
    final now = _now();
    var at = 0;
    for (final c in cells) {
      final have = _lru.fetchedAt(c);
      var need = have == null;
      if (have != null) {
        _lru.touch(c);
        if (front && !matcher.hasCell(c) && !_empty.contains(c)) await _loadFromDisk(c);
        if (now - have > refreshAfter.inMilliseconds) need = true; // corrections and map edits arrive this way
        if (now - have > fresh.inMilliseconds && !front) need = true;
      }
      if (!need || _queue.contains(c)) continue;
      if (front) {
        _queue.insert(at++, c);
      } else {
        _queue.add(c);
      }
    }
    while (_queue.length > maxQueue) {
      _queue.removeLast();
    }
    _pump();
  }

  Future<bool> _loadFromDisk(String cell) async {
    if (!persist) return false;
    try {
      final d = await _open();
      if (d == null) return false;
      final f = File(p.join(d.path, '$cell.json'));
      if (!await f.exists()) {
        _lru.remove(cell);
        return false;
      }
      final c = RoadCell.fromJson(jsonDecode(await f.readAsString()));
      if (c == null) {
        _empty.add(cell);
        return false;
      }
      matcher.addCell(c);
      return true;
    } catch (_) {
      _empty.add(cell);
      return false;
    }
  }

  void _pump() {
    if (_fetching || _queue.isEmpty) return;
    final a = api();
    if (a == null || !a.hasToken || SosBatteryReserve.isActive) return;
    final now = _now();
    if (now < _pausedUntil) return;
    final i = _queue.indexWhere((c) => (_notBefore[c] ?? 0) <= now);
    if (i < 0) return;
    final cell = _queue.removeAt(i);
    _fetching = true;
    _fetch(a, cell).whenComplete(() {
      _fetching = false;
      Timer(pauseBetween, _pump);
    });
  }

  Future<void> _fetch(ApiClient a, String cell) async {
    try {
      final r = await a.get('/geo/roads?cell=$cell', timeout: const Duration(seconds: 20));
      if (r is Map && r['pending'] == true) {
        final s = r['retryAfterS'];
        _notBefore[cell] = _now() + ((s is num ? s.toInt() : 60).clamp(20, 3600)) * 1000;
        if (_notBefore.length > 400) _notBefore.remove(_notBefore.keys.first);
        return;
      }
      final c = RoadCell.fromJson(r);
      if (c == null || c.id != cell) return;
      fetched++;
      matcher.addCell(c);
      await _store(cell, jsonEncode(r));
      notifyListeners();
    } on ApiException catch (e) {
      failed++;
      // 503 = the gateway has no road source; 429 = slow down. Either way: wait.
      _pausedUntil = _now() + (e.statusCode == 503 ? 30 : (e.statusCode == 0 ? 1 : 5)) * 60000;
    } catch (_) {
      failed++;
      _pausedUntil = _now() + 60000;
    }
  }

  Future<void> _store(String cell, String text) async {
    if (!persist) return;
    try {
      final d = await _open();
      if (d == null) return;
      await File(p.join(d.path, '$cell.json')).writeAsString(text, flush: false);
      for (final gone in _lru.put(cell, text.length, _now())) {
        try {
          await File(p.join(d.path, '$gone.json')).delete();
        } catch (_) {}
      }
      _saveIndexSoon();
    } catch (_) {}
  }

  // ------------------------------------------------------------------ "wrong limit" reports
  /// The limits shown on this ride, newest last (at most 40 roads). Kept in memory for the
  /// "Limits on your last ride" list; cleared when the next ride starts.
  final List<ShownLimit> shownLimits = <ShownLimit>[];

  void startRide() {
    shownLimits.clear();
  }

  /// The cockpit showed [kmh] for road [way] (once per road and value).
  void noteShown({required int way, required String cell, required int kmh, required bool estimated, required String source, String name = ''}) {
    if (way <= 0) return;
    if (shownLimits.isNotEmpty && shownLimits.last.way == way && shownLimits.last.kmh == kmh) return;
    shownLimits.removeWhere((x) => x.way == way);
    shownLimits.add(ShownLimit(way: way, cell: cell, kmh: kmh, estimated: estimated, source: source, name: name));
    if (shownLimits.length > 40) shownLimits.removeAt(0);
  }

  /// One "wrong limit" vote (POST /api/geo/limit-corrections). Only for a rider who is not
  /// moving: the caller checks that. Returns a short line for the rider.
  Future<String> reportWrongLimit(ShownLimit shown, int rightKmh) async {
    final a = api();
    if (a == null || !a.hasToken) return 'Sign in to report a limit.';
    try {
      final r = await a.post('/geo/limit-corrections', {'way': shown.way, 'cell': shown.cell, 'kmh': rightKmh, 'shownKmh': shown.kmh, 'shownSource': shown.source});
      if (r is Map && r['accepted'] == false) {
        return r['reason'] == 'NO_CONSENT' ? 'Turn on "Help make roads safer" to send limit reports.' : 'The report could not be saved.';
      }
      shown.reported = rightKmh;
      notifyListeners();
      final applied = r is Map ? r['applied'] : null;
      return applied is num ? 'Thank you. This road now shows ${applied.toInt()}.' : 'Thank you. The limit changes when 3 riders agree.';
    } on ApiException catch (e) {
      return e.statusCode == 404 ? 'This road is not in the road data any more.' : (e.statusCode == 429 ? 'That is enough reports for today. Thank you.' : 'Could not send the report. Try again later.');
    } catch (_) {
      return 'Could not send the report. Try again later.';
    }
  }

  /// Settings > Road safety > Road data > Clear.
  Future<void> clear() async {
    _queue.clear();
    _notBefore.clear();
    _empty.clear();
    matcher.clear();
    _lru.clear();
    try {
      final d = await _open();
      if (d != null && await d.exists()) {
        await for (final f in d.list()) {
          if (f is File) await f.delete();
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  @override
  void dispose() {
    _indexSave?.cancel();
    if (identical(shared, this)) shared = null;
    super.dispose();
  }
}

/// A limit the cockpit showed for a road during the ride.
class ShownLimit {
  ShownLimit({required this.way, required this.cell, required this.kmh, required this.estimated, required this.source, this.name = ''});
  final int way;
  final String cell;
  final int kmh;
  final bool estimated;
  final String source;
  final String name;

  /// The value this rider reported for it (null: not reported).
  int? reported;

  String get label => estimated ? '~$kmh est.' : '$kmh';
}
