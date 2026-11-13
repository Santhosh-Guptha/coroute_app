import 'dart:math' as math;

import 'road_cell.dart';

/// Where the rider is on the road network.
class RoadMatch {
  const RoadMatch({required this.way, required this.segment, required this.t, required this.forward, required this.distanceM, required this.urban});

  final RoadWay way;

  /// Segment index (between points [segment] and [segment] + 1) and the position on it (0..1).
  final int segment;
  final double t;

  /// Riding along the way's points (true) or against them.
  final bool forward;
  final double distanceM;

  /// The cell around the matched road looks built-up.
  final bool urban;
}

/// The road ahead of a match: one line with the road under each stretch.
class RoadAhead {
  const RoadAhead({required this.line, required this.spans, required this.endedAtJunction});

  /// From the rider's matched point onward.
  final List<(double, double)> line;

  /// (start metres along [line], the road from there).
  final List<({double fromM, RoadWay way})> spans;

  /// The line stops at a junction where the continuation is not clear (nothing is predicted beyond).
  final bool endedAtJunction;

  RoadWay? wayAt(double alongM) {
    RoadWay? w;
    for (final s in spans) {
      if (s.fromM <= alongM) w = s.way;
    }
    return w;
  }
}

/// Map matching on the phone's road cells (pure; round 7).
///
/// Match: the segments within [maxDistM] of the fix are scored by distance, by how well the
/// rider's heading agrees with the segment (one-way roads only in their direction) and by
/// continuity (the road matched last time, or one that touches it, is preferred). No heading
/// (standing, first fix): distance and continuity only. Nothing within reach: null (stay silent).
///
/// Ahead: follows the matched road in the riding direction and, at its end, the most likely
/// continuation: the road that shares the end point with the smallest turn, preferring the same
/// name and class. Where the best continuation turns more than [maxContinueTurnDeg] or two
/// candidates are about equally likely, the line ends (a junction: no guessing).
class RoadMatcher {
  RoadMatcher();

  static const double maxDistM = 35;
  static const double maxHeadingDiffDeg = 60;
  static const double headingWeightM = 0.35; // metres of penalty per degree
  static const double continuityBonusM = 12;
  static const double maxContinueTurnDeg = 50;

  final Map<String, RoadCell> _cells = <String, RoadCell>{};
  final Map<int, List<int>> _grid = <int, List<int>>{}; // bucket -> packed (way index << 12 | segment)
  final Map<int, List<int>> _nodes = <int, List<int>>{}; // point key -> packed (way index << 12 | point)
  final List<RoadWay> _ways = <RoadWay>[];
  final List<bool> _urban = <bool>[];
  bool _dirty = false;
  RoadWay? _last;

  int get cellCount => _cells.length;
  int get wayCount => _ways.length;
  bool hasCell(String id) => _cells.containsKey(id);
  Iterable<RoadCell> get cells => _cells.values;

  /// Adds (or replaces) a cell. At most [maxCells] stay loaded (the oldest goes).
  void addCell(RoadCell cell, {int maxCells = 24}) {
    _cells.remove(cell.id);
    _cells[cell.id] = cell;
    while (_cells.length > maxCells) {
      _cells.remove(_cells.keys.first);
    }
    _dirty = true;
  }

  void clear() {
    _cells.clear();
    _dirty = true;
    _last = null;
  }

  static int _bucket(int lat5, int lng5) => ((lat5 ~/ 100) + 100000) * 1000000 + ((lng5 ~/ 100) + 200000);
  static int _node(int lat5, int lng5) => (lat5 + 9000000) * 40000000 + (lng5 + 18000000);

  void _rebuild() {
    _dirty = false;
    _grid.clear();
    _nodes.clear();
    _ways.clear();
    _urban.clear();
    for (final c in _cells.values) {
      for (final w in c.ways) {
        if (w.length < 2 || w.length > 4000 || _ways.length >= 500000) continue;
        final wi = _ways.length;
        _ways.add(w);
        _urban.add(c.urban);
        for (var i = 0; i < w.length; i++) {
          (_nodes[_node(w.lat5[i], w.lng5[i])] ??= <int>[]).add((wi << 12) | i);
          if (i == w.length - 1) break;
          // Every bucket the segment touches (segments are short after clipping; step by half a bucket).
          final a5 = w.lat5[i], o5 = w.lng5[i], b5 = w.lat5[i + 1], p5 = w.lng5[i + 1];
          final steps = math.max(1, (math.max((b5 - a5).abs(), (p5 - o5).abs()) / 50).ceil());
          int? prev;
          for (var s = 0; s <= steps; s++) {
            final k = _bucket(a5 + ((b5 - a5) * s) ~/ steps, o5 + ((p5 - o5) * s) ~/ steps);
            if (k == prev) continue;
            prev = k;
            final list = _grid[k] ??= <int>[];
            final packed = (wi << 12) | i;
            if (list.isEmpty || list.last != packed) list.add(packed);
          }
        }
      }
    }
  }

  static double _bearing(double dx, double dy) => (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
  static double _diff(double a, double b) {
    final d = (a - b).abs() % 360;
    return d > 180 ? 360 - d : d;
  }

  bool _touches(RoadWay a, RoadWay b) {
    if (a.id == b.id) return true;
    for (final i in [0, a.length - 1]) {
      for (final j in [0, b.length - 1]) {
        if (a.lat5[i] == b.lat5[j] && a.lng5[i] == b.lng5[j]) return true;
      }
    }
    return false;
  }

  /// The most likely road for a fix, or null.
  RoadMatch? match(double lat, double lng, {double? headingDeg, double speedKmh = 0}) {
    if (_dirty) _rebuild();
    if (_ways.isEmpty) return null;
    final la5 = (lat * 1e5).round(), lo5 = (lng * 1e5).round();
    final kx = math.cos(lat * math.pi / 180) * 1.1132, ky = 1.1054; // metres per 1e-5 degree
    final useHeading = headingDeg != null && headingDeg.isFinite && speedKmh >= 10;
    RoadMatch? best;
    var bestScore = double.infinity;
    final seen = <int>{};
    for (var da = -1; da <= 1; da++) {
      for (var dob = -1; dob <= 1; dob++) {
        final list = _grid[_bucket(la5 + da * 100, lo5 + dob * 100)];
        if (list == null) continue;
        for (final packed in list) {
          if (!seen.add(packed)) continue;
          final wi = packed >> 12, i = packed & 0xfff;
          final w = _ways[wi];
          final ax = (w.lng5[i] - lo5) * kx, ay = (w.lat5[i] - la5) * ky;
          final bx = (w.lng5[i + 1] - lo5) * kx, by = (w.lat5[i + 1] - la5) * ky;
          final dx = bx - ax, dy = by - ay;
          final len2 = dx * dx + dy * dy;
          var t = len2 > 0 ? (-(ax * dx + ay * dy)) / len2 : 0.0;
          t = t.clamp(0.0, 1.0);
          final cx = ax + t * dx, cy = ay + t * dy;
          final d = math.sqrt(cx * cx + cy * cy);
          if (d > maxDistM) continue;
          var score = d;
          var forward = true;
          if (useHeading && len2 > 1) {
            final segB = _bearing(dx, dy);
            final f = _diff(headingDeg, segB), r = _diff(headingDeg, (segB + 180) % 360);
            double hd;
            if (w.oneway == 1) {
              hd = f;
            } else if (w.oneway == -1) {
              hd = r;
              forward = false;
            } else {
              forward = f <= r;
              hd = math.min(f, r);
            }
            if (hd > maxHeadingDiffDeg) continue;
            score += hd * headingWeightM;
          } else if (w.oneway == -1) {
            forward = false;
          }
          final last = _last;
          if (last != null && _touches(last, w)) score -= last.id == w.id ? continuityBonusM : continuityBonusM / 2;
          // A service road never wins over a real road at about the same distance.
          if (w.highway == 'service') score += 6;
          if (score < bestScore) {
            bestScore = score;
            best = RoadMatch(way: w, segment: i, t: t, forward: forward, distanceM: d, urban: _urban[wi]);
          }
        }
      }
    }
    _last = best?.way ?? _last;
    if (best == null) _last = null;
    return best;
  }

  /// The road line ahead of [m], up to [maxM].
  RoadAhead ahead(RoadMatch m, {double maxM = 700}) {
    if (_dirty) _rebuild();
    final line = <(double, double)>[];
    final spans = <({double fromM, RoadWay way})>[];
    var total = 0.0;
    void push(double lat, double lng) {
      if (line.isNotEmpty) {
        final p = line.last;
        final k = math.cos(lat * math.pi / 180) * 111320.0;
        final dx = (lng - p.$2) * k, dy = (lat - p.$1) * 110540.0;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d < 0.3) return;
        total += d;
      }
      line.add((lat, lng));
    }

    var w = m.way;
    var forward = m.forward;
    // The matched point itself.
    final a = m.segment, b = m.segment + 1;
    push(w.latAt(a) + (w.latAt(b) - w.latAt(a)) * m.t, w.lngAt(a) + (w.lngAt(b) - w.lngAt(a)) * m.t);
    spans.add((fromM: 0, way: w));
    var i = forward ? b : a;
    final visited = <int>{w.id};
    var junction = false;
    for (var guard = 0; guard < 60 && total < maxM; guard++) {
      // To the end of this way.
      while (i >= 0 && i < w.length && total < maxM) {
        push(w.latAt(i), w.lngAt(i));
        i += forward ? 1 : -1;
      }
      if (total >= maxM) break;
      final end = forward ? w.length - 1 : 0;
      final prev = forward ? end - 1 : end + 1;
      final next = _continuation(w, end, prev, visited);
      if (next == null) {
        junction = _nodes[_node(w.lat5[end], w.lng5[end])]!.length > 1;
        break;
      }
      w = next.way;
      forward = next.forward;
      visited.add(w.id);
      spans.add((fromM: total, way: w));
      i = next.from + (forward ? 1 : -1);
    }
    return RoadAhead(line: line, spans: spans, endedAtJunction: junction);
  }

  ({RoadWay way, bool forward, int from})? _continuation(RoadWay w, int end, int prev, Set<int> visited) {
    final list = _nodes[_node(w.lat5[end], w.lng5[end])];
    if (list == null) return null;
    final kx = math.cos(w.latAt(end) * math.pi / 180);
    final inB = _bearing((w.lng5[end] - w.lng5[prev]) * kx, (w.lat5[end] - w.lat5[prev]).toDouble());
    final cands = <({RoadWay way, bool forward, int from, double score, double turn})>[];
    for (final packed in list) {
      final c = _ways[packed >> 12];
      final at = packed & 0xfff;
      if (identical(c, w)) continue;
      if (visited.contains(c.id) && c.id != w.id) continue;
      for (final dir in const [1, -1]) {
        final nx = at + dir;
        if (nx < 0 || nx >= c.length) continue;
        if (c.oneway != 0 && c.oneway != dir) continue;
        final outB = _bearing((c.lng5[nx] - c.lng5[at]) * kx, (c.lat5[nx] - c.lat5[at]).toDouble());
        final turn = _diff(inB, outB);
        if (turn > 120) continue; // back where we came from
        var score = turn;
        if (c.id == w.id) score -= 30; // the same way, split at a cell edge
        if (c.name.isNotEmpty && c.name == w.name) score -= 20;
        if (c.cls == w.cls) score -= 8;
        if (c.highway == 'service') score += 25;
        cands.add((way: c, forward: dir == 1, from: at, score: score, turn: turn));
      }
    }
    if (cands.isEmpty) return null;
    cands.sort((x, y) => x.score.compareTo(y.score));
    final top = cands.first;
    if (top.turn > maxContinueTurnDeg) return null; // a turn at a junction: not predicted
    for (final c in cands.skip(1)) {
      // The same road seen in two overlapping cells is one candidate, not a rival.
      if (c.way.id == top.way.id && (c.turn - top.turn).abs() < 10) continue;
      if (c.score - top.score < 12) return null; // two roads about equally likely: not predicted
      break;
    }
    final best = (way: top.way, forward: top.forward, from: top.from);
    return best;
  }

  /// Schools / hospitals within [withinM] of a point: (school, hospital).
  (bool, bool) zonesNear(double lat, double lng, {double withinM = 150}) {
    var school = false, hospital = false;
    final k = math.cos(lat * math.pi / 180) * 111320.0;
    for (final c in _cells.values) {
      for (final z in c.zones) {
        final dx = (z.lng - lng) * k, dy = (z.lat - lat) * 110540.0;
        if (dx * dx + dy * dy > withinM * withinM) continue;
        if (z.school) {
          school = true;
        } else {
          hospital = true;
        }
      }
    }
    return (school, hospital);
  }

  /// The corrected limit of a road (riders' votes), or null.
  int? correctionFor(int wayId) {
    for (final c in _cells.values) {
      final v = c.corrections[wayId];
      if (v != null) return v;
    }
    return null;
  }
}
