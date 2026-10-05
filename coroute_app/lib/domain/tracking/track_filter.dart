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
  });

  final double maxAccuracyM;
  final double maxKmh;
  final double minMoveM;
  final Duration stationaryKeepEvery;

  TrackPoint? _last;
  TrackPoint? get last => _last;

  void reset() => _last = null;

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
      if (kmh > maxKmh && d > 200) return false; // teleport
      if (d < minMoveM && p.speedKmh < 3 && dtMs < stationaryKeepEvery.inMilliseconds) return false; // drift
    }
    _last = p;
    return true;
  }
}
