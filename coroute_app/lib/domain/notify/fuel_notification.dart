import '../../data/models/route_essential.dart';
import '../safety/fuel_profile.dart';
import 'status_text.dart';

/// Bounded presentation derived from the shared route window, never a provider call.
class FuelNotification {
  const FuelNotification(this.line, this.detail, {this.warning = false});
  final String line, detail;
  final bool warning;

  static FuelNotification build({required EssentialsSnapshot? snapshot,
      required double progressM, required double? usableKm, required bool uncertain,
      required bool online, required bool currentPosition, required int now}) {
    if (!currentPosition) return const FuelNotification('Fuel · waiting for location', 'Open Fuel for details');
    final range = usableKm != null && usableKm.isFinite && usableKm >= 0
        ? 'Est. usable ${usableKm.floor()} km${uncertain ? ' · uncertain' : ''}' : 'Fuel range not set';
    if (snapshot == null || snapshot.category != 'FUEL') {
      return FuelNotification(online ? 'Fuel information unavailable' : 'Fuel unavailable offline', range);
    }
    final stations = snapshot.places.where((p) => p.routePositionM >= progressM).take(2).toList();
    if (stations.isEmpty) return FuelNotification('No upcoming mapped stations in this window', '$range · coverage limited');
    String distance(RouteEssential p) => StatusText.roundedDistance(p.aheadM(progressM));
    final line = 'You → ${stations.map((p) => '${p.name.length > 22 ? '${p.name.substring(0, 21)}…' : p.name} +${distance(p)}').join(' → ')}';
    final fresh = snapshot.freshAt(now) && online;
    final advice = fuelAdvice(usableKm: uncertain || !fresh ? null : usableKm,
        nextKm: stations.first.roadDistanceM(progressM) == null ? null : stations.first.roadDistanceM(progressM)! / 1000,
        followingKm: stations.length < 2 ? null : stations[1].roadDistanceM(progressM) == null ? null : stations[1].roadDistanceM(progressM)! / 1000,
        reliable: fresh && snapshot.complete);
    final warning = advice == FuelAdvice.rangeRisk || advice == FuelAdvice.recommended;
    final reason = advice == FuelAdvice.rangeRisk ? 'Next station exceeds estimate'
        : advice == FuelAdvice.recommended ? 'Fuel stop recommended'
        : !fresh ? 'Cached · ${DateTime.fromMillisecondsSinceEpoch(snapshot.fetchedAt).toLocal().toString().substring(0, 16)}'
        : 'Along-route distances · ${snapshot.complete ? 'mapped stations' : 'partial coverage'}';
    return FuelNotification(line, '$range · $reason', warning: warning);
  }
}
