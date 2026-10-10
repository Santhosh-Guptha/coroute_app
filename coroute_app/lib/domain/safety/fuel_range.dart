import '../../core/constants/safety_constants.dart';
import '../tracking/geo_math.dart';
import '../tracking/track_point.dart';
import 'fuel_profile.dart';

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
  double? baselineKm;
  String? profileStamp;
  bool uncertain = false;

  double? usableKm(FuelProfile p) => p.valid && baselineKm != null && profileStamp == p.toJson().toString()
      ? p.usableKm(baselineKm!, _riddenM) : null;

  /// Explicit rider confirmation only. Partial fills need a known baseline.
  bool refuel(FuelProfile p, int atMs, {bool full = false, double? addedL, double? currentL, double? currentKm}) {
    if (!p.valid || atMs <= 0 || atMs < _lastFillAt) return false;
    double? next;
    if (full) { next = p.rangeKm; }
    else if (currentL != null && p.litresMode && currentL.isFinite && currentL >= 0 && currentL <= p.capacityL) {
      next = currentL * p.mileageKmL;
    } else if (currentKm != null && !p.litresMode && currentKm.isFinite && currentKm >= 0 && currentKm <= p.rangeKm) {
      next = currentKm;
    } else if (addedL != null && p.litresMode && addedL.isFinite && addedL > 0 && addedL <= p.capacityL && usableKm(p) != null && !uncertain) {
      next = ((baselineKm! - _riddenM / 1000).clamp(0, p.rangeKm) + addedL * p.mileageKmL).clamp(0, p.rangeKm).toDouble();
    }
    if (next == null) return false;
    filledUp(atMs);
    baselineKm = next;
    profileStamp = p.toJson().toString();
    uncertain = false;
    _lastLat = null;
    _lastLng = null;
    _lastTs = atMs;
    return true;
  }

  /// Metres ridden since the last fill (or since the tracker started).
  double get riddenM => _riddenM;

  /// When fuel was last explicitly confirmed (epoch ms, 0 = never).
  int get lastFillAt => _lastFillAt;

  /// The reminder was already given for this fill.
  bool get warned => _warned;

  /// Adds the distance from the previous fix. A jump over
  /// [SafetyConstants.fuelMaxJumpM] or a gap over [SafetyConstants.fuelMaxGap]
  /// is skipped (GPS teleports, a restart): the new fix only becomes the new start.
  void onFix(TrackPoint p) {
    if (!p.lat.isFinite || !p.lng.isFinite || p.lat.abs() > 90 || p.lng.abs() > 180 || !p.accuracyM.isFinite || p.accuracyM > 100) { uncertain = true; return; }
    if (p.ts < _lastTs || (p.ts == _lastTs && _lastLat != null)) return;
    final lat = _lastLat, lng = _lastLng;
    if (lat != null && lng != null && _lastTs > 0 && p.ts >= _lastTs) {
      final dt = p.ts - _lastTs;
      final d = GeoMath.haversine(lat, lng, p.lat, p.lng);
      if (dt <= SafetyConstants.fuelMaxGap.inMilliseconds && d <= SafetyConstants.fuelMaxJumpM) { _riddenM += d; } else { uncertain = true; }
    }
    _lastLat = p.lat;
    _lastLng = p.lng;
    _lastTs = p.ts;
  }

  /// The tank was filled at [atMs]: the count starts again.
  void filledUp(int atMs) {
    _riddenM = 0;
    baselineKm = null;
    profileStamp = null;
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
    baselineKm = null;
    profileStamp = null;
    uncertain = false;
    _riddenM = 0;
    _lastLat = null;
    _lastLng = null;
    _lastTs = 0;
    _lastFillAt = 0;
    _warned = false;
  }

  Map<String, Object?> toJson() => {
        'm': _riddenM.round(),
        'baselineKm': baselineKm,
        'profileStamp': profileStamp,
        'uncertain': uncertain,
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
    if (!t._riddenM.isFinite) return null;
    final baseline = j['baselineKm'];
    t.baselineKm = baseline is num && baseline.isFinite && baseline >= 0 ? baseline.toDouble() : null;
    t.profileStamp = j['profileStamp'] is String ? j['profileStamp'] as String : null;
    t.uncertain = j['uncertain'] == true;
    for (final key in ['lat', 'lng', 'ts', 'fill']) {
      if (j[key] != null && (j[key] is! num || !(j[key] as num).isFinite)) return null;
    }
    t._lastLat = (j['lat'] as num?)?.toDouble();
    t._lastLng = (j['lng'] as num?)?.toDouble();
    t._lastTs = (j['ts'] as num?)?.toInt() ?? 0;
    t._lastFillAt = (j['fill'] as num?)?.toInt() ?? 0;
    if ((t._lastLat?.abs() ?? 0) > 90 || (t._lastLng?.abs() ?? 0) > 180 || t._lastTs < 0 || t._lastFillAt < 0) return null;
    t._warned = j['w'] == true;
    if (t._riddenM < 0) t._riddenM = 0;
    return t;
  }
}
