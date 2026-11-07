import 'dart:math' as math;

import '../tracking/geo_math.dart';

/// One sharp bend found on a route line.
class Bend {
  const Bend({
    required this.startAlongM,
    required this.endAlongM,
    required this.turnDeg,
    required this.radiusM,
    required this.advisoryKmh,
  });

  /// Where the bend starts and ends along the line (metres from its first point).
  final double startAlongM;
  final double endAlongM;

  /// Net heading change through the bend: positive = right, negative = left.
  final double turnDeg;

  /// Estimated radius of the tightest part.
  final double radiusM;

  /// Comfortable speed through it (km/h, rounded down to 5, at least [BendAdvisor.minAdvisoryKmh]).
  final int advisoryKmh;

  @override
  String toString() => 'Bend(${startAlongM.round()}-${endAlongM.round()} m, ${turnDeg.round()} deg, r ${radiusM.round()} m, $advisoryKmh km/h)';
}

/// "Sharp bend in 300 m, slow to 35."
class BendWarning {
  const BendWarning({required this.bend, required this.distanceM, required this.advisoryKmh, required this.count});

  final Bend bend;

  /// Metres from the rider to the start of the (first) bend.
  final double distanceM;

  /// The slowest advisory of the bends warned together.
  final int advisoryKmh;

  /// Bends warned together (an S-bend or a chain of hairpins is one warning).
  final int count;

  /// Distance in the speech: rounded to 50 m.
  int get roundedM => math.max(50, (distanceM / 50).round() * 50);

  String get title => count > 1 ? 'Sharp bends in $roundedM m' : 'Sharp bend in $roundedM m';
  String get message => 'Slow to $advisoryKmh km/h.';
  String get speech => count > 1 ? 'Sharp bends in $roundedM metres, slow to $advisoryKmh.' : 'Sharp bend in $roundedM metres, slow to $advisoryKmh.';
}

/// Sharp-bend warning (3.55), pure and offline: curvature from the route line the rider follows
/// plus the current speed.
///
/// Detection ([detect], once per line): heading changes at the line's vertices are grouped into
/// bends (same direction, turning vertices at most [maxGapM] apart). A bend counts when it turns
/// [minTurnDeg] or more and its tightest part (the shortest run of vertices holding 75% of the
/// turn) has a radius of [maxRadiusM] or less. A corner of 60 degrees or more within 10 m of line
/// is a junction turn (the navigation voice already handles it) and is skipped.
///
/// Advisory speed: v = sqrt(a * r) with a conservative lateral acceleration of [lateralAccel]
/// m/s^2, rounded down to 5 km/h, never below [minAdvisoryKmh].
///
/// Warning ([onFix]): only when riding at least [minSpeedKmh] and notably faster than the
/// advisory (+10 km/h and +20%), at a lead distance of at least 6 s of riding plus the distance to
/// slow down gently (at least 150 m, at most 600 m), once per bend, with a [cooldown] between two
/// warnings. Bends within [chainM] of each other are warned together with the slowest advisory.
class BendAdvisor {
  BendAdvisor({this.cooldown = const Duration(seconds: 20)});

  static const double minTurnDeg = 40;
  static const double maxRadiusM = 200;
  static const double minVertexTurnDeg = 3;
  static const double maxGapM = 60;
  static const double junctionTurnDeg = 60;
  static const double lateralAccel = 2.5;
  static const int minAdvisoryKmh = 20;
  static const double minSpeedKmh = 35;
  static const double leadSeconds = 6;
  static const double minLeadM = 150;
  static const double maxLeadM = 600;
  static const double brakeDecel = 2.5; // m/s^2, gentle
  static const double chainM = 250;

  final Duration cooldown;

  Object? _lineKey;
  int _lineLen = -1;
  List<Bend> _bends = const [];
  final Set<int> _warned = {};
  int _lastWarnMs = -1 << 40;

  /// The bends of the current line (after [setLine]).
  List<Bend> get bends => _bends;

  /// Uses [line] (cached: the same list instance is analysed once).
  void setLine(List<(double, double)>? line) {
    if (line == null || line.length < 3) {
      if (_lineKey != null) _reset(null, -1, const []);
      return;
    }
    if (identical(line, _lineKey) && line.length == _lineLen) return;
    _reset(line, line.length, detect(line));
  }

  void _reset(Object? key, int len, List<Bend> bends) {
    _lineKey = key;
    _lineLen = len;
    _bends = bends;
    _warned.clear();
  }

  void reset() {
    _reset(null, -1, const []);
    _lastWarnMs = -1 << 40;
  }

  /// Advisory speed for a radius (km/h).
  static int advisoryKmhFor(double radiusM) {
    final v = math.sqrt(lateralAccel * math.max(0, radiusM)) * 3.6;
    final rounded = (v / 5).floor() * 5;
    return math.max(minAdvisoryKmh, rounded);
  }

  /// The lead distance at which a bend is warned (metres).
  static double leadFor(double speedKmh, int advisoryKmh) {
    final v = speedKmh / 3.6, va = advisoryKmh / 3.6;
    final brake = v > va ? (v * v - va * va) / (2 * brakeDecel) : 0.0;
    return (v * leadSeconds + brake).clamp(minLeadM, maxLeadM).toDouble();
  }

  /// Notably above the advisory: +10 km/h and +20%.
  static bool tooFast(double speedKmh, int advisoryKmh) =>
      speedKmh >= minSpeedKmh && speedKmh >= advisoryKmh + 10 && speedKmh >= advisoryKmh * 1.2;

  /// A warning for the next bend, or null. [alongM] is the rider's position along the line
  /// (metres from its first point), [onLine] false when the rider is off the line.
  BendWarning? onFix({required double alongM, required double speedKmh, required int nowMs, bool onLine = true}) {
    if (!onLine || _bends.isEmpty || !alongM.isFinite) return null;
    if (nowMs - _lastWarnMs < cooldown.inMilliseconds) return null;
    for (var i = 0; i < _bends.length; i++) {
      final b = _bends[i];
      if (b.endAlongM < alongM) continue; // passed
      final dist = b.startAlongM - alongM;
      if (dist < 0) continue; // already in this bend: too late to warn it
      if (dist > maxLeadM) return null; // bends are ordered: nothing closer
      if (_warned.contains(i)) continue;
      // The chain: the next bends close behind this one are warned with it.
      var adv = b.advisoryKmh, n = 1, j = i;
      while (j + 1 < _bends.length && _bends[j + 1].startAlongM - _bends[j].endAlongM <= chainM) {
        j++;
        n++;
        adv = math.min(adv, _bends[j].advisoryKmh);
      }
      if (!tooFast(speedKmh, adv)) {
        // Slow enough for this bend: if the rider is close, it is done; a later speed-up
        // before it can still warn while it is ahead.
        continue;
      }
      if (dist > leadFor(speedKmh, adv)) return null;
      for (var k = i; k <= j; k++) {
        _warned.add(k);
      }
      _lastWarnMs = nowMs;
      return BendWarning(bend: b, distanceM: dist, advisoryKmh: adv, count: n);
    }
    return null;
  }

  // ------------------------------------------------------------------ detection
  static double _wrap(double d) {
    var x = d % 360;
    if (x > 180) x -= 360;
    if (x <= -180) x += 360;
    return x;
  }

  /// All sharp bends of [line], ordered along it.
  static List<Bend> detect(List<(double, double)> line) {
    // Drop repeated points (zero-length segments have no heading).
    final pts = <(double, double)>[];
    for (final p in line) {
      if (pts.isEmpty || GeoMath.haversine(pts.last.$1, pts.last.$2, p.$1, p.$2) > 0.5) pts.add(p);
    }
    if (pts.length < 3) return const [];
    final n = pts.length;
    final cum = List<double>.filled(n, 0);
    final seg = List<double>.filled(n - 1, 0);
    final hdg = List<double>.filled(n - 1, 0);
    for (var i = 0; i < n - 1; i++) {
      seg[i] = GeoMath.haversine(pts[i].$1, pts[i].$2, pts[i + 1].$1, pts[i + 1].$2);
      cum[i + 1] = cum[i] + seg[i];
      hdg[i] = GeoMath.bearing(pts[i].$1, pts[i].$2, pts[i + 1].$1, pts[i + 1].$2);
    }
    // Turn at each inner vertex.
    final turn = List<double>.filled(n, 0);
    for (var v = 1; v < n - 1; v++) {
      turn[v] = _wrap(hdg[v] - hdg[v - 1]);
    }
    final out = <Bend>[];
    var v = 1;
    while (v < n - 1) {
      if (turn[v].abs() < minVertexTurnDeg) {
        v++;
        continue;
      }
      final sign = turn[v].sign;
      final run = <int>[v];
      var w = v + 1;
      while (w < n - 1) {
        final t = turn[w];
        if (t.abs() >= minVertexTurnDeg) {
          if (t.sign != sign) break;
          if (cum[w] - cum[run.last] > maxGapM) break;
          run.add(w);
        } else if (cum[w] - cum[run.last] > maxGapM) {
          break;
        }
        w++;
      }
      v = run.last + 1;
      final bend = _bendOf(run, turn, cum, seg);
      if (bend != null) out.add(bend);
    }
    return out;
  }

  static Bend? _bendOf(List<int> run, List<double> turn, List<double> cum, List<double> seg) {
    var total = 0.0;
    for (final v in run) {
      total += turn[v];
    }
    if (total.abs() < minTurnDeg) return null;
    // Arc length of a vertex sub-run [a..b] of the run (indices into run).
    double arc(int a, int b) {
      final va = run[a], vb = run[b];
      if (a == b) {
        final s = math.min(seg[va - 1], seg[va]);
        return s.clamp(5.0, 20.0).toDouble();
      }
      final span = cum[vb] - cum[va];
      return span + span / (b - a); // n vertices hold about n spacings of arc
    }

    // Tightest part: the shortest sub-run holding 75% of the turn.
    final need = total.abs() * 0.75;
    var bestA = 0, bestB = run.length - 1;
    var bestLen = arc(0, run.length - 1);
    var bestTurn = total.abs();
    for (var a = 0; a < run.length; a++) {
      var sum = 0.0;
      for (var b = a; b < run.length; b++) {
        sum += turn[run[b]].abs();
        if (sum >= need) {
          final len = arc(a, b);
          if (len < bestLen || (len == bestLen && sum > bestTurn)) {
            bestLen = len;
            bestA = a;
            bestB = b;
            bestTurn = sum;
          }
          break;
        }
      }
    }
    // A junction corner: the turn happens at one spot (one vertex, or a few within 10 m); the
    // navigation voice announces it.
    if (bestTurn >= junctionTurnDeg && cum[run[bestB]] - cum[run[bestA]] <= 10) return null;
    final radius = bestLen / (bestTurn * math.pi / 180);
    if (radius > maxRadiusM) return null;
    final first = run.first, last = run.last;
    final start = math.max(0.0, cum[first] - (run.length == 1 ? 10 : (cum[last] - cum[first]) / (2 * (run.length - 1))));
    return Bend(
      startAlongM: start,
      endAlongM: cum[last],
      turnDeg: total,
      radiusM: radius,
      advisoryKmh: advisoryKmhFor(radius),
    );
  }

  /// Rider position along [line] when no route matcher is available. With [hintAlongM] (the last
  /// answer) only the stretch from 200 m behind to 600 m ahead of it is searched first, so stacked
  /// hairpins that pass close to each other do not make the position jump; the whole line is
  /// searched when nothing there is within [onLineM].
  static ({double alongM, bool onLine})? locate(double lat, double lng, List<(double, double)> line,
      {double? hintAlongM, double onLineM = 40}) {
    if (line.length < 2) return null;
    final k = math.cos(lat * math.pi / 180);
    const r = GeoMath.earthRadiusM;
    double x(double lo) => lo * math.pi / 180 * r * k;
    double y(double la) => la * math.pi / 180 * r;
    final px = x(lng), py = y(lat);
    ({double along, double off}) search(double from, double to) {
      var best = double.infinity, bestAlong = 0.0, acc = 0.0;
      for (var i = 0; i < line.length - 1; i++) {
        final ax = x(line[i].$2), ay = y(line[i].$1), bx = x(line[i + 1].$2), by = y(line[i + 1].$1);
        final dx = bx - ax, dy = by - ay;
        final len2 = dx * dx + dy * dy;
        final segLen = math.sqrt(len2);
        if (acc + segLen >= from && acc <= to) {
          var t = len2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / len2 : 0.0;
          t = t.clamp(0.0, 1.0).toDouble();
          final cx = ax + t * dx, cy = ay + t * dy;
          final d = math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
          if (d < best) {
            best = d;
            bestAlong = acc + t * segLen;
          }
        }
        acc += segLen;
      }
      return (along: bestAlong, off: best);
    }

    if (hintAlongM != null && hintAlongM.isFinite) {
      final near = search(hintAlongM - 200, hintAlongM + 600);
      if (near.off <= onLineM) return (alongM: near.along, onLine: true);
    }
    final all = search(double.negativeInfinity, double.infinity);
    return (alongM: all.along, onLine: all.off <= onLineM);
  }
}
