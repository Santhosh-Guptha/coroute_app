import '../../data/models/convoy_model.dart';
import '../../data/models/route_essential.dart';

/// Group fuel consensus engine: calculates the convoy's bottleneck motorcycle
/// (the rider with the lowest usable fuel range) and evaluates whether the convoy
/// must stop at the upcoming station to avoid stranding any rider.
class GroupFuelConsensus {
  final double lowestRangeKm;
  final String bottleneckUserId;
  final String bottleneckRiderName;
  final RouteEssential? recommendedStation;
  final double? distanceToStationKm;
  final bool alertLead;
  final String summary;

  const GroupFuelConsensus({
    required this.lowestRangeKm,
    required this.bottleneckUserId,
    required this.bottleneckRiderName,
    this.recommendedStation,
    this.distanceToStationKm,
    required this.alertLead,
    required this.summary,
  });

  /// Evaluates all riders in the convoy against the corridor stations.
  static GroupFuelConsensus? evaluate({
    required ConvoyModel convoy,
    required List<RouteEssential> upcomingStations,
    required double progressM,
  }) {
    if (convoy.riders.isEmpty) return null;

    String? bottleneckUid;
    String? bottleneckName;
    double minRange = double.infinity;

    for (final rider in convoy.riders.values) {
      final range = rider.fuelUsableKm;
      if (range != null && range > 0 && range < minRange) {
        minRange = range;
        bottleneckUid = rider.userId;
        bottleneckName = rider.name;
      }
    }

    if (bottleneckUid == null || minRange == double.infinity) return null;

    final upcomingFuel = upcomingStations.where((e) => e.category == 'FUEL').toList();
    final nearest = upcomingFuel.isNotEmpty ? upcomingFuel.first : null;
    final nextStation = upcomingFuel.length > 1 ? upcomingFuel[1] : null;

    final distToFirstM = nearest?.aheadM(progressM);
    final distToFirstKm = distToFirstM != null ? distToFirstM / 1000 : null;

    final distToSecondM = nextStation?.aheadM(progressM);
    final distToSecondKm = distToSecondM != null ? distToSecondM / 1000 : null;

    // A consensus stop is needed when the bottleneck rider cannot safely reach
    // the subsequent fuel station after skipping the nearest one (keeping a 30 km safety margin),
    // or when the bottleneck range drops below 75 km.
    final bool needsStop;
    if (distToSecondKm != null && distToSecondKm > (minRange - 30.0)) {
      needsStop = true; // Cannot make it to station 2!
    } else if (distToFirstKm != null && distToFirstKm > (minRange - 20.0)) {
      needsStop = true; // Dangerously close to running out before station 1!
    } else if (minRange <= 75.0) {
      needsStop = true; // General low reserve on bottleneck motorcycle
    } else {
      needsStop = false;
    }

    final who = bottleneckName?.split(' ').first ?? 'Rider';
    final summary = needsStop
        ? (nearest != null && distToFirstKm != null
            ? '$who has ${minRange.round()} km left. Stop at ${nearest.name} in ${distToFirstKm.toStringAsFixed(1)} km.'
            : '$who has only ${minRange.round()} km range remaining. Plan fuel stop.')
        : '$who has lowest range: ${minRange.round()} km left.';

    return GroupFuelConsensus(
      lowestRangeKm: minRange,
      bottleneckUserId: bottleneckUid,
      bottleneckRiderName: bottleneckName ?? 'Rider',
      recommendedStation: nearest,
      distanceToStationKm: distToFirstKm,
      alertLead: needsStop,
      summary: summary,
    );
  }
}
