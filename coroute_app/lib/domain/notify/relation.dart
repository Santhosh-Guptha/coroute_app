import '../tracking/bearing.dart';
import '../tracking/geo_math.dart';

/// Where a point is from me, in words riders use. Pure, no state.
///
/// Along the route when both of us are on it ("4.8 km behind your location",
/// "1.6 km ahead on your route"), else as the crow flies with a compass word
/// ("1.8 km north-east of you").
class Relation {
  Relation._();

  /// Both points must be this close to the route to measure along it.
  static const double onRouteM = 300;

  /// Closer than this along the route counts as "here" (ahead by 0).
  static const double _sameSpotM = 30;

  /// Signed distance along [route] from me to the point (positive = ahead), or null
  /// when either is farther than [onRouteM] from the route or the route is too short.
  static double? alongDelta({required double myLat, required double myLng, required double lat, required double lng, List<(double, double)> route = const []}) {
    if (route.length < 2) return null;
    final m = GeoMath.alongRoute(myLat, myLng, route);
    final p = GeoMath.alongRoute(lat, lng, route);
    if (m == null || p == null || m.offRoute > onRouteM || p.offRoute > onRouteM) return null;
    return p.along - m.along;
  }

  static bool _unknown(double lat, double lng) => !lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0);

  /// "4.8 km behind your location", "1.6 km ahead on your route", "1.8 km north-east of you";
  /// '' when either position is unknown.
  static String text({required double myLat, required double myLng, required double lat, required double lng, List<(double, double)> route = const []}) {
    if (_unknown(myLat, myLng) || _unknown(lat, lng)) return '';
    final d = alongDelta(myLat: myLat, myLng: myLng, lat: lat, lng: lng, route: route);
    if (d != null) {
      if (d >= -_sameSpotM) return '${distanceText(d < 0 ? 0 : d)} ahead on your route';
      return '${distanceText(-d)} behind your location';
    }
    final m = GeoMath.haversine(myLat, myLng, lat, lng);
    return '${distanceText(m)} ${Bearing.compassWord(Bearing.degrees(myLat, myLng, lat, lng))} of you';
  }

  /// The same for speech: "4.8 kilometers behind you", "1.6 kilometers ahead", "1.8 kilometers north-east of you".
  static String spoken({required double myLat, required double myLng, required double lat, required double lng, List<(double, double)> route = const []}) {
    if (_unknown(myLat, myLng) || _unknown(lat, lng)) return '';
    final d = alongDelta(myLat: myLat, myLng: myLng, lat: lat, lng: lng, route: route);
    if (d != null) {
      if (d >= -_sameSpotM) return '${spokenDistance(d < 0 ? 0 : d)} ahead';
      return '${spokenDistance(-d)} behind you';
    }
    final m = GeoMath.haversine(myLat, myLng, lat, lng);
    return '${spokenDistance(m)} ${Bearing.compassWord(Bearing.degrees(myLat, myLng, lat, lng))} of you';
  }

  /// Rounded so the text does not change with every fix: 10 m steps below 100 m,
  /// 50 m below 1 km, 0.1 km below 10 km, then whole km ("450 m", "2 km", "4.8 km", "23 km").
  static String distanceText(num metres) {
    final m = metres.isFinite ? metres.abs() : 0;
    if (m < 100) return '${((m / 10).round() * 10).clamp(10, 100)} m';
    if (m < 975) return '${(m / 50).round() * 50} m';
    if (m < 9950) return '${_oneDecimal(m / 1000)} km';
    return '${(m / 1000).round()} km';
  }

  /// "4.8 kilometers", "1 kilometer", "500 meters" (for speech).
  static String spokenDistance(num metres) {
    final m = metres.isFinite ? metres.abs() : 0;
    if (m < 975) {
      final v = m < 100 ? ((m / 10).round() * 10).clamp(10, 100) : (m / 50).round() * 50;
      return '$v meters';
    }
    final km = m < 9950 ? _oneDecimal(m / 1000) : '${(m / 1000).round()}';
    return km == '1' ? '1 kilometer' : '$km kilometers';
  }

  static String _oneDecimal(num v) {
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  /// "Last location update: 8 seconds ago", "Last location update: 2 min ago",
  /// "Last location update: at 10:42" (an hour or more ago, local time).
  static String lastUpdate(int atMs, int nowMs) {
    final age = nowMs - atMs;
    final s = age < 0 ? 0 : age ~/ 1000;
    if (s < 2) return 'Last location update: just now';
    if (s < 60) return 'Last location update: $s seconds ago';
    final min = s ~/ 60;
    if (min < 60) return 'Last location update: $min min ago';
    final t = DateTime.fromMillisecondsSinceEpoch(atMs);
    return 'Last location update: at ${t.hour}:${t.minute.toString().padLeft(2, '0')}';
  }
}
