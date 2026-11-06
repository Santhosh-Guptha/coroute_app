import 'geo_math.dart';
import 'track_point.dart';

/// Decides which GPS fixes are worth recording.
///
/// Drops fixes that are inaccurate, out of order, physically impossible, or
/// pure drift while the rider is standing still (that last rule keeps the
/// recording small without losing anything: a parked rider is represented by
/// at most one fix per [stationaryKeepEvery]).
class TrackFilter {
  TrackFilter({
    this.maxAccuracyM = 30,
    this.maxKmh = 250,
    this.minMoveM = 3,
    this.stationaryKeepEvery = const Duration(seconds: 25),
    this.reanchorAfter = 3,
  });

  final double maxAccuracyM;
  final double maxKmh;
  final double minMoveM;
  final Duration stationaryKeepEvery;

  /// After this many fixes in a row that all "teleport" away from the last
  /// kept fix but agree with each other, the last kept fix was the bad one
  /// (a wrong cold-start fix): recording continues from the new position
  /// instead of dropping the rest of the ride.
  final int reanchorAfter;

  TrackPoint? _last;
  TrackPoint? get last => _last;
  final List<TrackPoint> _jumped = [];

  void reset() {
    _last = null;
    _jumped.clear();
  }

  bool _teleport(TrackPoint a, TrackPoint b) {
    final dtMs = b.ts - a.ts;
    final d = GeoMath.haversine(a.lat, a.lng, b.lat, b.lng);
    if (d <= 200) return false;
    return dtMs <= 0 || d / (dtMs / 1000) * 3.6 > maxKmh;
  }

  /// Returns true when [p] should be recorded (and remembers it).
  bool accept(TrackPoint p) {
    if (p.accuracyM > maxAccuracyM) return false;
    if (!(p.lat.abs() <= 90 && p.lng.abs() <= 180) || (p.lat == 0 && p.lng == 0)) return false;
    final last = _last;
    if (last != null) {
      final dtMs = p.ts - last.ts;
      if (dtMs <= 0) return false;
      final d = GeoMath.haversine(last.lat, last.lng, p.lat, p.lng);
      final kmh = d / (dtMs / 1000) * 3.6;
      if (kmh > maxKmh && d > 200) {
        // Teleport, unless the following fixes keep agreeing with this one.
        if (_jumped.isNotEmpty && _teleport(_jumped.last, p)) _jumped.clear();
        _jumped.add(p);
        if (_jumped.length < reanchorAfter) return false;
        _jumped.clear();
        _last = p;
        return true;
      }
      _jumped.clear();
      if (d < minMoveM && p.speedKmh < 3 && dtMs < stationaryKeepEvery.inMilliseconds) return false; // drift
    }
    _last = p;
    return true;
  }
}
