// 3.55 false-SOS review: "is the rider simply riding on?" from the phone's own GPS fixes.
//
// Pure Dart, no timers. Used by the crash detector (an impact followed by continued riding is a
// pothole, a speed breaker or a loose phone, never a crash), by the crash alarm countdown (riding
// away cancels it before an automatic SOS goes out) and by the check-in escalations (a rider who is
// visibly riding with good GPS is never reported as "no reply").
import 'dart:math' as math;

import '../tracking/track_point.dart';

/// Sustained riding from consecutive fixes: every fix in the run is faster than [minKmh], accurate
/// (accuracy <= [maxAccuracyM], or unknown), the run spans at least [minSpan], and the speed did
/// not collapse inside the run (the slowest fix is at least [minHoldShare] of the fastest one), so
/// a bike sliding to a stop after a crash (80, 55, 30, 10 km/h) never counts as riding on.
class RideOnRun {
  RideOnRun({
    this.minKmh = 15,
    this.minSpan = const Duration(seconds: 3),
    this.maxAccuracyM = 50,
    this.minHoldShare = 0.6,
    this.maxGap = const Duration(seconds: 4),
  });

  final double minKmh;
  final Duration minSpan;
  final double maxAccuracyM;
  final double minHoldShare;
  final Duration maxGap;

  int? _from;
  int? _last;
  double _min = double.infinity;
  double _max = 0;

  /// Feeds one fix; true once the run qualifies as riding on.
  bool add(TrackPoint p) {
    final accurate = p.accuracyM <= 0 || p.accuracyM <= maxAccuracyM;
    if (!accurate) return riding; // a rough fix neither breaks nor extends the run
    final last = _last;
    if (last != null && p.ts <= last) return riding; // out of order / repeated
    if (p.speedKmh <= minKmh || (last != null && p.ts - last > maxGap.inMilliseconds)) {
      reset();
      if (p.speedKmh <= minKmh) return false;
    }
    _from ??= p.ts;
    _last = p.ts;
    _min = math.min(_min, p.speedKmh);
    _max = math.max(_max, p.speedKmh);
    return riding;
  }

  /// True while the current run qualifies.
  bool get riding {
    final from = _from, last = _last;
    if (from == null || last == null) return false;
    if (last - from < minSpan.inMilliseconds) return false;
    return _max <= 0 || _min >= _max * minHoldShare;
  }

  void reset() {
    _from = null;
    _last = null;
    _min = double.infinity;
    _max = 0;
  }
}

/// True when [fix] shows the rider riding normally right now: fresh (at most [freshFor] old at
/// [nowMs]), accurate (at most [maxAccuracyM]) and at least [minKmh]. A stale or rough fix is
/// never taken as proof of riding (a crashed phone keeps its last speed).
bool ridingNormally(
  TrackPoint? fix, {
  required int nowMs,
  double minKmh = 15,
  Duration freshFor = const Duration(seconds: 15),
  double maxAccuracyM = 30,
}) {
  if (fix == null) return false;
  final age = nowMs - fix.ts;
  if (age < -5000 || age > freshFor.inMilliseconds) return false;
  if (!(fix.accuracyM <= 0 || fix.accuracyM <= maxAccuracyM)) return false;
  return fix.speedKmh >= minKmh;
}
