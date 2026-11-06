import 'dart:math' as math;
import '../../core/constants/safety_constants.dart';
import '../tracking/geo_math.dart';
import '../tracking/track_point.dart';
import 'accel_bucket.dart';
import 'crash_incident.dart';

/// Thresholds of the crash rule. Defaults come from [SafetyConstants].
class CrashThresholds {
  final double armSpeedKmh;
  final Duration armSustain;
  final double instantArmSpeedKmh;
  final Duration disarmAfter;
  final double lowSpeedArmKmh;
  final Duration armWindow;
  final double impactG;
  final double dynamicImpactG;
  final double slideImpactG;
  final double rotationRadS;
  final double tiltThresholdDeg;
  final double minDurationMs;
  final Duration stopWithin;
  final Duration highSpeedStopWithin;
  final double stopSpeedKmh;
  final Duration stillFor;
  final double stillStdG;
  final double stillMaxMoveM;
  final double resumeKmh;
  final Duration settle;
  final Duration cooldown;

  const CrashThresholds({
    this.armSpeedKmh = SafetyConstants.crashArmSpeedKmh,
    this.armSustain = SafetyConstants.crashArmSustain,
    this.instantArmSpeedKmh = SafetyConstants.crashInstantArmKmh,
    this.disarmAfter = SafetyConstants.crashDisarmAfter,
    this.lowSpeedArmKmh = SafetyConstants.crashLowSpeedArmKmh,
    this.armWindow = SafetyConstants.crashArmWindow,
    this.impactG = SafetyConstants.crashImpactG,
    this.dynamicImpactG = SafetyConstants.crashDynamicImpactG,
    this.slideImpactG = SafetyConstants.crashSlideImpactG,
    this.rotationRadS = SafetyConstants.crashRotationRadS,
    this.tiltThresholdDeg = SafetyConstants.crashTiltThresholdDeg,
    this.minDurationMs = SafetyConstants.crashMinDurationMs,
    this.stopWithin = SafetyConstants.crashStopWithin,
    this.highSpeedStopWithin = const Duration(seconds: 18),
    this.stopSpeedKmh = SafetyConstants.crashStopSpeedKmh,
    this.stillFor = SafetyConstants.crashStillFor,
    this.stillStdG = SafetyConstants.crashStillStdG,
    this.stillMaxMoveM = SafetyConstants.crashStillMaxMoveM,
    this.resumeKmh = SafetyConstants.crashResumeKmh,
    this.settle = SafetyConstants.crashSettle,
    this.cooldown = SafetyConstants.crashCooldown,
  });

  Duration stopWithinForSpeed(double speedKmh) =>
      speedKmh > 60.0 ? highSpeedStopWithin : stopWithin;
}

/// A likely crash: a hard impact at speed, or a rotational fall/slide, then a stop, and no riding on.
class CrashEvent {
  final int impactAtMs;
  final double impactG;
  final double speedBeforeKmh;
  final double lat;
  final double lng;
  final bool hasRotationOrTilt;
  final bool isSlideFall;
  final CrashScenario scenario;
  final double confidence;
  final double peakJerkGPerS;
  final MovementState movementState;

  const CrashEvent({
    required this.impactAtMs,
    required this.impactG,
    required this.speedBeforeKmh,
    required this.lat,
    required this.lng,
    this.hasRotationOrTilt = false,
    this.isSlideFall = false,
    this.scenario = CrashScenario.unknown,
    this.confidence = 1.0,
    this.peakJerkGPerS = 0.0,
    this.movementState = MovementState.stopped,
  });

  @override
  String toString() =>
      'CrashEvent(at $impactAtMs, ${impactG.toStringAsFixed(1)} g, ${speedBeforeKmh.toStringAsFixed(0)} km/h, rot/tilt: $hasRotationOrTilt, slide: $isSlideFall, scenario: ${scenario.wireName}, conf: ${confidence.toStringAsFixed(2)})';
}

class _Candidate {
  final int impactAt;
  final double impactG;
  final double speedBefore;
  double lat;
  double lng;
  final bool hasRotationOrTilt;
  final bool isSlideFall;
  CrashScenario scenario;
  double confidence;
  double peakJerkGPerS;
  MovementState movementState;

  /// Any fix after the impact (fast or slow).
  bool fixSeen = false;
  int? stopAt;

  /// The stop was read from a GPS fix (else assumed: no fix at all after the impact).
  bool gpsStop = false;
  double? stopLat;
  double? stopLng;
  int stillBuckets = 0;

  _Candidate({
    required this.impactAt,
    required this.impactG,
    required this.speedBefore,
    required this.lat,
    required this.lng,
    this.hasRotationOrTilt = false,
    this.isSlideFall = false,
    this.scenario = CrashScenario.unknown,
    this.confidence = 1.0,
    this.peakJerkGPerS = 0.0,
    this.movementState = MovementState.unknown,
  });
}

/// Pure crash rule (no timers, no platform code). Feed it the rider's fixes and
/// the one-second accelerometer buckets; it returns a [CrashEvent] once when the
/// whole pattern is complete:
///
/// 1. Armed: at least [CrashThresholds.armSpeedKmh] (12 km/h) for [CrashThresholds.armSustain] (10 s),
///    or one fix above [CrashThresholds.instantArmSpeedKmh] (25 km/h); it stays armed until no fix
///    reached [CrashThresholds.lowSpeedArmKmh] for [CrashThresholds.disarmAfter] (3 min parked).
///    Low-speed falls need a fix at [lowSpeedArmKmh] or more in the last 30 s.
/// 2. Impact / Slide:
///    - High impact: dynamic linear shock >= [dynamicImpactG] or raw peak >= [impactG].
///    - Lowside / Slide: dynamic shock >= [slideImpactG] accompanied by rotation >= [rotationRadS] or tilt >= [tiltThresholdDeg].
///    - Low-speed fall: tilt >= [tiltThresholdDeg] with abrupt stop.
///    - Sub-sample noise pulses (< [minDurationMs] without rotation) are rejected.
/// 3. Stop: a fix at 5 km/h or less within 10 s after the impact (extended to 18 s
///    for initial speeds > 60 km/h to account for slides and Doppler smoothing lag).
///    Missing GPS is treated as UNKNOWN, never automatically assumed stopped unless
///    positive motion sensor evidence confirms complete stillness and tumble/impact.
/// 4. No riding on for 20 s after the stop: no fix faster than 15 km/h and none
///    farther than 80 m from the stop. A rider who gets up and walks about still
///    gets the alarm and answers "I'm OK" (product decision r314). Only for an
///    assumed stop (no GPS fix at all) every bucket after a 2 s settle must also be
///    calm (std 0.15 g or less, at least half present), because without GPS a bumpy
///    ride on (a tunnel) and a phone lying on the road look alike otherwise.
///
/// Riding on drops the candidate. After an alarm, [cooldown] blocks new
/// candidates for 2 minutes.
class CrashDetector {
  CrashDetector({
    CrashThresholds thresholds = const CrashThresholds(),
    this.standaloneOfflineMode = false,
  }) : t = thresholds;

  final CrashThresholds t;

  /// When true, operates purely on device accelerometer and gyroscope streams
  /// without requiring prior GPS fixes (ISSUE-6C).
  bool standaloneOfflineMode;

  final List<TrackPoint> _recent = [];
  int? _lastLowSpeedAt;

  /// When the current arming began (null: disarmed).
  int? _armedSince;

  /// Last fix at riding pace ([CrashThresholds.lowSpeedArmKmh] or more): the arming lasts
  /// [CrashThresholds.disarmAfter] after it.
  int? _lastKeepAt;

  /// The current run of fixes at or above [CrashThresholds.armSpeedKmh] (start and last fix).
  int? _runStartAt;
  int? _runLastAt;
  int _now = 0;
  int _cooldownUntil = 0;
  _Candidate? _c;

  /// True while the accelerometer is needed: armed, or an impact is being checked.
  bool get wantsSensor => standaloneOfflineMode || _c != null || armedAt(_now);

  /// True while the detector is armed at [tMs] (sustained riding pace, see the class doc, and
  /// not parked for [CrashThresholds.disarmAfter] since). With [lowSpeed]: a fix at
  /// [CrashThresholds.lowSpeedArmKmh] or more within [CrashThresholds.armWindow] of [tMs].
  /// Always true when [standaloneOfflineMode] is active.
  bool armedAt(int tMs, {bool lowSpeed = false}) {
    if (standaloneOfflineMode) return true;
    final w = t.armWindow.inMilliseconds;
    if (lowSpeed) {
      final low = _lastLowSpeedAt;
      return low != null && tMs - low <= w && tMs - low >= -w;
    }
    final since = _armedSince;
    final keep = _lastKeepAt;
    if (since == null || keep == null) return false;
    return tMs >= since - w && tMs - keep <= t.disarmAfter.inMilliseconds;
  }

  /// Arming with hysteresis: arm after a sustained run at [CrashThresholds.armSpeedKmh] (a dip
  /// into the band just below it, down to [CrashThresholds.lowSpeedArmKmh], does not break the
  /// run; slower, or a GPS gap longer than [CrashThresholds.armWindow], starts it again), or at
  /// once above [CrashThresholds.instantArmSpeedKmh]; disarm after [CrashThresholds.disarmAfter]
  /// without a fix at riding pace.
  void _trackArming(TrackPoint p) {
    final v = p.speedKmh;
    final keep = _lastKeepAt;
    if (_armedSince != null && (keep == null || p.ts - keep > t.disarmAfter.inMilliseconds)) {
      _armedSince = null; // parked long enough: the next ride must arm again
    }
    if (v >= t.lowSpeedArmKmh) _lastKeepAt = math.max(keep ?? p.ts, p.ts);
    if (v >= t.armSpeedKmh) {
      final last = _runLastAt;
      if (_runStartAt == null || last == null || p.ts - last > t.armWindow.inMilliseconds) _runStartAt = p.ts;
      _runLastAt = math.max(last ?? p.ts, p.ts);
    } else if (v < t.lowSpeedArmKmh) {
      _runStartAt = null;
      _runLastAt = null;
    }
    if (_armedSince == null) {
      final run = _runStartAt;
      if (v > t.instantArmSpeedKmh || (run != null && p.ts - run >= t.armSustain.inMilliseconds)) {
        _armedSince = p.ts;
      }
    }
  }

  /// True while an impact is being checked (for tests and diagnostics).
  bool get evaluating => _c != null;

  CrashEvent? onFix(TrackPoint p) {
    _now = math.max(_now, p.ts);

    // Stale or low-accuracy GPS filtering
    final isStale = _now > 0 && (_now - p.ts > 10000);
    final isAccurate = p.accuracyM <= 0 || p.accuracyM <= 65.0;

    if (!isStale && isAccurate) {
      _recent.add(p);
      _recent.removeWhere((f) => f.ts < _now - 40000);
      _trackArming(p);
      // Low-speed falls arm only above walking / jogging pace: a phone dropped while walking
      // (5-8 km/h) must not open the crash alarm. Was stopSpeedKmh (5 km/h), which let a walk arm it.
      if (p.speedKmh >= t.lowSpeedArmKmh) _lastLowSpeedAt = math.max(_lastLowSpeedAt ?? p.ts, p.ts);
    }

    final c = _c;
    // A bucket covers one second from its start (impactAt), so a fix inside that same second
    // may still be from before the impact: only later fixes count as "after the impact".
    if (c == null || p.ts < c.impactAt + 1000) return null;
    c.fixSeen = true;
    final stopAt = c.stopAt;
    final stopWithinMs = t.stopWithinForSpeed(c.speedBefore).inMilliseconds;
    if (stopAt == null) {
      if (p.ts - c.impactAt > stopWithinMs) {
        _c = null; // never came to a stop in time: a pothole or a dropped phone, the ride goes on
        return null;
      }
      if (p.speedKmh <= t.stopSpeedKmh && isAccurate) {
        c.stopAt = p.ts;
        c.gpsStop = true;
        c.stopLat = p.lat;
        c.stopLng = p.lng;
        c.lat = p.lat;
        c.lng = p.lng;
      }
      return null;
    }
    // After the stop only riding on cancels: riding speed, or too far for someone on foot.
    final moved = GeoMath.haversine(c.stopLat ?? p.lat, c.stopLng ?? p.lng, p.lat, p.lng);
    if (p.speedKmh > t.resumeKmh || moved > t.stillMaxMoveM) {
      _c = null;
      return null;
    }
    return _complete(c, p.ts);
  }

  CrashEvent? onAccel(AccelBucket b) {
    _now = math.max(_now, b.tMs);
    final c = _c;
    if (c == null) {
      if (b.tMs < _cooldownUntil) return null;

      final isArmed = armedAt(b.tMs);
      final isLowSpeedArmed = armedAt(b.tMs, lowSpeed: true);
      final hasRotationOrTilt = b.peakGyroRadS >= t.rotationRadS || b.tiltDeg >= t.tiltThresholdDeg;

      // 1. High-side crash (violent angular snap/rebound + high dynamic shock)
      final isHighside = isArmed &&
          (b.peakGyroRadS >= SafetyConstants.crashHighsideRotationRadS || b.tiltDeg >= SafetyConstants.crashHighsideTiltDeg) &&
          (b.effectiveDynG >= 2.5 || b.peakG >= 3.0);

      // 2. High impact collision (gravity compensated dynamic peak or total peak)
      final isHighImpact = isArmed && (b.effectiveDynG >= t.dynamicImpactG || b.peakG >= t.impactG);

      // 3. Lowside / motorcycle slide (moderate dynamic impact + rotation/tilt)
      final isSlideFall = isArmed &&
          (b.effectiveDynG >= t.slideImpactG || b.peakG >= t.slideImpactG) &&
          hasRotationOrTilt;

      // 4. Low-speed intersection fall / tip-over
      final isLowSpeedFall = isLowSpeedArmed &&
          hasRotationOrTilt &&
          (b.effectiveDynG >= 1.5 || b.peakG >= 1.8);

      // False-positive rejection:
      // A. Pothole / Speed breaker: transient shock, but duration <= 35ms, low rotation (< 0.8 rad/s), low tilt (< 15°)
      final isPotholeOrSpeedBump = b.impactDurationMs > 0 &&
          b.impactDurationMs <= SafetyConstants.crashPotholeMaxDurationMs &&
          b.peakGyroRadS <= SafetyConstants.crashPotholeMaxRotationRadS &&
          b.tiltDeg <= SafetyConstants.crashPotholeMaxTiltDeg;

      // B. Hard braking: pure linear deceleration along travel axis without rotation (< 0.5 rad/s) or tilt (< 12°)
      final isHardBraking = b.peakGyroRadS < 0.5 && b.tiltDeg < 12.0 && b.effectiveDynG < 2.5;

      // C. Normal cornering lean: lean angle present, but low dynamic shock (< 1.0g) and low jerk (< 15 g/s)
      final isNormalCornering = b.effectiveDynG < 1.0 && b.peakJerkGPerS < 15.0 && b.tiltDeg <= 45.0 && b.peakGyroRadS < 1.2;

      // Noise rejection: sub-sample spike (< minDurationMs) without rotational evidence is rejected
      final isPebbleNoise = b.impactDurationMs > 0 && b.impactDurationMs < t.minDurationMs && !hasRotationOrTilt;

      if ((isHighside || isHighImpact || isSlideFall || isLowSpeedFall) &&
          !isPotholeOrSpeedBump &&
          !isHardBraking &&
          !isNormalCornering &&
          !isPebbleNoise &&
          !_slowBefore(b.tMs, isLowSpeed: isLowSpeedFall && !isHighImpact && !isHighside)) {
        final last = _recent.isEmpty ? null : _recent.last;

        CrashScenario scenario;
        double confidence;
        if (isHighside) {
          scenario = CrashScenario.highsideFall;
          confidence = 0.95;
        } else if (isHighImpact) {
          scenario = CrashScenario.highImpactCollision;
          confidence = b.peakJerkGPerS >= SafetyConstants.crashPeakJerkGPerS ? 0.95 : 0.88;
        } else if (isSlideFall) {
          scenario = CrashScenario.lowsideSlide;
          confidence = 0.90;
        } else {
          scenario = CrashScenario.stationaryDrop;
          confidence = 0.85;
        }

        _c = _Candidate(
          impactAt: b.tMs,
          impactG: math.max(b.effectiveDynG, b.peakG),
          speedBefore: _speedBefore(b.tMs),
          lat: last?.lat ?? 0,
          lng: last?.lng ?? 0,
          hasRotationOrTilt: hasRotationOrTilt,
          isSlideFall: isSlideFall || isLowSpeedFall || isHighside,
          scenario: scenario,
          confidence: confidence * b.sensorConfidence,
          peakJerkGPerS: b.peakJerkGPerS,
          movementState: MovementState.unknown,
        );
      }
      return null;
    }

    if (b.tMs < c.impactAt) return null;
    var stopAt = c.stopAt;
    final stopWithinMs = t.stopWithinForSpeed(c.speedBefore).inMilliseconds;
    if (stopAt == null) {
      if (b.tMs >= c.impactAt + stopWithinMs) {
        if (c.fixSeen) {
          _c = null; // fixes kept coming but none was slow: still riding
          return null;
        }

        // GPS is missing (UNKNOWN): do not assume stopped if riding motion/vibrations continue
        // or if this was just a bump with no rollover/rotation.
        if (b.stdG > t.stillStdG) {
          _c = null; // motorcycle still moving / vibrating (e.g. tunnel ride on)
          return null;
        }

        // Positive evidence required: either high-impact crash or rotational fall
        if (!c.hasRotationOrTilt && c.impactG < t.impactG) {
          _c = null;
          return null;
        }

        // Confirmed stillness without GPS fixes
        stopAt = c.impactAt + stopWithinMs;
        c.stopAt = stopAt;
      } else {
        return null; // tumbling and sliding are not judged
      }
    }

    // After a GPS stop motion is not judged: a rider who gets up and walks still gets the alarm.
    // After an assumed stop (no fix at all) the phone must lie still, after a 2 s settle (the end
    // of the slide); otherwise riding on with the GPS lost (a tunnel) would look the same.
    if (!c.gpsStop && b.tMs >= stopAt + t.settle.inMilliseconds) {
      if (b.stdG > t.stillStdG) {
        _c = null; // moving: walking about, picked the phone up, riding on
        return null;
      }
      c.stillBuckets++;
    }
    return _complete(c, b.tMs);
  }

  CrashEvent? _complete(_Candidate c, int tMs) {
    final stopAt = c.stopAt;
    if (stopAt == null) return null;
    final need = t.stillFor.inMilliseconds;
    if (tMs - stopAt < need) return null;
    if (!c.gpsStop && c.stillBuckets < (need ~/ 1000) ~/ 2) return null;
    _c = null;
    _cooldownUntil = tMs + t.cooldown.inMilliseconds;
    return CrashEvent(
      impactAtMs: c.impactAt,
      impactG: c.impactG,
      speedBeforeKmh: c.speedBefore,
      lat: c.lat,
      lng: c.lng,
      hasRotationOrTilt: c.hasRotationOrTilt,
      isSlideFall: c.isSlideFall,
      scenario: c.scenario,
      confidence: c.confidence,
      peakJerkGPerS: c.peakJerkGPerS,
      movementState: c.gpsStop ? MovementState.stopped : MovementState.unknown,
    );
  }

  /// True when there were fixes in the 10 s before the impact and none was faster than the
  /// arming speed: the phone was not at riding speed (dropped after arriving at a stop).
  bool _slowBefore(int impactAt, {bool isLowSpeed = false}) {
    final armSpeed = isLowSpeed ? t.stopSpeedKmh : t.armSpeedKmh;
    var any = false;
    for (final f in _recent) {
      if (f.ts > impactAt || impactAt - f.ts > t.stopWithin.inMilliseconds) continue;
      if (f.speedKmh > armSpeed) return false;
      any = true;
    }
    return any;
  }

  /// Highest speed in the 10 s before the impact (the last fast speed when the GPS was sparse).
  double _speedBefore(int impactAt) {
    var best = 0.0;
    for (final f in _recent) {
      if (f.ts <= impactAt && impactAt - f.ts <= t.stopWithin.inMilliseconds) best = math.max(best, f.speedKmh);
    }
    if (best > 0) return best;
    for (final f in _recent.reversed) {
      if (f.ts <= impactAt && f.speedKmh > t.armSpeedKmh) return f.speedKmh;
    }
    return 0;
  }

  /// Forgets everything (a new ride, or crash detection switched off).
  void reset() {
    _recent.clear();
    _lastLowSpeedAt = null;
    _armedSince = null;
    _lastKeepAt = null;
    _runStartAt = null;
    _runLastAt = null;
    _now = 0;
    _cooldownUntil = 0;
    _c = null;
  }

  /// After an alarm (any answer): no new candidate for [CrashThresholds.cooldown].
  void cooldown(int nowMs) {
    _c = null;
    _now = math.max(_now, nowMs);
    _cooldownUntil = math.max(_cooldownUntil, nowMs + t.cooldown.inMilliseconds);
  }
}
