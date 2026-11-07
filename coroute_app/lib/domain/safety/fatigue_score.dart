// Fatigue score (3.55): break prompts that adapt to the rider, not only the fixed 2 h timer.
//
// Pure Dart, no Flutter, no I/O, no timers. Fed with the rider's own fixes and the 1 s
// accelerometer buckets the crash detector already receives (no new sensor work). Only the
// resulting level (0-100) ever leaves this class; raw sensor values are never shared.
//
// The level combines four signals:
//  * ride time in the current stretch (the FatigueTracker stretch: no stop of 10 min or more):
//    [FatigueScore.timePoints] grows linearly to 60 points at 2 h, capped at 75;
//  * time of day: the time points weigh more in the circadian dips, x1.25 from 14:00 to 16:00
//    and x1.4 from 00:00 to 06:00 (local time);
//  * micro-stops: stops of 1 to 10 min inside the stretch (short, frequent stops are a sign of
//    discomfort or sleepiness), 4 points each, at most 12;
//  * steering wobble: the variance of the gyroscope peak (peakGyroRadS) at a steady speed over
//    the last 10 min, compared with the rider's own baseline from the first 30 min of riding
//    in this ride. A ratio above 1.5 adds up to 20 points.
import 'dart:math' as math;

import '../tracking/track_point.dart';
import 'accel_bucket.dart';

/// One reading of the fatigue score.
class FatigueAssessment {
  /// 0 (fresh) to 100 (very tired).
  final int level;

  /// Minutes until a break is suggested (0: now). Never more than the time left to the
  /// fixed 2 h rule.
  final int suggestedBreakInMin;

  /// The parts, for tests and the ride safety report.
  final double timePoints;
  final double circadianFactor;
  final double microStopPoints;
  final double wobblePoints;

  const FatigueAssessment({
    required this.level,
    required this.suggestedBreakInMin,
    this.timePoints = 0,
    this.circadianFactor = 1,
    this.microStopPoints = 0,
    this.wobblePoints = 0,
  });

  static const FatigueAssessment fresh = FatigueAssessment(level: 0, suggestedBreakInMin: 120);

  @override
  String toString() => 'FatigueAssessment($level, break in $suggestedBreakInMin min, time ${timePoints.toStringAsFixed(1)} '
      'x${circadianFactor.toStringAsFixed(2)}, stops ${microStopPoints.toStringAsFixed(0)}, wobble ${wobblePoints.toStringAsFixed(1)})';
}

/// The pure formula (no state).
class FatigueScore {
  FatigueScore._();

  /// The level at which a break is suggested (the early prompt threshold).
  static const int breakLevel = 70;

  /// Points from ride time: 60 at 2 h, linear, capped at 75 (2 h 30 min).
  static double timePoints(Duration stretch) {
    final min = stretch.inSeconds / 60.0;
    if (min <= 0) return 0;
    return math.min(75.0, min / 120.0 * 60.0);
  }

  /// x1.4 from 00:00 to 06:00, x1.25 from 14:00 to 16:00, else x1.0 (local hour).
  static double circadianFactor(DateTime local) {
    final h = local.hour;
    if (h >= 0 && h < 6) return 1.4;
    if (h >= 14 && h < 16) return 1.25;
    return 1.0;
  }

  /// 4 points per micro-stop, at most 12.
  static double microStopPoints(int microStops) => math.min(12.0, math.max(0, microStops) * 4.0);

  /// Up to 20 points when the steering wobble variance is more than 1.5x the rider's baseline.
  /// Null or non-positive baseline: no points (not enough data yet).
  static double wobblePoints({double? baselineVar, double? currentVar}) {
    if (baselineVar == null || currentVar == null) return 0;
    if (!baselineVar.isFinite || !currentVar.isFinite || baselineVar <= 1e-6) return 0;
    final ratio = currentVar / baselineVar;
    if (ratio <= 1.5) return 0;
    return math.min(20.0, (ratio - 1.5) * 20.0);
  }

  /// Combines the parts. [rideFor] is the fixed rule (2 h): the suggested break is never later.
  static FatigueAssessment assess({
    required Duration stretch,
    required DateTime localTime,
    int microStops = 0,
    double? baselineVar,
    double? currentVar,
    Duration rideFor = const Duration(hours: 2),
  }) {
    final tp = timePoints(stretch);
    final cf = circadianFactor(localTime);
    final mp = microStopPoints(microStops);
    final wp = wobblePoints(baselineVar: baselineVar, currentVar: currentVar);
    final raw = tp * cf + mp + wp;
    final level = raw.isFinite ? raw.round().clamp(0, 100) : 0;
    // Minutes until the level reaches [breakLevel] at the current rate (time points grow by
    // 0.5 per minute, times the circadian factor), never later than the fixed rule.
    final leftToRule = math.max(0, rideFor.inMinutes - stretch.inMinutes);
    int inMin;
    if (level >= breakLevel) {
      inMin = 0;
    } else {
      final perMin = 0.5 * cf;
      final need = breakLevel - raw;
      inMin = (need / perMin).ceil();
      // Past the time points' cap the level stops growing: the rule decides.
      if (tp >= 75.0) inMin = leftToRule;
    }
    inMin = math.min(inMin, leftToRule);
    return FatigueAssessment(
      level: level,
      suggestedBreakInMin: math.max(0, inMin),
      timePoints: tp,
      circadianFactor: cf,
      microStopPoints: mp,
      wobblePoints: wp,
    );
  }
}

/// Keeps the inputs of [FatigueScore] for one ride: micro-stops in the current stretch and the
/// steering wobble baseline / recent window. Pure, fed with fixes and buckets.
class FatigueScoreTracker {
  FatigueScoreTracker({
    this.steadyMinKmh = 30,
    this.steadyMaxDeltaKmh = 5,
    this.baselineFor = const Duration(minutes: 30),
    this.baselineMinSamples = 120,
    this.recentWindow = const Duration(minutes: 10),
    this.recentMinSamples = 60,
    this.microStopMin = const Duration(minutes: 1),
    this.microStopMax = const Duration(minutes: 10),
    this.stopKmh = 5,
  });

  final double steadyMinKmh;
  final double steadyMaxDeltaKmh;
  final Duration baselineFor;
  final int baselineMinSamples;
  final Duration recentWindow;
  final int recentMinSamples;
  final Duration microStopMin;
  final Duration microStopMax;
  final double stopKmh;

  TrackPoint? _last;
  TrackPoint? _prev;

  // Riding time of this ride (moving fixes), for the baseline window.
  int _ridingMs = 0;

  // Baseline (first [baselineFor] of riding): running sums.
  int _baseN = 0;
  double _baseSum = 0;
  double _baseSq = 0;

  // Recent samples (tMs, gyro) for the last [recentWindow].
  final List<(int, double)> _recent = [];

  // Micro-stops of the current stretch.
  int? _stretchStart;
  int? _stopStart;
  int _microStops = 0;

  int get microStops => _microStops;
  int get baselineSamples => _baseN;
  int get recentSamples => _recent.length;

  /// Variance of the baseline, null until [baselineMinSamples] samples were seen.
  double? get baselineVar {
    if (_baseN < baselineMinSamples) return null;
    final mean = _baseSum / _baseN;
    return math.max(0.0, _baseSq / _baseN - mean * mean);
  }

  /// Variance of the recent window, null with fewer than [recentMinSamples].
  double? get currentVar {
    if (_recent.length < recentMinSamples) return null;
    var s = 0.0, q = 0.0;
    for (final r in _recent) {
      s += r.$2;
      q += r.$2 * r.$2;
    }
    final n = _recent.length;
    final mean = s / n;
    return math.max(0.0, q / n - mean * mean);
  }

  /// A fix of mine; [stretchStart] is the FatigueTracker's current stretch (null on a break).
  void onFix(TrackPoint p, {int? stretchStart}) {
    final last = _last;
    if (last != null && p.ts < last.ts) return;
    if (last != null) {
      final gap = p.ts - last.ts;
      if (gap > 0 && gap <= 30000 && p.speedKmh >= stopKmh) _ridingMs += gap;
    }
    _prev = last;
    _last = p;
    if (stretchStart != _stretchStart) {
      _stretchStart = stretchStart;
      _microStops = 0;
      _stopStart = null;
    }
    if (stretchStart == null) return;
    if (p.speedKmh < stopKmh) {
      _stopStart ??= p.ts;
    } else {
      final s = _stopStart;
      if (s != null) {
        final d = p.ts - s;
        if (d >= microStopMin.inMilliseconds && d < microStopMax.inMilliseconds) _microStops++;
      }
      _stopStart = null;
    }
  }

  /// True when the last two fixes show a steady speed (fresh, fast enough, no big change).
  bool steadyAt(int tMs) {
    final a = _last, b = _prev;
    if (a == null || b == null) return false;
    if ((tMs - a.ts).abs() > 5000 || a.ts - b.ts > 10000) return false;
    return a.speedKmh >= steadyMinKmh && b.speedKmh >= steadyMinKmh && (a.speedKmh - b.speedKmh).abs() < steadyMaxDeltaKmh;
  }

  /// A 1 s bucket: counted only at a steady speed and with a usable sensor.
  void onAccel(AccelBucket b) {
    if (b.sensorConfidence < 0.5 || !b.peakGyroRadS.isFinite) return;
    if (!steadyAt(b.tMs)) return;
    // Crash-like seconds are not steering: never part of the wobble.
    if (b.peakG >= 3.0 || b.tiltDeg >= 45) return;
    final g = b.peakGyroRadS;
    if (_ridingMs <= baselineFor.inMilliseconds) {
      _baseN++;
      _baseSum += g;
      _baseSq += g * g;
      return;
    }
    _recent.add((b.tMs, g));
    final from = b.tMs - recentWindow.inMilliseconds;
    while (_recent.isNotEmpty && _recent.first.$1 < from) {
      _recent.removeAt(0);
    }
    // Bounded: at most one sample per second of the window.
    while (_recent.length > recentWindow.inSeconds + 5) {
      _recent.removeAt(0);
    }
  }

  /// The current reading at [nowMs] ([localTime] for the circadian weight).
  FatigueAssessment assess({required int nowMs, required DateTime localTime}) {
    final start = _stretchStart;
    final stretch = start == null ? Duration.zero : Duration(milliseconds: math.max(0, nowMs - start));
    return FatigueScore.assess(
      stretch: stretch,
      localTime: localTime,
      microStops: _microStops,
      baselineVar: baselineVar,
      currentVar: currentVar,
    );
  }

  void reset() {
    _last = null;
    _prev = null;
    _ridingMs = 0;
    _baseN = 0;
    _baseSum = 0;
    _baseSq = 0;
    _recent.clear();
    _stretchStart = null;
    _stopStart = null;
    _microStops = 0;
  }
}

/// When an adaptive (early) fatigue prompt may be shown. Pure.
///
/// * only from [minStretch] (45 min) of riding and with a level of [FatigueScore.breakLevel];
/// * never within [spacing] (30 min) of any fatigue prompt (early or the fixed rule);
/// * never within [spacing] before the fixed rule's next reminder (it comes anyway, and the
///   rider must not get two prompts within 30 min);
/// * the fixed 2 h rule itself is never delayed by this class.
class FatigueEarlyPromptGate {
  FatigueEarlyPromptGate({
    this.minStretch = const Duration(minutes: 45),
    this.spacing = const Duration(minutes: 30),
    this.rideFor = const Duration(hours: 2),
    this.remindAgain = const Duration(minutes: 60),
  });

  final Duration minStretch;
  final Duration spacing;
  final Duration rideFor;
  final Duration remindAgain;

  int? _lastPromptAt;
  int? _lastRuleAt;
  int? _stretch;

  int? get lastPromptAt => _lastPromptAt;

  /// The fixed rule reminded at [tMs] (FatigueTracker.onFix returned true).
  void noteRulePrompt(int tMs) {
    _lastRuleAt = tMs;
    _lastPromptAt = tMs;
  }

  /// An early prompt was shown at [tMs].
  void noteEarlyPrompt(int tMs) => _lastPromptAt = tMs;

  bool allowed({required int nowMs, required int? stretchStart, required int level}) {
    if (stretchStart != _stretch) {
      _stretch = stretchStart;
      _lastRuleAt = null; // a new stretch: the rule starts again
    }
    if (stretchStart == null) return false;
    if (level < FatigueScore.breakLevel) return false;
    if (nowMs - stretchStart < minStretch.inMilliseconds) return false;
    final last = _lastPromptAt;
    if (last != null && nowMs - last < spacing.inMilliseconds) return false;
    final rule = _lastRuleAt;
    final nextRule = rule == null ? stretchStart + rideFor.inMilliseconds : rule + remindAgain.inMilliseconds;
    if (nextRule - nowMs < spacing.inMilliseconds) return false;
    return true;
  }

  void reset() {
    _lastPromptAt = null;
    _lastRuleAt = null;
    _stretch = null;
  }
}
