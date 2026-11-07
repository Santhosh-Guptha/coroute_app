import '../places/place_poi.dart';
import '../places/poi_category.dart';
import '../tracking/geo_math.dart';

/// A safe stop ahead where a spread group can gather.
class RegroupSuggestion {
  final String placeId;
  final String name;
  final double lat;
  final double lng;
  final PoiCategory category;

  /// Along the route from its start (m).
  final double alongM;

  /// How far ahead of the lead (m; 0 when the lead is already past the window start).
  final double aheadOfLeadM;

  const RegroupSuggestion({
    required this.placeId,
    required this.name,
    required this.lat,
    required this.lng,
    required this.category,
    required this.alongM,
    required this.aheadOfLeadM,
  });

  /// "Regroup at Indian Oil, 4.2 km ahead".
  String get text => 'Regroup at $name, ${_km(aheadOfLeadM)} ahead';

  static String _km(double m) {
    if (m < 1000) return '${(m / 50).round() * 50} m';
    final s = (m / 1000).toStringAsFixed(1);
    return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s} km';
  }
}

/// 3.55 smart regroup point (pure): picks from the places the phone already cached along the
/// route (map places corridor). Rules:
///  * category fuel, food or a rest place (stay, toilet);
///  * within [maxOffRouteM] of the route;
///  * between [minAheadM] and [maxAheadM] ahead of the LAST rider (so everyone can reach it), and
///    not behind the lead (the front rider never turns back);
///  * fuel before food before rest places, then nearest to the middle of that window.
class RegroupPointPicker {
  RegroupPointPicker._();

  static const double maxOffRouteM = 300;
  static const double minAheadM = 2000;
  static const double maxAheadM = 10000;

  /// Lower is better.
  static int? rankOf(PoiCategory c) => switch (c) {
        PoiCategory.fuel => 0,
        PoiCategory.food => 1,
        PoiCategory.stay || PoiCategory.toilet => 2,
        _ => null,
      };

  static RegroupSuggestion? pick({
    required List<(double, double)> route,
    required Iterable<PlacePoi> places,
    required double lastAlongM,
    required double leadAlongM,
  }) {
    if (route.length < 2) return null;
    final from = (lastAlongM + minAheadM) > leadAlongM ? lastAlongM + minAheadM : leadAlongM;
    final to = lastAlongM + maxAheadM;
    if (to <= from) return null; // spread wider than the window: no stop all can reach ahead of the lead
    final mid = (from + to) / 2;
    // Cheap prefilter: a place inside the window is within (half window + side) of the window's
    // middle point as the crow flies (straight lines are never longer than the road).
    final midPt = _pointAt(route, mid);
    final radius = (to - from) / 2 + maxOffRouteM + 200;
    RegroupSuggestion? best;
    int? bestRank;
    double bestDist = double.infinity;
    for (final p in places) {
      final rank = rankOf(p.category);
      if (rank == null) continue;
      if (midPt != null && GeoMath.haversine(midPt.$1, midPt.$2, p.lat, p.lng) > radius) continue;
      final a = GeoMath.alongRoute(p.lat, p.lng, route);
      if (a == null || a.offRoute > maxOffRouteM || a.along < from || a.along > to) continue;
      final dist = (a.along - mid).abs();
      if (bestRank == null || rank < bestRank || (rank == bestRank && dist < bestDist)) {
        bestRank = rank;
        bestDist = dist;
        best = RegroupSuggestion(
          placeId: p.id,
          name: p.displayName,
          lat: p.lat,
          lng: p.lng,
          category: p.category,
          alongM: a.along,
          aheadOfLeadM: a.along - leadAlongM < 0 ? 0 : a.along - leadAlongM,
        );
      }
    }
    return best;
  }

  /// The point [m] metres along [line] (null for an empty line).
  static (double, double)? _pointAt(List<(double, double)> line, double m) {
    if (line.isEmpty) return null;
    var acc = 0.0;
    for (var i = 0; i < line.length - 1; i++) {
      final (aLat, aLng) = line[i];
      final (bLat, bLng) = line[i + 1];
      final d = GeoMath.haversine(aLat, aLng, bLat, bLng);
      if (acc + d >= m && d > 0) {
        final t = (m - acc) / d;
        return (aLat + (bLat - aLat) * t, aLng + (bLng - aLng) * t);
      }
      acc += d;
    }
    return line.last;
  }
}
