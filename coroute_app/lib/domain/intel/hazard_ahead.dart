import 'dart:math' as math;

import '../tracking/geo_math.dart';

/// A cell from the gateway's k-anonymous layers (hazards, road quality, twisty, stops).
class IntelCell {
  const IntelCell({required this.id, required this.lat, required this.lng, this.kind = '', this.level = '', this.dirs = const [], this.score = 0, this.ghat = false, this.fuel = false, this.name = ''});

  final String id;
  final double lat, lng;

  /// hazards: hard_brake | swerve | skid | crash | sos; road quality: pothole | rough.
  final String kind;

  /// hazards: 'high' | 'medium'.
  final String level;

  /// Heading buckets (0 = north, 45 degrees each) riders had there; empty = both / unknown directions.
  final List<int> dirs;
  final int score;
  final bool ghat;
  final bool fuel;
  final String name;

  static IntelCell? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], lat = j['lat'], lng = j['lng'];
    if (id is! String || lat is! num || lng is! num) return null;
    final place = j['place'];
    return IntelCell(
      id: id,
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      kind: j['kind'] is String ? j['kind'] as String : '',
      level: j['level'] is String ? j['level'] as String : '',
      dirs: [for (final d in (j['dirs'] is List ? j['dirs'] as List : const [])) if (d is num && d >= 0 && d < 8) d.toInt()],
      score: (j['score'] as num?)?.toInt() ?? 0,
      ghat: j['ghat'] == true,
      fuel: j['fuel'] == true,
      name: place is Map && place['name'] is String ? place['name'] as String : (j['name'] is String ? j['name'] as String : ''),
    );
  }

  Map<String, Object> toJson() => {'id': id, 'lat': lat, 'lng': lng, 'kind': kind, 'level': level, 'dirs': dirs, 'score': score, 'ghat': ghat, 'fuel': fuel, 'name': name};
}

/// What to say and show for a cell ahead.
class AheadWarning {
  const AheadWarning({required this.cell, required this.distanceM, required this.title, required this.speech});
  final IntelCell cell;
  final double distanceM;
  final String title;
  final String speech;
}

/// "Hazard ahead" / "Rough road ahead" (pure, fed with my fixes; works from the offline cache):
///  * a cell [minAheadM]-[maxAheadM] (300-500 m) ahead: in front of me (bearing within [frontDeg] of my
///    heading) and, when the cell has directions, riders were going my way (±45 degrees);
///  * at most one warning per [spacingM] of riding (2 km hazards, 5 km rough road), never the same cell twice
///    per ride;
///  * never while an SOS / crash alarm is open (the caller passes [emergency]); nothing when [muted].
class AheadMonitor {
  AheadMonitor({this.minAheadM = 300, this.maxAheadM = 500, this.spacingM = 2000, this.frontDeg = 35, this.minKmh = 15});

  final double minAheadM;
  final double maxAheadM;
  final double spacingM;
  final double frontDeg;
  final double minKmh;

  bool muted = false;
  List<IntelCell> _cells = const [];
  final Set<String> _warned = {};
  double _odoM = 0;
  double? _lastWarnOdoM;
  (double, double)? _last;

  void setCells(List<IntelCell> cells) => _cells = cells;
  int get cellCount => _cells.length;

  void reset() {
    _warned.clear();
    _odoM = 0;
    _lastWarnOdoM = null;
    _last = null;
  }

  /// One fix with my heading (degrees, null when unknown) and speed. Returns a warning to give, or null.
  AheadWarning? onFix({required double lat, required double lng, required double? headingDeg, required double speedKmh, required bool emergency,
      required AheadWarning Function(IntelCell c, double d) describe}) {
    final last = _last;
    if (last != null) {
      final step = GeoMath.haversine(last.$1, last.$2, lat, lng);
      if (step < 2000) _odoM += step; // a jump is a bad fix, not riding
    }
    _last = (lat, lng);
    if (muted || emergency || headingDeg == null || !headingDeg.isFinite || speedKmh < minKmh || _cells.isEmpty) return null;
    final lw = _lastWarnOdoM;
    if (lw != null && _odoM - lw < spacingM) return null;
    IntelCell? best;
    var bestD = double.infinity;
    // Cheap prefilter by degrees (≈ 600 m) before the exact distance.
    final dLat = maxAheadM / 111000 * 1.2;
    final dLng = dLat / math.max(0.2, math.cos(lat * math.pi / 180));
    for (final c in _cells) {
      if ((c.lat - lat).abs() > dLat || (c.lng - lng).abs() > dLng || _warned.contains(c.id)) continue;
      final d = GeoMath.haversine(lat, lng, c.lat, c.lng);
      if (d < minAheadM || d > maxAheadM) continue;
      final toCell = GeoMath.bearing(lat, lng, c.lat, c.lng);
      if (GeoMath.bearingDiff(headingDeg, toCell) > frontDeg) continue;
      if (c.dirs.isNotEmpty && !c.dirs.any((b) => GeoMath.bearingDiff(headingDeg, b * 45.0) <= 45)) continue;
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    if (best == null) return null;
    _warned.add(best.id);
    _lastWarnOdoM = _odoM;
    return describe(best, bestD);
  }

  static AheadWarning hazard(IntelCell c, double d) {
    final m = (d / 50).round() * 50;
    final what = switch (c.kind) {
      'crash' || 'sos' => 'Accident-prone spot',
      'skid' => 'Slippery spot',
      'swerve' => 'Riders swerve here',
      _ => 'Riders brake hard here',
    };
    return AheadWarning(cell: c, distanceM: d, title: 'Hazard ahead · $m m', speech: 'Hazard ahead in $m meters. $what. Ride carefully.');
  }

  static AheadWarning rough(IntelCell c, double d) {
    final m = (d / 50).round() * 50;
    final pothole = c.kind == 'pothole';
    return AheadWarning(cell: c, distanceM: d, title: '${pothole ? 'Pothole' : 'Rough road'} ahead · $m m', speech: '${pothole ? 'Pothole' : 'Rough road'} ahead.');
  }
}

/// One twisty section along the planned route (along-route metres).
class TwistySection {
  const TwistySection(this.startM, this.endM, {this.ghat = false});
  final double startM, endM;
  final bool ghat;
  double get lengthKm => (endM - startM) / 1000;
}

/// "Twisty section next 8 km. Slow down." (pure). Sections come from twisty cells projected onto the route
/// once per route ([sectionsOf]); the heads-up is given once per section, [leadM] (1 km) before it starts.
class TwistyAhead {
  TwistyAhead({this.leadM = 1000});
  final double leadM;
  List<TwistySection> _sections = const [];
  final Set<int> _said = {};

  void setSections(List<TwistySection> s) {
    _sections = s;
    _said.clear();
  }

  List<TwistySection> get sections => _sections;

  /// Twisty cells (score ≥ 50 = ghat, ≥ 30 twisty) at along-route positions → merged sections of ≥ [minKm],
  /// cells closer than [joinM] joined. Each cell covers about ±[halfCellM] of road.
  static List<TwistySection> sectionsOf(List<({double alongM, bool ghat})> cells, {double minKm = 2, double joinM = 1500, double halfCellM = 500}) {
    final sorted = [...cells]..sort((a, b) => a.alongM.compareTo(b.alongM));
    final out = <TwistySection>[];
    double? s, e;
    var ghat = false;
    for (final c in sorted) {
      final a = c.alongM - halfCellM, b = c.alongM + halfCellM;
      if (s == null || a - e! > joinM) {
        if (s != null && (e! - s) / 1000 >= minKm) out.add(TwistySection(s, e, ghat: ghat));
        s = a;
        e = b;
        ghat = c.ghat;
      } else {
        e = math.max(e, b);
        ghat = ghat || c.ghat;
      }
    }
    if (s != null && (e! - s) / 1000 >= minKm) out.add(TwistySection(math.max(0, s), e, ghat: ghat));
    return out;
  }

  /// My along-route position; returns the section to announce now, or null.
  TwistySection? onAlong(double alongM, {required bool emergency}) {
    if (emergency) return null;
    for (var i = 0; i < _sections.length; i++) {
      final s = _sections[i];
      if (_said.contains(i)) continue;
      if (alongM >= s.startM - leadM && alongM < s.startM + 200) {
        _said.add(i);
        return s;
      }
    }
    return null;
  }

  static String title(TwistySection s) => '${s.ghat ? 'Ghat' : 'Twisty'} section next ${s.lengthKm.round()} km';
  static String speech(TwistySection s) => '${s.ghat ? 'Ghat' : 'Twisty'} section for the next ${s.lengthKm.round()} kilometers. Slow down.';
}

/// Offline cache of intel cells by read tile (geohash-4), kept [maxAge] (14 days).
class IntelTileCache {
  IntelTileCache({this.maxAge = const Duration(days: 14), this.maxTiles = 256});
  final Duration maxAge;
  final int maxTiles;
  final Map<String, ({int at, List<IntelCell> cells})> _tiles = {};

  int get tileCount => _tiles.length;

  void put(String tile, List<IntelCell> cells, int nowMs) {
    _tiles.remove(tile);
    _tiles[tile] = (at: nowMs, cells: cells);
    while (_tiles.length > maxTiles) {
      _tiles.remove(_tiles.keys.first);
    }
  }

  bool fresh(String tile, int nowMs, {Duration within = const Duration(hours: 12)}) {
    final t = _tiles[tile];
    return t != null && nowMs - t.at < within.inMilliseconds;
  }

  /// Every cell of the tiles still within [maxAge].
  List<IntelCell> cells(int nowMs) => [
        for (final t in _tiles.values)
          if (nowMs - t.at < maxAge.inMilliseconds) ...t.cells,
      ];

  Map<String, Object> toJson() => {
        for (final e in _tiles.entries) e.key: {'at': e.value.at, 'c': [for (final c in e.value.cells) c.toJson()]},
      };

  static IntelTileCache fromJson(Object? j, {Duration maxAge = const Duration(days: 14)}) {
    final out = IntelTileCache(maxAge: maxAge);
    if (j is! Map) return out;
    for (final e in j.entries) {
      final v = e.value;
      if (e.key is! String || v is! Map || v['at'] is! num || v['c'] is! List) continue;
      out._tiles[e.key as String] = (at: (v['at'] as num).toInt(), cells: [for (final c in v['c'] as List) ?IntelCell.fromJson(c)]);
    }
    return out;
  }
}
