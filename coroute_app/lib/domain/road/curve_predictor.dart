import 'dart:math' as math;

/// How tight a bend is. Ordered: a later value is more severe.
enum CurveClass { gentle, medium, sharp, hairpin }

/// One bend on a line (a planned route, or the road ahead in free riding).
class RoadCurve {
  const RoadCurve({
    required this.startM,
    required this.apexM,
    required this.endM,
    required this.radiusM,
    required this.turnDeg,
    required this.cls,
    required this.apexLat,
    required this.apexLng,
    this.junction = false,
    this.learned = false,
  });

  /// Metres along the line (from its first point).
  final double startM, apexM, endM;

  /// Radius of the tightest part.
  final double radiusM;

  /// Net heading change: positive = right, negative = left.
  final double turnDeg;
  final CurveClass cls;
  final double apexLat, apexLng;

  /// A corner at one point of the line (a turn at a junction; the navigation voice announces it).
  final bool junction;

  /// Riders braked hard here (road intelligence): the class was raised one step.
  final bool learned;

  bool get right => turnDeg > 0;

  /// The same bend seen again on another look-ahead line: its apex on a grid of about 30 m and its side.
  String get key => '${(apexLat * 3000).round()}:${(apexLng * 3000).round()}:${right ? 'R' : 'L'}';

  RoadCurve raised() => RoadCurve(
        startM: startM,
        apexM: apexM,
        endM: endM,
        radiusM: radiusM,
        turnDeg: turnDeg,
        cls: CurveClass.values[math.min(cls.index + 1, CurveClass.hairpin.index)],
        apexLat: apexLat,
        apexLng: apexLng,
        junction: junction,
        learned: true,
      );

  RoadCurve shifted(double byM) => RoadCurve(
        startM: startM + byM,
        apexM: apexM + byM,
        endM: endM + byM,
        radiusM: radiusM,
        turnDeg: turnDeg,
        cls: cls,
        apexLat: apexLat,
        apexLng: apexLng,
        junction: junction,
        learned: learned,
      );

  @override
  String toString() => 'RoadCurve(${cls.name} ${right ? 'right' : 'left'} ${startM.round()}-${endM.round()} m, r ${radiusM.round()} m, ${turnDeg.round()} deg)';
}

/// What lowers the comfortable speed.
class CurveConditions {
  const CurveConditions({this.dark = false, this.rain = false, this.cautious = false});
  final bool dark;

  /// Only when known (no weather source rides with the phone today: false).
  final bool rain;

  /// The rider chose the cautious setting (or the rider score suggests it).
  final bool cautious;

  static const CurveConditions normal = CurveConditions();
}

/// Curvature of a line, pure and offline (round 7; docs/features_355/curve_and_speed_limit.md).
///
/// 1. The line is projected to metres and resampled every [stepM] (10 m), so dense and sparse
///    lines are treated alike.
/// 2. The heading at each sample is the chord over two steps (20 m), the turn between samples is
///    smoothed (1-2-1): a point that is a few metres off (GPS noise, a coarse map) does not make
///    a bend.
/// 3. Samples that turn the same way are grouped into one bend; its radius is the arc length of
///    the tightest part (the shortest run holding 70% of the turn, less one step for the
///    smoothing) divided by that turn.
/// 4. Class from radius and turn: hairpin (turn of 135 degrees or more, radius up to 30 m), sharp
///    (radius up to 40 m, or up to 60 m with 75 degrees or more), medium (up to 100 m), gentle
///    (up to 250 m).
///
/// ADVISORY ONLY: map lines are simplified and can be metres off, so the radius is an estimate.
class CurveAnalyzer {
  CurveAnalyzer._();

  static const double stepM = 10;
  static const double minSampleTurnDeg = 2.0;
  static const double maxGapM = 25;
  static const double g = 9.80665;

  /// Lateral acceleration budget (in g) for the advisory speed.
  static double lateralG(CurveConditions c) {
    var a = 0.28;
    if (c.dark) a = math.min(a, 0.24);
    if (c.rain) a = math.min(a, 0.20);
    if (c.cautious) a -= 0.03;
    return math.max(0.15, a);
  }

  /// Comfortable speed through [curve] in km/h: sqrt(a * r), rounded down to 5, at least 15, a
  /// learned (hard-braking) bend 15% lower, never above [limitKmh] when a limit is known.
  static int advisoryKmh(RoadCurve curve, {CurveConditions conditions = CurveConditions.normal, int? limitKmh}) {
    var a = lateralG(conditions) * g;
    if (curve.learned) a *= 0.72; // speed scales with sqrt: about 15% slower
    final v = math.sqrt(a * math.max(0, curve.radiusM)) * 3.6;
    var out = math.max(15, (v / 5).floor() * 5);
    if (limitKmh != null && limitKmh > 0 && out > limitKmh) out = limitKmh;
    return out;
  }

  static CurveClass? classify(double radiusM, double turnAbsDeg) {
    if (turnAbsDeg >= 135 && radiusM <= 30) return CurveClass.hairpin;
    if (turnAbsDeg >= 30 && (radiusM <= 40 || (radiusM <= 60 && turnAbsDeg >= 75))) return CurveClass.sharp;
    if (turnAbsDeg >= 25 && radiusM <= 100) return CurveClass.medium;
    if (turnAbsDeg >= 25 && radiusM <= 250) return CurveClass.gentle;
    return null;
  }

  static double _wrap(double d) {
    var x = d % 360;
    if (x > 180) x -= 360;
    if (x <= -180) x += 360;
    return x;
  }

  /// The bends of [line] (lat, lng), ordered along it. [hardBrakeSpots]: places where riders
  /// brake hard (road intelligence cells); a bend within [learnedRadiusM] of one is raised a class.
  static List<RoadCurve> analyze(List<(double, double)> line, {List<(double, double)> hardBrakeSpots = const [], double learnedRadiusM = 120}) {
    if (line.length < 3) return const [];
    // ---- metres
    final lat0 = line.first.$1, lng0 = line.first.$2;
    final kx = math.cos(lat0 * math.pi / 180) * 111320.0;
    const ky = 110540.0;
    final xs = <double>[], ys = <double>[];
    for (final p in line) {
      final x = (p.$2 - lng0) * kx, y = (p.$1 - lat0) * ky;
      if (xs.isEmpty || (x - xs.last).abs() + (y - ys.last).abs() > 0.5) {
        xs.add(x);
        ys.add(y);
      }
    }
    final n = xs.length;
    if (n < 3) return const [];
    // ---- corners at one point of the raw line (both neighbours at least 15 m away)
    final corners = <double>[]; // along metres
    final cum = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      cum[i] = cum[i - 1] + math.sqrt((xs[i] - xs[i - 1]) * (xs[i] - xs[i - 1]) + (ys[i] - ys[i - 1]) * (ys[i] - ys[i - 1]));
    }
    double hdg(double dx, double dy) => math.atan2(dx, dy) * 180 / math.pi;
    for (var i = 1; i < n - 1; i++) {
      final a = cum[i] - cum[i - 1], b = cum[i + 1] - cum[i];
      if (a < 15 || b < 15) continue;
      final t = _wrap(hdg(xs[i + 1] - xs[i], ys[i + 1] - ys[i]) - hdg(xs[i] - xs[i - 1], ys[i] - ys[i - 1]));
      if (t.abs() >= 60) corners.add(cum[i]);
    }
    final total = cum[n - 1];
    if (total < 3 * stepM) return const [];
    // ---- resample every stepM
    final m = (total / stepM).floor() + 1;
    final rx = List<double>.filled(m, 0), ry = List<double>.filled(m, 0);
    var seg = 0;
    for (var k = 0; k < m; k++) {
      final d = k * stepM;
      while (seg < n - 2 && cum[seg + 1] < d) {
        seg++;
      }
      final len = cum[seg + 1] - cum[seg];
      final t = len > 0 ? ((d - cum[seg]) / len).clamp(0.0, 1.0) : 0.0;
      rx[k] = xs[seg] + (xs[seg + 1] - xs[seg]) * t;
      ry[k] = ys[seg] + (ys[seg + 1] - ys[seg]) * t;
    }
    if (m < 4) return const [];
    // ---- heading by the chord over two steps, turn per sample, smoothed 1-2-1
    final h = List<double>.filled(m, 0);
    for (var k = 0; k < m; k++) {
      final a = math.max(0, k - 1), b = math.min(m - 1, k + 1);
      h[k] = hdg(rx[b] - rx[a], ry[b] - ry[a]);
    }
    final raw = List<double>.filled(m, 0);
    for (var k = 1; k < m; k++) {
      raw[k] = _wrap(h[k] - h[k - 1]);
    }
    final turn = List<double>.filled(m, 0);
    for (var k = 1; k < m; k++) {
      final a = raw[math.max(1, k - 1)], b = raw[math.min(m - 1, k + 1)];
      turn[k] = (a + 2 * raw[k] + b) / 4;
    }
    // ---- group samples turning the same way
    final out = <RoadCurve>[];
    var k = 1;
    while (k < m) {
      if (turn[k].abs() < minSampleTurnDeg) {
        k++;
        continue;
      }
      final sign = turn[k].sign;
      final first = k;
      var last = k, j = k + 1;
      while (j < m) {
        if (turn[j].abs() >= minSampleTurnDeg) {
          if (turn[j].sign != sign) break;
          last = j;
        } else if ((j - last) * stepM > maxGapM) {
          break;
        }
        j++;
      }
      k = last + 1;
      var sum = 0.0;
      for (var i = first; i <= last; i++) {
        sum += turn[i];
      }
      final abs = sum.abs();
      if (abs < 25) continue;
      // Tightest part: the shortest run of samples holding 70% of the turn.
      final need = abs * 0.7;
      var bestLen = (last - first + 1) * stepM, bestTurn = abs, bestA = first, bestB = last;
      for (var a = first; a <= last; a++) {
        var s = 0.0;
        for (var b = a; b <= last; b++) {
          s += turn[b].abs();
          if (s >= need) {
            final len = (b - a + 1) * stepM;
            if (len < bestLen) {
              bestLen = len;
              bestTurn = s;
              bestA = a;
              bestB = b;
            }
            break;
          }
        }
      }
      // The two-step chord and the smoothing spread a turn over about one more step than it has:
      // take that step off again, so tight bends are not read as wider (the unsafe direction).
      final radius = math.max(stepM, bestLen - stepM) / (bestTurn * math.pi / 180);
      final cls = classify(radius, abs);
      if (cls == null) continue;
      final startM = math.max(0.0, (first - 1) * stepM), endM = last * stepM;
      final apexK = ((bestA + bestB) / 2).round();
      final apexM = apexK * stepM;
      final apexLat = lat0 + ry[apexK] / ky, apexLng = lng0 + rx[apexK] / kx;
      final junction = endM - startM <= 50 && corners.any((c) => c >= startM - 10 && c <= endM + 10);
      var curve = RoadCurve(startM: startM, apexM: apexM, endM: endM, radiusM: radius, turnDeg: sum, cls: cls, apexLat: apexLat, apexLng: apexLng, junction: junction);
      for (final s in hardBrakeSpots) {
        final dx = (s.$2 - apexLng) * kx, dy = (s.$1 - apexLat) * ky;
        if (dx * dx + dy * dy <= learnedRadiusM * learnedRadiusM) {
          curve = curve.raised();
          break;
        }
      }
      out.add(curve);
    }
    return out;
  }

  /// "Series of bends": from [from], the run of bends (medium or tighter) with gaps of at most
  /// [gapM]. Returns the index of the last bend of the run and its length; null for fewer than 3.
  static ({int lastIndex, double lengthM})? seriesFrom(List<RoadCurve> curves, int from, {double gapM = 150}) {
    var last = from, count = 1;
    for (var i = from + 1; i < curves.length; i++) {
      if (curves[i].cls.index < CurveClass.medium.index) continue;
      if (curves[i].startM - curves[last].endM > gapM) break;
      last = i;
      count++;
    }
    if (count < 3) return null;
    return (lastIndex: last, lengthM: curves[last].endM - curves[from].startM);
  }
}

/// "Sharp right bend in 150 m, slow to 35."
class CurveWarning {
  const CurveWarning({required this.curve, required this.distanceM, required this.advisoryKmh, this.seriesLengthM = 0, this.seriesCount = 1});

  final RoadCurve curve;
  final double distanceM;
  final int advisoryKmh;

  /// More than 0: a series of bends of this length starts here.
  final double seriesLengthM;
  final int seriesCount;

  bool get isSeries => seriesLengthM > 0;
  int get roundedM => math.max(50, (distanceM / 50).round() * 50);
  String get side => curve.right ? 'right' : 'left';

  String get _name => switch (curve.cls) {
        CurveClass.hairpin => 'Hairpin $side',
        CurveClass.sharp => 'Sharp $side bend',
        CurveClass.medium => '${curve.right ? 'Right' : 'Left'} bend',
        CurveClass.gentle => 'Gentle $side bend',
      };

  String get _seriesKm {
    final km = seriesLengthM / 1000;
    return km >= 0.95 ? '${km.round()} km' : '${math.max(100, (seriesLengthM / 100).round() * 100)} m';
  }

  String get title => isSeries ? 'Series of bends for $_seriesKm' : '$_name in $roundedM m';
  String get message => 'Slow to $advisoryKmh km/h.';
  String get speech => isSeries
      ? 'Series of bends for $_seriesKm, first one $side. Slow to $advisoryKmh.'
      : '$_name in $roundedM metres. Slow to $advisoryKmh.';

  /// Short text on the cockpit chip.
  String get chip => '$advisoryKmh';
}

/// When to warn (pure; fed with each fix):
///  * a bend that is medium or tighter, ahead by at most [leadSeconds] of riding at the current
///    speed (never less than [minLeadM], never more than [maxLeadM]);
///  * only when the rider is faster than the advisory speed plus a margin (5 km/h and 10%): a rider
///    who is already slow enough hears nothing;
///  * once per bend (also when the look-ahead line is rebuilt), at least [minGap] between two
///    warnings; three or more bends close together are one "series of bends" warning, and a much
///    tighter bend inside the series may still warn on its own;
///  * a junction corner is left to the navigation voice unless [includeJunctions].
class CurveWarner {
  CurveWarner({this.minGap = const Duration(seconds: 8)});

  static const double leadSeconds = 7;
  static const double minLeadM = 80;
  static const double maxLeadM = 400;
  static const double minSpeedKmh = 25;
  static const double tooLateM = 15;

  final Duration minGap;
  final Set<String> _warned = <String>{};
  int _lastWarnMs = -1 << 40;

  void reset() {
    _warned.clear();
    _lastWarnMs = -1 << 40;
  }

  static double leadFor(double speedKmh) => (speedKmh / 3.6 * leadSeconds).clamp(minLeadM, maxLeadM).toDouble();

  /// Faster than the advisory plus the margin.
  static bool tooFast(double speedKmh, int advisoryKmh) =>
      speedKmh >= minSpeedKmh && speedKmh > advisoryKmh + math.max(5.0, advisoryKmh * 0.10);

  CurveWarning? onFix({
    required List<RoadCurve> curves,
    required double alongM,
    required double speedKmh,
    required int nowMs,
    CurveConditions conditions = CurveConditions.normal,
    int? limitKmh,
    bool includeJunctions = false,
    bool enabled = true,
  }) {
    if (!enabled || curves.isEmpty || !alongM.isFinite || !speedKmh.isFinite) return null;
    if (nowMs - _lastWarnMs < minGap.inMilliseconds) return null;
    final lead = leadFor(speedKmh);
    for (var i = 0; i < curves.length; i++) {
      final c = curves[i];
      final dist = c.startM - alongM;
      if (dist < tooLateM) continue; // passed, in it, or too late to be useful
      if (dist > lead) return null; // ordered along the line: nothing nearer
      if (c.cls.index < CurveClass.medium.index) continue; // gentle bends are never announced
      if (c.junction && !includeJunctions) continue;
      if (_warned.contains(c.key)) continue;
      var adv = CurveAnalyzer.advisoryKmh(c, conditions: conditions, limitKmh: limitKmh);
      final series = CurveAnalyzer.seriesFrom(curves, i);
      var count = 1;
      if (series != null) {
        // The series is announced with the slowest of its first three bends.
        var seen = 0;
        for (var j = i; j <= series.lastIndex && seen < 3; j++) {
          if (curves[j].cls.index < CurveClass.medium.index) continue;
          seen++;
          adv = math.min(adv, CurveAnalyzer.advisoryKmh(curves[j], conditions: conditions, limitKmh: limitKmh));
        }
        count = 0;
        for (var j = i; j <= series.lastIndex; j++) {
          if (curves[j].cls.index >= CurveClass.medium.index) count++;
        }
      }
      if (!tooFast(speedKmh, adv)) continue; // slow enough: quiet (a later speed-up can still warn)
      _remember(c.key);
      if (series != null) {
        for (var j = i + 1; j <= series.lastIndex; j++) {
          // A much tighter bend deeper in the series keeps its own warning.
          final own = CurveAnalyzer.advisoryKmh(curves[j], conditions: conditions, limitKmh: limitKmh);
          if (own > adv - 10) _remember(curves[j].key);
        }
      }
      _lastWarnMs = nowMs;
      return CurveWarning(curve: c, distanceM: dist, advisoryKmh: adv, seriesLengthM: series?.lengthM ?? 0, seriesCount: count);
    }
    return null;
  }

  void _remember(String key) {
    if (_warned.length >= 400) _warned.remove(_warned.first);
    _warned.add(key);
  }
}
