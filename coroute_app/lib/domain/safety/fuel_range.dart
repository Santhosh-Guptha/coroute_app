import '../../core/constants/safety_constants.dart';
import '../tracking/geo_math.dart';
import '../tracking/track_point.dart';

/// Distance ridden since the last fuel fill, from the fixes the ride already
/// records (no extra GPS work). Warns once per fill when
/// [warnAtFraction] of the tank range was ridden. Pure: no timers, no I/O;
/// [toJson] / [fromJson] let the service keep it across an app restart.
class FuelRangeTracker {
  FuelRangeTracker({this.warnAtFraction = SafetyConstants.fuelWarnFraction});

  final double warnAtFraction;

  double _riddenM = 0;
  double? _lastLat;
  double? _lastLng;
  int _lastTs = 0;
  int _lastFillAt = 0;
  bool _warned = false;

  /// Metres ridden since the last fill (or since the tracker started).
  double get riddenM => _riddenM;

  /// When "Filled up" was last pressed or a fuel stop was reached (epoch ms, 0 = never).
  int get lastFillAt => _lastFillAt;

  /// The reminder was already given for this fill.
  bool get warned => _warned;

  /// Adds the distance from the previous fix. A jump over
  /// [SafetyConstants.fuelMaxJumpM] or a gap over [SafetyConstants.fuelMaxGap]
  /// is skipped (GPS teleports, a restart): the new fix only becomes the new start.
  void onFix(TrackPoint p) {
    final lat = _lastLat, lng = _lastLng;
    if (lat != null && lng != null && _lastTs > 0 && p.ts >= _lastTs) {
      final dt = p.ts - _lastTs;
      final d = GeoMath.haversine(lat, lng, p.lat, p.lng);
      if (dt <= SafetyConstants.fuelMaxGap.inMilliseconds && d <= SafetyConstants.fuelMaxJumpM) _riddenM += d;
    }
    _lastLat = p.lat;
    _lastLng = p.lng;
    _lastTs = p.ts;
  }

  /// The tank was filled at [atMs]: the count starts again.
  void filledUp(int atMs) {
    _riddenM = 0;
    _warned = false;
    if (atMs > _lastFillAt) _lastFillAt = atMs;
  }

  /// True exactly once per fill, as soon as [warnAtFraction] of [rangeKm] was ridden.
  /// [rangeKm] 0 (or less) means the reminder is off.
  bool shouldWarn(int rangeKm) {
    if (rangeKm <= 0 || _warned) return false;
    if (_riddenM < warnAtFraction * rangeKm * 1000) return false;
    _warned = true;
    return true;
  }

  void reset() {
    _riddenM = 0;
    _lastLat = null;
    _lastLng = null;
    _lastTs = 0;
    _lastFillAt = 0;
    _warned = false;
  }

  Map<String, Object?> toJson() => {
        'm': _riddenM.round(),
        'lat': _lastLat,
        'lng': _lastLng,
        'ts': _lastTs,
        'fill': _lastFillAt,
        'w': _warned,
      };

  /// Null for anything that is not a saved tracker.
  static FuelRangeTracker? fromJson(Map? j, {double warnAtFraction = SafetyConstants.fuelWarnFraction}) {
    if (j == null || j['m'] is! num) return null;
    final t = FuelRangeTracker(warnAtFraction: warnAtFraction);
    t._riddenM = (j['m'] as num).toDouble();
    t._lastLat = (j['lat'] as num?)?.toDouble();
    t._lastLng = (j['lng'] as num?)?.toDouble();
    t._lastTs = (j['ts'] as num?)?.toInt() ?? 0;
    t._lastFillAt = (j['fill'] as num?)?.toInt() ?? 0;
    t._warned = j['w'] == true;
    if (t._riddenM < 0) t._riddenM = 0;
    return t;
  }
}
