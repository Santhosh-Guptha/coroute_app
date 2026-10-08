import 'dart:math' as math;
import '../../core/constants/safety_constants.dart';
import '../tracking/geo_math.dart';
import '../tracking/track_point.dart';
import 'accel_bucket.dart';

/// Thresholds of the crash rule. Defaults come from [SafetyConstants].
class CrashThresholds {
  final double armSpeedKmh;
  final Duration armWindow;
  final double impactG;
  final Duration stopWithin;
  final double stopSpeedKmh;
  final Duration stillFor;
  final double stillStdG;
  final double stillMaxMoveM;
  final double resumeKmh;
  final Duration settle;
  final Duration cooldown;

  const CrashThresholds({
    this.armSpeedKmh = SafetyConstants.crashArmSpeedKmh,
    this.armWindow = SafetyConstants.crashArmWindow,
    this.impactG = SafetyConstants.crashImpactG,
    this.stopWithin = SafetyConstants.crashStopWithin,
    this.stopSpeedKmh = SafetyConstants.crashStopSpeedKmh,
    this.stillFor = SafetyConstants.crashStillFor,
    this.stillStdG = SafetyConstants.crashStillStdG,
    this.stillMaxMoveM = SafetyConstants.crashStillMaxMoveM,
    this.resumeKmh = SafetyConstants.crashResumeKmh,
    this.settle = SafetyConstants.crashSettle,
    this.cooldown = SafetyConstants.crashCooldown,
  });
}

/// A likely crash: a hard impact at speed, then a stop, and no riding on.
class CrashEvent {
  final int impactAtMs;
  final double impactG;
  final double speedBeforeKmh;
  final double lat;
  final double lng;

  const CrashEvent({required this.impactAtMs, required this.impactG, required this.speedBeforeKmh, required this.lat, required this.lng});

  @override
  String toString() => 'CrashEvent(at $impactAtMs, ${impactG.toStringAsFixed(1)} g, ${speedBeforeKmh.toStringAsFixed(0)} km/h)';
}

class _Candidate {
  final int impactAt;
  final double impactG;
  final double speedBefore;
  double lat;
  double lng;

  /// Any fix after the impact (fast or slow).
  bool fixSeen = false;
  int? stopAt;

  /// The stop was read from a GPS fix (else assumed: no fix at all after the impact).
  bool gpsStop = false;
  double? stopLat;
  double? stopLng;
  int stillBuckets = 0;

  _Candidate({required this.impactAt, required this.impactG, required this.speedBefore, required this.lat, required this.lng});
}

/// Pure crash rule (no timers, no platform code). Feed it the rider's fixes and
/// the one-second accelerometer buckets; it returns a [CrashEvent] once when the
/// whole pattern is complete:
///
/// 1. Armed: a fix faster than 25 km/h in the last 30 s.
/// 2. Impact: a bucket with a peak of 4 g or more while armed.
/// 3. Stop: a fix at 5 km/h or less within 10 s after the impact. With the GPS
///    distance filter a phone that does not move gets no fixes at all, so when
///    NO fix arrives in those 10 s the stop is taken to be at impact + 10 s.
///    The impact must also be at speed: when there were fixes in the 10 s before it,
///    at least one was faster than 25 km/h (a phone dropped at a fuel stop is not).
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
  CrashDetector({CrashThresholds thresholds = const CrashThresholds()}) : t = thresholds;

  final CrashThresholds t;

  final List<TrackPoint> _recent = [];
  int? _lastFastAt;
  int _now = 0;
  int _cooldownUntil = 0;
  _Candidate? _c;

  /// True while the accelerometer is needed: armed, or an impact is being checked.
  bool get wantsSensor => _c != null || armedAt(_now);

  /// True when a fix faster than the arming speed was seen in the window before [tMs].
  bool armedAt(int tMs) {
    final fast = _lastFastAt;
    return fast != null && tMs - fast <= t.armWindow.inMilliseconds && tMs - fast >= -t.armWindow.inMilliseconds;
  }

  /// True while an impact is being checked (for tests and diagnostics).
  bool get evaluating => _c != null;

  CrashEvent? onFix(TrackPoint p) {
    _now = math.max(_now, p.ts);
    _recent.add(p);
    _recent.removeWhere((f) => f.ts < _now - 40000);
    if (p.speedKmh > t.armSpeedKmh) _lastFastAt = math.max(_lastFastAt ?? p.ts, p.ts);

    final c = _c;
    // A bucket covers one second from its start (impactAt), so a fix inside that same second
    // may still be from before the impact: only later fixes count as "after the impact".
    if (c == null || p.ts < c.impactAt + 1000) return null;
    c.fixSeen = true;
    final stopAt = c.stopAt;
    if (stopAt == null) {
      if (p.ts - c.impactAt > t.stopWithin.inMilliseconds) {
        _c = null; // never came to a stop in time: a pothole or a dropped phone, the ride goes on
        return null;
      }
      if (p.speedKmh <= t.stopSpeedKmh) {
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
      if (b.peakG >= t.impactG && armedAt(b.tMs) && b.tMs >= _cooldownUntil && !_slowBefore(b.tMs)) {
        final last = _recent.isEmpty ? null : _recent.last;
        _c = _Candidate(
          impactAt: b.tMs,
          impactG: b.peakG,
          speedBefore: _speedBefore(b.tMs),
          lat: last?.lat ?? 0,
          lng: last?.lng ?? 0,
        );
      }
      return null;
    }
    if (b.tMs < c.impactAt) return null;
    var stopAt = c.stopAt;
    if (stopAt == null) {
      if (b.tMs >= c.impactAt + t.stopWithin.inMilliseconds) {
        if (c.fixSeen) {
          _c = null; // fixes kept coming but none was slow: still riding
          return null;
        }
        // No fix at all since the impact: the phone has not moved 8 m (GPS distance filter).
        stopAt = c.impactAt + t.stopWithin.inMilliseconds;
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
    return CrashEvent(impactAtMs: c.impactAt, impactG: c.impactG, speedBeforeKmh: c.speedBefore, lat: c.lat, lng: c.lng);
  }

  /// True when there were fixes in the 10 s before the impact and none was faster than the
  /// arming speed: the phone was not at riding speed (dropped after arriving at a stop).
  bool _slowBefore(int impactAt) {
    var any = false;
    for (final f in _recent) {
      if (f.ts > impactAt || impactAt - f.ts > t.stopWithin.inMilliseconds) continue;
      if (f.speedKmh > t.armSpeedKmh) return false;
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
    _lastFastAt = null;
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
