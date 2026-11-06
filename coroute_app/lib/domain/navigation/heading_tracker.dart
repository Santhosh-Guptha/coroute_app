import '../tracking/geo_math.dart';
import 'reroute_rules.dart';

/// My direction of travel from the fixes: the GPS heading when moving fast
/// enough for it to mean something, else the bearing of my last
/// [minMoveM] metres of movement (so jitter while slow gives no direction).
class HeadingTracker {
  /// Movement (metres) needed before a new direction is taken from positions.
  static const double minMoveM = 15;

  /// The GPS heading is used from this speed (km/h).
  static const double gpsFromKmh = 10;

  (double, double)? _from;
  double? _heading;

  /// The last direction from movement, if any.
  double? get heading => _heading;

  /// One fix; returns my direction (degrees, 0 = north) or null.
  double? update(double lat, double lng, {double? gpsHeadingDeg, double speedKmh = 0}) {
    final from = _from;
    if (from == null) {
      _from = (lat, lng);
    } else if (GeoMath.haversine(from.$1, from.$2, lat, lng) >= minMoveM) {
      _heading = RerouteRules.bearing(from.$1, from.$2, lat, lng);
      _from = (lat, lng);
    }
    final g = gpsHeadingDeg;
    if (g != null && g.isFinite && g >= 0 && speedKmh.isFinite && speedKmh >= gpsFromKmh) return g % 360;
    return _heading;
  }

  void reset() {
    _from = null;
    _heading = null;
  }
}
