import 'dart:math' as math;

import '../tracking/geo_math.dart';

/// 3.55 "No-signal ahead" (switch `noSignalAhead`): a log of where THIS phone had no signal on the
/// rider's own past rides, and the decision "a no-signal stretch starts 2 to 5 km ahead".
///
/// Pure. Cells are about 500 m square ([cellKey]): a latitude band of 1/222 degree and a longitude
/// step widened by 1/cos(latitude) so cells stay square. A cell counts one PASS per ride: a pass
/// is offline when any sample in it during that ride was offline (a pass first seen online that
/// then drops is moved to offline). At most [maxCells] cells (least recently passed are dropped).
/// Nothing leaves the phone: the log is the rider's own history.
class CoverageCell {
  int offline;
  int online;

  /// Minutes since epoch of the last sample (for least-recently-used eviction).
  int lastMin;

  /// Hash of the ride the last pass belongs to, and whether that pass is offline.
  int ride;
  bool passOffline;

  CoverageCell({this.offline = 0, this.online = 0, this.lastMin = 0, this.ride = 0, this.passOffline = false});

  /// Seen without signal in at least [minPasses] passes, and more often offline than online.
  bool dead(int minPasses) => offline >= minPasses && offline > online;

  List<int> toJson() => [offline, online, lastMin, ride, passOffline ? 1 : 0];

  static CoverageCell? fromJson(Object? j) {
    if (j is! List || j.length < 5) return null;
    int n(int i) => j[i] is num ? (j[i] as num).toInt() : 0;
    return CoverageCell(offline: n(0), online: n(1), lastMin: n(2), ride: n(3), passOffline: n(4) == 1);
  }
}

/// A stretch ahead on the route that had no signal on earlier rides.
class DeadStretch {
  /// Metres along the route from the rider to the first and past the last dead cell.
  final double startAheadM;
  final double endAheadM;

  /// The first dead cell (one notice per stretch).
  final String startCell;

  /// Where the stretch starts.
  final double lat;
  final double lng;

  const DeadStretch({required this.startAheadM, required this.endAheadM, required this.startCell, required this.lat, required this.lng});

  double get lengthM => endAheadM - startAheadM;
}

class CoverageLog {
  CoverageLog({this.maxCells = 5000});

  final int maxCells;

  /// Cell size in degrees of latitude (~500 m).
  static const double cellDeg = 1 / 222;

  final Map<String, CoverageCell> _cells = <String, CoverageCell>{};
  bool _dirty = false;

  int get length => _cells.length;
  bool get dirty => _dirty;
  void markSaved() => _dirty = false;
  CoverageCell? cell(String key) => _cells[key];

  static String cellKey(double lat, double lng) {
    final row = (lat / cellDeg).floor();
    final band = ((row + 0.5) * cellDeg) * math.pi / 180;
    final cos = math.max(0.05, math.cos(band));
    final col = (lng * cos / cellDeg).floor();
    return '$row:$col';
  }

  static int rideHash(String rideId) {
    var h = 0x811c9dc5;
    for (final c in rideId.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h == 0 ? 1 : h;
  }

  /// One sample during a ride: [online] = the phone had a live connection at this fix.
  void record({required double lat, required double lng, required bool online, required String rideId, required int nowMs}) {
    if (lat == 0 && lng == 0) return;
    if (!lat.isFinite || !lng.isFinite) return;
    final key = cellKey(lat, lng);
    final ride = rideHash(rideId);
    final min = nowMs ~/ 60000;
    var c = _cells.remove(key); // re-inserted last: the map's order is least recently used first
    if (c == null) {
      c = CoverageCell(lastMin: min);
      if (_cells.length >= maxCells) _evict();
    }
    if (c.ride != ride) {
      c.ride = ride;
      c.passOffline = !online;
      if (online) {
        c.online++;
      } else {
        c.offline++;
      }
    } else if (!online && !c.passOffline) {
      // This pass was counted online and the signal dropped inside the cell: it is an offline pass.
      c.passOffline = true;
      if (c.online > 0) c.online--;
      c.offline++;
    }
    c.lastMin = min;
    _cells[key] = c;
    _dirty = true;
  }

  void _evict() {
    while (_cells.length >= maxCells && _cells.isNotEmpty) {
      _cells.remove(_cells.keys.first);
    }
  }

  /// The first no-signal stretch whose start is [minAheadM]..[maxAheadM] ahead along [line] from
  /// the rider at [myAlongM] (metres along the line), or null. The stretch runs while the cells are
  /// dead or not logged at all, at most [maxStretchM]; it ends at the first cell with signal.
  DeadStretch? deadAhead({
    required List<(double, double)> line,
    required double myAlongM,
    double minAheadM = 2000,
    double maxAheadM = 5000,
    int minPasses = 2,
    double stepM = 200,
    double maxStretchM = 60000,
  }) {
    if (line.length < 2) return null;
    // From the rider on: a stretch that already starts closer than [minAheadM] is too late to announce.
    final pts = _sample(line, myAlongM, myAlongM + maxAheadM + maxStretchM, stepM);
    DeadStretch? found;
    double? start;
    String? startCell;
    (double, double)? startPos;
    double last = 0;
    for (final (along, lat, lng) in pts) {
      final ahead = along - myAlongM;
      final c = _cells[cellKey(lat, lng)];
      final dead = c != null && c.dead(minPasses);
      if (start == null) {
        if (ahead > maxAheadM) break;
        if (dead && ahead < minAheadM) return null;
        if (dead) {
          start = ahead;
          startCell = cellKey(lat, lng);
          startPos = (lat, lng);
          last = ahead;
        }
        continue;
      }
      final hasSignal = c != null && !c.dead(minPasses) && c.online > 0;
      if (hasSignal || ahead - start > maxStretchM) break;
      if (dead) last = ahead;
    }
    if (start != null && startCell != null && startPos != null) {
      found = DeadStretch(startAheadM: start, endAheadM: last + stepM, startCell: startCell, lat: startPos.$1, lng: startPos.$2);
    }
    return found;
  }

  /// Points every [stepM] along [line] between [fromM] and [toM] metres: (along, lat, lng).
  static List<(double, double, double)> _sample(List<(double, double)> line, double fromM, double toM, double stepM) {
    final out = <(double, double, double)>[];
    var acc = 0.0;
    var next = fromM < 0 ? 0.0 : fromM;
    for (var i = 1; i < line.length; i++) {
      final a = line[i - 1], b = line[i];
      final seg = GeoMath.haversine(a.$1, a.$2, b.$1, b.$2);
      if (seg <= 0) continue;
      while (next <= acc + seg && next <= toM) {
        final f = (next - acc) / seg;
        out.add((next, a.$1 + (b.$1 - a.$1) * f, a.$2 + (b.$2 - a.$2) * f));
        next += stepM;
      }
      acc += seg;
      if (next > toM) break;
    }
    return out;
  }

  Map<String, Object> toJson() => {
        'v': 1,
        'c': {for (final e in _cells.entries) e.key: e.value.toJson()},
      };

  /// Restores a saved log (oldest first, so eviction order survives); bad entries are skipped.
  static CoverageLog fromJson(Object? j, {int maxCells = 5000}) {
    final log = CoverageLog(maxCells: maxCells);
    if (j is! Map || j['c'] is! Map) return log;
    final entries = <MapEntry<String, CoverageCell>>[];
    (j['c'] as Map).forEach((k, v) {
      final c = CoverageCell.fromJson(v);
      if (c != null && k is String) entries.add(MapEntry(k, c));
    });
    entries.sort((a, b) => a.value.lastMin.compareTo(b.value.lastMin));
    for (final e in entries.length > maxCells ? entries.sublist(entries.length - maxCells) : entries) {
      log._cells[e.key] = e.value;
    }
    return log;
  }
}
