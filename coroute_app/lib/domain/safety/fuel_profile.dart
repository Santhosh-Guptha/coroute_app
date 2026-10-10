import 'dart:math' as math;

/// Optional rider inputs. Zero capacity/mileage selects the simple range mode.
/// No field represents a measured tank level.
class FuelProfile {
  final double capacityL, mileageKmL, fullRangeKm, reserveL, reserveKm, bufferKm;
  const FuelProfile({this.capacityL = 0, this.mileageKmL = 0, this.fullRangeKm = 0,
    this.reserveL = 0, this.reserveKm = 0, this.bufferKm = 20});
  bool get litresMode => capacityL > 0 && mileageKmL > 0;
  double get rangeKm => litresMode ? capacityL * mileageKmL : fullRangeKm;
  double get marginKm => (litresMode ? reserveL * mileageKmL : reserveKm) + bufferKm;
  bool get valid => [capacityL, mileageKmL, fullRangeKm, reserveL, reserveKm, bufferKm].every((v) => v.isFinite && v >= 0)
      && capacityL <= 100 && mileageKmL <= 150 && fullRangeKm <= 3000 && bufferKm <= 500
      && (litresMode ? reserveL < capacityL : reserveKm < fullRangeKm)
      && rangeKm > marginKm;
  double usableKm(double baselineKm, double riddenM) => math.max(0, baselineKm - riddenM / 1000 - marginKm);
  Map<String, dynamic> toJson() => {'capacityL': capacityL, 'mileageKmL': mileageKmL,
    'fullRangeKm': fullRangeKm, 'reserveL': reserveL, 'reserveKm': reserveKm, 'bufferKm': bufferKm};
  static FuelProfile fromJson(Map j) {
    double n(String k, [double fallback = 0]) => j[k] is num ? (j[k] as num).toDouble() : fallback;
    return FuelProfile(capacityL: n('capacityL'), mileageKmL: n('mileageKmL'), fullRangeKm: n('fullRangeKm'),
      reserveL: n('reserveL'), reserveKm: n('reserveKm'), bufferKm: n('bufferKm', 20));
  }
}

enum FuelAdvice { unknown, withinEstimate, consider, recommended, rangeRisk }

/// Distances must be road distances from the rider, including access to the station.
/// Partial or stale place coverage can warn, but can never endorse skipping a stop.
FuelAdvice fuelAdvice({required double? usableKm, required double? nextKm,
    double? followingKm, required bool reliable, double cautionKm = 20}) {
  if (usableKm == null || nextKm == null || !usableKm.isFinite || !nextKm.isFinite || usableKm < 0 || nextKm < 0) return FuelAdvice.unknown;
  if (usableKm < nextKm) return FuelAdvice.rangeRisk;
  if (!reliable) return FuelAdvice.unknown;
  if (followingKm == null || !followingKm.isFinite || followingKm < nextKm) return FuelAdvice.consider;
  if (followingKm > usableKm) return FuelAdvice.recommended;
  if (followingKm + cautionKm > usableKm) return FuelAdvice.consider;
  return FuelAdvice.withinEstimate;
}
