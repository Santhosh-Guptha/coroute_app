import 'fuel_match.dart';
import 'place_poi.dart';
import 'route_corridor.dart';

/// A place projected once onto the route.
class ProjectedPoi {
  const ProjectedPoi(this.poi, this.alongM, this.offM);
  final PlacePoi poi;
  final double alongM, offM;
}

/// Projects places onto [path], keeping those within [maxOffM] of it. Done once
/// per new data or route, never per GPS fix.
List<ProjectedPoi> projectOntoRoute(Iterable<PlacePoi> pois, RoutePath path, {double maxOffM = 1500}) {
  final out = <ProjectedPoi>[];
  if (!path.valid) return out;
  for (final p in pois) {
    final hit = path.project(p.lat, p.lng);
    if (hit != null && hit.off <= maxOffM) out.add(ProjectedPoi(p, hit.along, hit.off));
  }
  out.sort((a, b) => a.alongM.compareTo(b.alongM));
  return out;
}

enum Reach { reachable, onReserve, tooFar, unknown }

extension ReachText on Reach {
  String get label => switch (this) {
        Reach.reachable => 'Reachable',
        Reach.onReserve => 'On reserve',
        Reach.tooFar => 'Too far',
        Reach.unknown => 'Range not set',
      };
}

/// [usableKm] is the estimate before the reserve (and safety buffer) of
/// [marginKm]; a stop past both is too far.
Reach reachOf(double distanceKm, {double? usableKm, double marginKm = 0}) {
  if (usableKm == null || !usableKm.isFinite || !distanceKm.isFinite) return Reach.unknown;
  if (distanceKm <= usableKm) return Reach.reachable;
  if (distanceKm <= usableKm + marginKm) return Reach.onReserve;
  return Reach.tooFar;
}

/// A station ahead on the route for this bike.
class FuelStop {
  const FuelStop({required this.poi, required this.match, required this.alongM, required this.offM,
      required this.distanceKm, required this.reach});
  final PlacePoi poi;
  final FuelMatch match;
  final double alongM, offM;

  /// Along the route from the rider, plus the way off the route to the pump.
  final double distanceKm;
  final Reach reach;
  bool get confirmed => match == FuelMatch.match;
}

/// Stations ahead of [progressM] for this fuel type, nearest first. Stations that
/// explicitly do not sell it are left out; untagged ones are kept (unconfirmed).
List<FuelStop> fuelStopsAhead(List<ProjectedPoi> projected, {required double progressM, required BikeFuelType type,
    double? usableKm, double marginKm = 0, double behindM = 100, int limit = 12}) {
  final out = <FuelStop>[];
  for (final p in projected) {
    if (p.alongM < progressM - behindM) continue;
    final m = fuelMatch(p.poi, type);
    if (m == FuelMatch.noMatch) continue;
    final d = ((p.alongM - progressM).clamp(0, double.infinity) + p.offM) / 1000;
    out.add(FuelStop(poi: p.poi, match: m, alongM: p.alongM, offM: p.offM, distanceKm: d,
        reach: reachOf(d, usableKm: usableKm, marginKm: marginKm)));
    if (out.length >= limit * 3) break;
  }
  out.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// Everything the fuel warning needs at one moment, from the places loaded on the phone.
class FuelAheadView {
  const FuelAheadView({required this.type, required this.stops, required this.coverageKm, this.groupStopKm, this.groupStopName});
  final BikeFuelType type;
  final List<FuelStop> stops;

  /// How far ahead the places are loaded without gaps (km); a missing station
  /// beyond this is "not known", never "none".
  final double coverageKm;
  final double? groupStopKm;
  final String? groupStopName;
}
