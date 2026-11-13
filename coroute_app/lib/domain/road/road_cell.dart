import 'dart:math' as math;

import '../intel/geohash.dart';

/// Road classes in wire order (`h`). Must match CLASSES in gateway/src/road_cells.js.
const List<String> roadClasses = [
  'motorway', 'trunk', 'primary', 'secondary', 'tertiary', 'unclassified', 'residential', 'living_street',
  'service', 'road', 'motorway_link', 'trunk_link', 'primary_link', 'secondary_link', 'tertiary_link',
];

/// One road (an OpenStreetMap way, or the part of it inside a cell).
class RoadWay {
  RoadWay({
    required this.id,
    required this.cls,
    required this.lat5,
    required this.lng5,
    this.name = '',
    this.maxspeed,
    this.maxspeedMotorcycle,
    this.maxspeedType,
    this.oneway = 0,
    this.lit = false,
    this.lanes = 0,
  });

  final int id;

  /// Index into [roadClasses].
  final int cls;

  /// Points in 1e-5 degrees (shared OpenStreetMap nodes have identical values).
  final List<int> lat5, lng5;
  final String name;

  /// Raw tag values (null when not tagged).
  final String? maxspeed, maxspeedMotorcycle, maxspeedType;

  /// 1 = one-way along the points, -1 = against them, 0 = both ways.
  final int oneway;
  final bool lit;
  final int lanes;

  String get highway => cls >= 0 && cls < roadClasses.length ? roadClasses[cls] : 'road';
  bool get isLink => highway.endsWith('_link');
  int get length => lat5.length;
  double latAt(int i) => lat5[i] / 1e5;
  double lngAt(int i) => lng5[i] / 1e5;

  static RoadWay? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['i'], h = j['h'], g = j['g'];
    if (id is! num || h is! num || g is! List || g.length < 4 || g.length.isOdd) return null;
    final la = <int>[], lo = <int>[];
    var a = 0, o = 0;
    for (var k = 0; k < g.length; k += 2) {
      final da = g[k], dob = g[k + 1];
      if (da is! num || dob is! num) return null;
      a += da.toInt();
      o += dob.toInt();
      if (a.abs() > 9000000 || o.abs() > 18000000) return null;
      la.add(a);
      lo.add(o);
    }
    String? str(String k) => j[k] is String && (j[k] as String).isNotEmpty ? j[k] as String : null;
    final ow = j['ow'];
    final ln = j['ln'];
    return RoadWay(
      id: id.toInt(),
      cls: h.toInt().clamp(0, roadClasses.length - 1),
      lat5: la,
      lng5: lo,
      name: str('n') ?? '',
      maxspeed: str('ms'),
      maxspeedMotorcycle: str('mm'),
      maxspeedType: str('mt'),
      oneway: ow == 1 ? 1 : (ow == -1 ? -1 : 0),
      lit: j['lit'] == 1,
      lanes: ln is num ? ln.toInt() : 0,
    );
  }
}

/// A school ('s') or hospital ('h') near a road.
class RoadZone {
  const RoadZone(this.lat, this.lng, this.school);
  final double lat, lng;
  final bool school;
}

/// One geohash-6 cell of road data (GET /api/geo/roads?cell=). Map data: OpenStreetMap, ODbL.
class RoadCell {
  RoadCell({required this.id, required this.ways, this.zones = const [], this.buildings = 0, this.landuse = 0, this.corrections = const {}, this.truncated = false});

  final String id;
  final List<RoadWay> ways;
  final List<RoadZone> zones;

  /// Counts of buildings and built-up land-use areas in the cell (the urban hint).
  final int buildings, landuse;

  /// Way id -> limit agreed by riders ("wrong limit" votes, k riders).
  final Map<int, int> corrections;
  final bool truncated;

  static const int precision = 6;

  static RoadCell? fromJson(Object? j) {
    if (j is! Map || j['v'] != 1 || j['c'] is! String || j['w'] is! List) return null;
    final ways = <RoadWay>[];
    for (final w in j['w'] as List) {
      final r = RoadWay.fromJson(w);
      if (r != null) ways.add(r);
      if (ways.length >= 2000) break;
    }
    final zones = <RoadZone>[];
    final z = j['z'];
    if (z is List) {
      for (final e in z) {
        if (e is List && e.length >= 3 && e[0] is num && e[1] is num) {
          zones.add(RoadZone((e[0] as num) / 1e5, (e[1] as num) / 1e5, e[2] != 'h'));
        }
      }
    }
    final fx = <int, int>{};
    final f = j['fx'];
    if (f is Map) {
      f.forEach((k, v) {
        final id = int.tryParse('$k');
        if (id != null && v is num && v >= 5 && v <= 120) fx[id] = v.toInt();
      });
    }
    final u = j['u'];
    return RoadCell(
      id: j['c'] as String,
      ways: ways,
      zones: zones,
      buildings: u is Map && u['b'] is num ? (u['b'] as num).toInt() : 0,
      landuse: u is Map && u['lu'] is num ? (u['lu'] as num).toInt() : 0,
      corrections: fx,
      truncated: j['tr'] == 1,
    );
  }

  /// Built-up area (the "within municipal limits" proxy; a guess, see the feature doc): many
  /// buildings, or mapped built-up land use with some buildings, or mostly residential streets.
  /// OpenStreetMap buildings are incomplete in much of India, so the street mix counts too.
  late final bool urban = _urban();

  bool _urban() {
    if (buildings >= 150) return true;
    if (landuse >= 1 && buildings >= 30) return true;
    var res = 0, all = 0;
    for (final w in ways) {
      final h = w.highway;
      if (h == 'service') continue;
      all += w.length;
      if (h == 'residential' || h == 'living_street') res += w.length;
    }
    return all >= 60 && res * 2 >= all;
  }
}

/// Which cells to fetch (pure). A geohash-6 cell is about 1.2 km x 0.6 km.
class RoadCellPlanner {
  RoadCellPlanner._();

  static (double, double) _offset(double lat, double lng, double bearingDeg, double distM) {
    final b = bearingDeg * math.pi / 180;
    final dLat = distM * math.cos(b) / 110540.0;
    final dLng = distM * math.sin(b) / (111320.0 * math.max(0.2, math.cos(lat * math.pi / 180)));
    return (lat + dLat, lng + dLng);
  }

  /// My cell first, then the cells ahead on my heading (to [aheadM]) and a little to each side.
  /// Without a heading: my cell and its neighbours at 500 m in eight directions.
  static List<String> around(double lat, double lng, {double? headingDeg, double aheadM = 2400, int max = 9}) {
    final out = <String>[];
    void add(double la, double lo) {
      final c = Geohash.encode(la, lo, RoadCell.precision);
      if (c != null && !out.contains(c) && out.length < max) out.add(c);
    }

    add(lat, lng);
    if (headingDeg == null || !headingDeg.isFinite) {
      for (var b = 0; b < 360; b += 45) {
        final p = _offset(lat, lng, b.toDouble(), 500);
        add(p.$1, p.$2);
      }
      return out;
    }
    for (var d = 400.0; d <= aheadM; d += 400) {
      final p = _offset(lat, lng, headingDeg, d);
      add(p.$1, p.$2);
      if (d <= 800) {
        for (final side in const [-90.0, 90.0]) {
          final q = _offset(p.$1, p.$2, headingDeg + side, 300);
          add(q.$1, q.$2);
        }
      }
    }
    return out;
  }

  /// The cells a route line passes through, in order, from [fromM] for [aheadM] (a point every 250 m).
  static List<String> alongRoute(List<(double, double)> line, {double fromM = 0, double aheadM = 30000, int max = 120}) {
    final out = <String>[];
    if (line.length < 2) return out;
    var acc = 0.0, next = fromM;
    for (var i = 0; i < line.length - 1 && out.length < max; i++) {
      final a = line[i], b = line[i + 1];
      final k = math.cos(a.$1 * math.pi / 180) * 111320.0;
      final dx = (b.$2 - a.$2) * k, dy = (b.$1 - a.$1) * 110540.0;
      final len = math.sqrt(dx * dx + dy * dy);
      while (next <= acc + len && next <= fromM + aheadM && out.length < max) {
        final t = len > 0 ? ((next - acc) / len).clamp(0.0, 1.0) : 0.0;
        final c = Geohash.encode(a.$1 + (b.$1 - a.$1) * t, a.$2 + (b.$2 - a.$2) * t, RoadCell.precision);
        if (c != null && !out.contains(c)) out.add(c);
        next += 250;
      }
      acc += len;
      if (acc > fromM + aheadM) break;
    }
    return out;
  }
}

/// Least-recently-used bookkeeping for the cells kept on the phone, bounded in bytes (pure; the
/// files themselves are RoadDataService's job).
class RoadCellLru {
  RoadCellLru({this.maxBytes = 30 * 1024 * 1024});

  int maxBytes;
  final Map<String, ({int bytes, int at})> _e = <String, ({int bytes, int at})>{}; // insertion order = use order
  int _used = 0;

  int get usedBytes => _used;
  int get count => _e.length;
  bool has(String id) => _e.containsKey(id);
  int? fetchedAt(String id) => _e[id]?.at;
  Iterable<String> get ids => _e.keys;

  void touch(String id) {
    final v = _e.remove(id);
    if (v != null) _e[id] = v;
  }

  /// Records a stored cell; returns the ids to delete to stay within [maxBytes].
  List<String> put(String id, int bytes, int atMs) {
    final old = _e.remove(id);
    if (old != null) _used -= old.bytes;
    _e[id] = (bytes: bytes, at: atMs);
    _used += bytes;
    final evict = <String>[];
    while (_used > maxBytes && _e.length > 1) {
      final k = _e.keys.first;
      if (k == id) break;
      _used -= _e.remove(k)!.bytes;
      evict.add(k);
    }
    return evict;
  }

  void remove(String id) {
    final v = _e.remove(id);
    if (v != null) _used -= v.bytes;
  }

  void clear() {
    _e.clear();
    _used = 0;
  }

  Map<String, Object> toJson() => {for (final e in _e.entries) e.key: [e.value.bytes, e.value.at]};

  void load(Object? j) {
    clear();
    if (j is! Map) return;
    j.forEach((k, v) {
      if (k is String && v is List && v.length == 2 && v[0] is num && v[1] is num) {
        _e[k] = (bytes: (v[0] as num).toInt(), at: (v[1] as num).toInt());
        _used += (v[0] as num).toInt();
      }
    });
  }
}
