import '../tracking/geo_math.dart';

/// The speed limit a rider is warned at (3.55 fix): the stricter of the group limit the lead set
/// and the rider's own limit from Settings; 0 = no limit. Before, a group limit always won, so a
/// rider who lowered their own limit during a group ride saw no change.
int effectiveSpeedLimit({required int groupKmh, required int personalKmh}) {
  final g = groupKmh > 0 ? groupKmh : 0;
  final p = personalKmh > 0 ? personalKmh : 0;
  if (g == 0) return p;
  if (p == 0) return g;
  return g < p ? g : p;
}

/// 3.55 fix: the lead's town limit on the rider's phone. The group limit at ([lat], [lng]), lowered
/// to [townKmh] within [radiusM] of the start, the destination or a planned stop ([places]); the
/// same rule the gateway's timeline uses (_activeLimit, TOWN_RADIUS_M 1000). Before, only the server
/// applied it, so a town limit set by the lead never reached the rider's own warning or display.
/// 0 = no limit.
int groupLimitAt({
  required int groupKmh,
  required int townKmh,
  required double lat,
  required double lng,
  required Iterable<(double, double)> places,
  double radiusM = 1000,
}) {
  final group = groupKmh > 0 ? groupKmh : 0;
  if (townKmh <= 0 || !lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0)) return group;
  for (final (pLat, pLng) in places) {
    if ((pLat == 0 && pLng == 0) || !pLat.isFinite || !pLng.isFinite) continue;
    if (GeoMath.haversine(lat, lng, pLat, pLng) <= radiusM) return group > 0 && group < townKmh ? group : townKmh;
  }
  return group;
}
