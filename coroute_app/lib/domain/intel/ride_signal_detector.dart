import '../../core/constants/safety_constants.dart';
import '../safety/accel_bucket.dart';
import '../safety/mount_classifier.dart';
import '../safety/road_surface_detector.dart';
import '../tracking/track_point.dart';
import 'intel_event.dart';

/// Swerve / skid signals from the 1 s accelerometer buckets the crash detector already gets (pure, conservative).
///  * SWERVE: a sharp rotation (≥ [swerveRadS]) at ≥ [swerveMinKmh] without a crash-level impact and without
///    the bike leaning over (a planned corner shows steady lean, a swerve a short snap).
///  * SKID: a rotation snap (≥ [skidRadS]) with a tilt spike (≥ [skidTiltDeg]) and a speed drop of
///    ≥ [skidDropKmh] within [skidWindow], below the crash impact level (the crash detector owns crashes).
/// At most one signal per [dedupe]. Never while the crash detector weighs an impact or an alarm is open (the
/// caller passes [busy]). A phone in a pocket or loose is skipped (too noisy to tell a swerve from a step).
class RideSignalDetector {
  static const double swerveRadS = 2.6;
  static const double swerveMinKmh = 30;
  static const double swerveMaxTiltDeg = 25;
  static const double skidRadS = 2.0;
  static const double skidTiltDeg = 30;
  static const double skidDropKmh = 12;
  static const Duration skidWindow = Duration(seconds: 4);
  static const Duration dedupe = Duration(seconds: 20);

  final List<TrackPoint> _fixes = [];
  int _lastAt = -1 << 40;
  ({int tMs, double speed})? _skidCandidate;

  void reset() {
    _fixes.clear();
    _lastAt = -1 << 40;
    _skidCandidate = null;
  }

  void onFix(TrackPoint p) {
    _fixes.add(p);
    while (_fixes.isNotEmpty && p.ts - _fixes.first.ts > 10000) {
      _fixes.removeAt(0);
    }
  }

  double? _speedAt(int t) {
    TrackPoint? best;
    for (final f in _fixes) {
      if ((f.ts - t).abs() <= 3000 && (best == null || (f.ts - t).abs() < (best.ts - t).abs())) best = f;
    }
    return best?.speedKmh;
  }

  /// Returns a signal type (swerve or skid) for this second, or null.
  IntelEventType? onBucket(AccelBucket b, {required bool busy, MountKind mount = MountKind.unknown}) {
    if (busy || mount.weak || b.sensorConfidence < 0.5) return null;
    if (b.peakG >= SafetyConstants.crashImpactG) return null; // crash level: not ours
    final cand = _skidCandidate;
    if (cand != null) {
      if (b.tMs - cand.tMs > skidWindow.inMilliseconds) {
        _skidCandidate = null;
      } else {
        final v = _speedAt(b.tMs);
        if (v != null && cand.speed - v >= skidDropKmh) {
          _skidCandidate = null;
          return _emit(b.tMs, IntelEventType.skid);
        }
      }
    }
    if (b.tMs - _lastAt < dedupe.inMilliseconds) return null;
    final v = _speedAt(b.tMs);
    if (v == null) return null;
    if (b.peakGyroRadS >= skidRadS && b.tiltDeg >= skidTiltDeg && v >= 15) {
      _skidCandidate = (tMs: b.tMs, speed: v);
      return null;
    }
    if (b.peakGyroRadS >= swerveRadS && v >= swerveMinKmh && b.tiltDeg < swerveMaxTiltDeg) return _emit(b.tMs, IntelEventType.swerve);
    return null;
  }

  IntelEventType _emit(int t, IntelEventType type) {
    _lastAt = t;
    return type;
  }
}

/// Feature 7: which road surface events become shared road quality signals (mount aware, pure).
///  * only potholes and rough road (a speed breaker is a planned bump, not a defect);
///  * only above [minKmh] (20 km/h);
///  * a phone in a pocket or loose: skipped (its own body movement looks like road shocks);
///  * an unknown mount: kept with low confidence (0.5); a handlebar mount: the detector's confidence.
class PotholeIntelGate {
  static const double minKmh = 20;

  static IntelEvent? eventOf(RoadSurfaceEvent e, {required MountKind mount, double? headingDeg}) {
    if (e.kind == RoadSurfaceKind.speedBreaker) return null;
    if (e.speedKmh <= minKmh) return null;
    if (mount.weak) return null;
    final conf = mount == MountKind.mounted ? e.confidence : (e.confidence * 0.5).clamp(0.1, 0.5).toDouble();
    return IntelEvent.at(
      type: e.kind == RoadSurfaceKind.pothole ? IntelEventType.pothole : IntelEventType.rough,
      lat: e.lat,
      lng: e.lng,
      headingDeg: headingDeg,
      speedKmh: e.speedKmh,
      ts: e.tMs,
      conf: conf,
    );
  }
}
