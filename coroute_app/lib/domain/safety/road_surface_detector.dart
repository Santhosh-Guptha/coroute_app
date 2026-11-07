// Road surface events from the phone's motion sensor (3.55): potholes, speed breakers and rough
// stretches felt by the rider at the front, so the riders behind are warned in time and the spot is
// saved for future rides.
//
// Input: the 1-second accelerometer buckets the crash detector already receives (no new sensor work)
// plus the latest GPS speed and position. Output: at most one event per [minSpacingM] and per
// [minGap]. Pure Dart, no Flutter, no I/O.
//
// Rules (conservative, so the group is not warned about every joint in the road):
//  * moving at [minSpeedKmh] or more, with a usable sensor (confidence >= 0.5);
//  * a crash-like second (very high impact, long impact, big tilt) is never a road event: the crash
//    detector owns it;
//  * POTHOLE: a sharp dynamic peak (>= [potholeDynG]) with little rotation, at a steady speed (the
//    rider did not slow for it: an unexpected hole);
//  * SPEED_BREAKER: a moderate peak after the rider slowed by [breakerSlowdown] or more in the last
//    seconds (riders slow for a breaker they see; the ones behind need the same warning);
//  * ROUGH_ROAD: [roughSeconds] of the last [roughWindow] seconds shaking (stdG >= [roughStdG]) at
//    speed: broken surface, gravel, a stretch under repair.
import 'dart:collection';

import '../../core/constants/safety_constants.dart';
import '../tracking/geo_math.dart';
import 'accel_bucket.dart';

enum RoadSurfaceKind {
  pothole,
  speedBreaker,
  roughRoad;

  /// The FEAT-02 wire classification (`ROUGH_ROAD` is new in 3.55; older apps read it as an
  /// uncertain surface anomaly).
  String get wire => switch (this) {
        pothole => 'POTHOLE',
        speedBreaker => 'SPEED_BREAKER',
        roughRoad => 'ROUGH_ROAD',
      };

  /// "Pothole", "Speed breaker", "Rough road".
  String get label => switch (this) {
        pothole => 'Pothole',
        speedBreaker => 'Speed breaker',
        roughRoad => 'Rough road',
      };

  static RoadSurfaceKind? fromWire(String? s) => switch ((s ?? '').toUpperCase()) {
        'POTHOLE' || 'SEVERE_RIDGE' => pothole,
        'SPEED_BREAKER' => speedBreaker,
        'ROUGH_ROAD' => roughRoad,
        _ => null,
      };
}

/// One detected road surface event.
class RoadSurfaceEvent {
  final RoadSurfaceKind kind;

  /// 'LOW', 'MEDIUM', 'HIGH' or 'CRITICAL' (the FEAT-02 wire severities).
  final String severity;
  final double lat;
  final double lng;
  final double speedKmh;
  final double peakDynG;
  final double peakGyroDegS;
  final double confidence;
  final int tMs;

  const RoadSurfaceEvent({
    required this.kind,
    required this.severity,
    required this.lat,
    required this.lng,
    required this.speedKmh,
    required this.peakDynG,
    required this.peakGyroDegS,
    required this.confidence,
    required this.tMs,
  });
}

class RoadSurfaceDetector {
  RoadSurfaceDetector();

  static const double minSpeedKmh = 15;
  static const double potholeDynG = 1.1;
  static const double potholeSevereDynG = 1.8;
  static const double breakerMinDynG = 0.6;
  static const double breakerSlowdown = 0.25;
  static const double maxGyroDegSForPothole = 120;
  static const double roughStdG = 0.35;
  static const int roughWindow = 10;
  static const int roughSeconds = 6;
  static const double minSpacingM = 150;
  static const Duration minGap = Duration(seconds: 20);

  // Crash-like seconds belong to the crash detector.
  static const double crashPeakG = 3.5;
  static const double crashImpactMs = 120;
  static const double crashTiltDeg = 50;

  final Queue<({int tMs, double speed})> _speeds = Queue();
  final Queue<bool> _shaky = Queue();
  int _lastEventMs = 0;
  (double, double)? _lastEventAt;

  /// True for a second the crash detector may treat as a crash (3.55 safety review): the fixed
  /// limits above, plus the crash detector's own slide / fall rule (a jolt with the rotation or tilt
  /// of a fall) and its high-impact limits. Before, a lowside slide (2-3 g with 1.8-2 rad/s of
  /// rotation, under 45 degrees of tilt) passed as a "pothole": the riders behind were warned of a
  /// pothole where a rider had just gone down, and the spot was saved for later rides.
  static bool isCrashLike(AccelBucket b) {
    if (b.peakG >= crashPeakG || b.impactDurationMs >= crashImpactMs || b.tiltDeg >= crashTiltDeg) return true;
    if (b.effectiveDynG >= SafetyConstants.crashDynamicImpactG || b.peakG >= SafetyConstants.crashImpactG) return true;
    final rotationOrTilt = b.peakGyroRadS >= SafetyConstants.crashRotationRadS || b.tiltDeg >= SafetyConstants.crashTiltThresholdDeg;
    // The crash detector's low-speed fall threshold (1.5 g dynamic / 1.8 g raw) is the lowest of its rules.
    return rotationOrTilt && (b.effectiveDynG >= 1.5 || b.peakG >= 1.8);
  }

  void reset() {
    _speeds.clear();
    _shaky.clear();
    _lastEventMs = 0;
    _lastEventAt = null;
  }

  /// One bucket with the latest GPS fix (speed km/h, position). Null when nothing to report.
  RoadSurfaceEvent? onBucket(AccelBucket b, {required double speedKmh, required double lat, required double lng}) {
    _speeds.addLast((tMs: b.tMs, speed: speedKmh));
    while (_speeds.isNotEmpty && b.tMs - _speeds.first.tMs > 6000) {
      _speeds.removeFirst();
    }
    final moving = speedKmh >= minSpeedKmh && b.sensorConfidence >= 0.5 && (lat != 0 || lng != 0);
    _shaky.addLast(moving && b.stdG >= roughStdG);
    while (_shaky.length > roughWindow) {
      _shaky.removeFirst();
    }
    if (!moving) return null;
    if (isCrashLike(b)) return null;
    if (b.tMs - _lastEventMs < minGap.inMilliseconds && _lastEventMs > 0) return null;
    final last = _lastEventAt;
    if (last != null && GeoMath.haversine(last.$1, last.$2, lat, lng) < minSpacingM) return null;

    final gyroDegS = b.peakGyroRadS * 57.29578;
    double maxRecent = speedKmh;
    for (final s in _speeds) {
      if (s.speed > maxRecent) maxRecent = s.speed;
    }
    final slowed = maxRecent > 0 && (maxRecent - speedKmh) / maxRecent >= breakerSlowdown;

    RoadSurfaceEvent make(RoadSurfaceKind kind, String severity, double confidence) {
      _lastEventMs = b.tMs;
      _lastEventAt = (lat, lng);
      _shaky.clear();
      return RoadSurfaceEvent(
        kind: kind,
        severity: severity,
        lat: lat,
        lng: lng,
        speedKmh: speedKmh,
        peakDynG: b.peakDynG,
        peakGyroDegS: gyroDegS,
        confidence: (confidence * b.sensorConfidence).clamp(0.1, 1.0).toDouble(),
        tMs: b.tMs,
      );
    }

    if (b.peakDynG >= potholeDynG && !slowed && gyroDegS <= maxGyroDegSForPothole) {
      final severe = b.peakDynG >= potholeSevereDynG || speedKmh >= 60;
      return make(RoadSurfaceKind.pothole, severe ? 'HIGH' : 'MEDIUM', severe ? 0.85 : 0.7);
    }
    if (slowed && b.peakDynG >= breakerMinDynG && b.peakDynG < potholeSevereDynG * 1.5) {
      return make(RoadSurfaceKind.speedBreaker, 'MEDIUM', 0.75);
    }
    if (_shaky.where((x) => x).length >= roughSeconds) {
      return make(RoadSurfaceKind.roughRoad, speedKmh >= 50 ? 'MEDIUM' : 'LOW', 0.65);
    }
    return null;
  }
}

/// What the riders behind hear and read for a road event `distanceM` ahead (rounded to 50 m).
class RoadSurfaceText {
  RoadSurfaceText._();

  static String _dist(double m) {
    if (m >= 1000) return '${(m / 1000).toStringAsFixed(1)} kilometres';
    final r = ((m / 50).round() * 50).clamp(50, 950);
    return '$r metres';
  }

  static String spoken(RoadSurfaceKind? kind, double distanceM, {bool fromHistory = false}) {
    final what = switch (kind) {
      RoadSurfaceKind.pothole => 'Pothole',
      RoadSurfaceKind.speedBreaker => 'Speed breaker',
      RoadSurfaceKind.roughRoad => 'Rough road',
      null => 'Road hazard',
    };
    final source = fromHistory ? ', reported by CoRoute riders' : '';
    return 'Caution. $what ahead in ${_dist(distanceM)}$source. Slow down.';
  }

  static String title(RoadSurfaceKind? kind, double distanceM) {
    final what = kind?.label ?? 'Road hazard';
    final d = distanceM >= 1000 ? '${(distanceM / 1000).toStringAsFixed(1)} km' : '${((distanceM / 50).round() * 50).clamp(50, 950)} m';
    return '$what ahead · $d';
  }
}
