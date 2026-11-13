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

/// Which limit the rider is warned at (round 9: shown in Settings so a change visibly applies).
enum SpeedLimitSource { none, group, personal }

/// The source of [effectiveSpeedLimit] for [groupKmh] / [personalKmh] (personal wins a tie).
SpeedLimitSource speedLimitSource({required int groupKmh, required int personalKmh}) {
  final limit = effectiveSpeedLimit(groupKmh: groupKmh, personalKmh: personalKmh);
  if (limit <= 0) return SpeedLimitSource.none;
  return personalKmh > 0 && limit == personalKmh ? SpeedLimitSource.personal : SpeedLimitSource.group;
}

/// Round 9 (docs/quality/ROUND9_SETTINGS_NOTES.md): the one line under Settings › Speed warning that
/// says which limit warns now. The stricter limit always wins (safety), so a rider who raises their own
/// limit above the group's, or a lead who raises the group limit above a rider's own, changes nothing on
/// that phone; this line says so instead of looking ignored. [inRide] false: no group limit applies.
String speedWarningLine({required int groupKmh, required int personalKmh, required bool inRide}) {
  final g = inRide && groupKmh > 0 ? groupKmh : 0;
  final p = personalKmh > 0 ? personalKmh : 0;
  final limit = effectiveSpeedLimit(groupKmh: g, personalKmh: p);
  if (limit <= 0) return inRide ? 'No limit set for this ride. Road limits still warn.' : 'Uses the group limit in a ride. Road limits always warn.';
  if (!inRide) return 'Warns above $p km/h. A stricter group limit wins in a ride.';
  if (p == 0) return 'Now: group limit $g km/h.';
  if (g == 0) return 'Now: your limit $p km/h.';
  if (p < g) return 'Now: your limit $p km/h (stricter than the group\'s $g).';
  if (p > g) return 'Now: group limit $g km/h (stricter than yours).';
  return 'Now: $limit km/h.';
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
