import '../../data/models/route_essential.dart';
import '../tracking/geo_math.dart';

/// Only fresh, consented, usable ranges contribute. Raw tank inputs never leave
/// the device. Positions remain necessary before recommending a common stop.
class SharedFuelRange {
  final String riderId;
  final double usableKm;
  final int updatedAt, positionAt;
  const SharedFuelRange(
    this.riderId,
    this.usableKm,
    this.updatedAt,
    this.positionAt,
  );

  bool freshAt(int now) =>
      usableKm.isFinite &&
      usableKm >= 0 &&
      usableKm <= 15000 &&
      updatedAt > 0 &&
      positionAt > 0 &&
      now >= updatedAt &&
      now >= positionAt &&
      now - updatedAt < 120000 &&
      now - positionAt < 120000;
}

class GroupFuelSummary {
  final int contributors, total;
  final double? lowestKm;
  const GroupFuelSummary(this.contributors, this.total, this.lowestKm);
  static GroupFuelSummary calculate(
    Iterable<SharedFuelRange> shared, {
    required int total,
    required int now,
  }) {
    final byRider = <String, SharedFuelRange>{};
    for (final f in shared) {
      if (f.freshAt(now) && (byRider[f.riderId]?.updatedAt ?? -1) < f.updatedAt) {
        byRider[f.riderId] = f;
      }
    }
    double? lowest;
    for (final f in byRider.values) {
      if (lowest == null || f.usableKm < lowest) lowest = f.usableKm;
    }
    return GroupFuelSummary(byRider.length, total, lowest);
  }
}

/// Route positions are required: the lowest range alone cannot select a group stop.
class PositionedFuelRange {
  final SharedFuelRange range;
  final double lat, lng;
  const PositionedFuelRange(this.range, this.lat, this.lng);
}

class GroupFuelStop {
  final RouteEssential station;
  final Map<String, double> distanceKm;
  final double smallestRemainingKm;
  final int contributors;
  final int totalRiders;
  final String bottleneckRiderId;
  final bool isCompleteCoverage;
  final bool isVerifiedCoco;

  const GroupFuelStop(
    this.station,
    this.distanceKm,
    this.smallestRemainingKm, {
    this.contributors = 1,
    this.totalRiders = 1,
    this.bottleneckRiderId = '',
    this.isCompleteCoverage = true,
    this.isVerifiedCoco = false,
  });
}

/// A conservative, local-only comparison. No new GPS or provider requests.
/// Returns suggestion for contributing riders (>= 1 rider) along the same calculated route.
/// Clearly flags bottleneck rider and whether complete group coverage was achieved.
/// Prioritizes verified Indian COCO fuel pumps (IOCL, BPCL, HPCL, Shell) with fallback.
GroupFuelStop? commonFuelStop({
  required List<PositionedFuelRange> riders,
  required int total,
  required int now,
  required List<(double, double)> route,
  required Iterable<RouteEssential> stations,
  required bool reliable,
  bool prioritizeCoco = true,
}) {
  if (!reliable ||
      total < 1 ||
      riders.isEmpty ||
      riders.length > total ||
      route.length < 2 ||
      riders.map((r) => r.range.riderId).toSet().length != riders.length) {
    return null;
  }
  final positions = <String, double>{};
  for (final rider in riders) {
    if (!rider.range.freshAt(now) ||
        !rider.lat.isFinite ||
        !rider.lng.isFinite ||
        rider.lat.abs() > 85 ||
        rider.lng.abs() > 180) {
      return null;
    }
    final at = GeoMath.alongRoute(rider.lat, rider.lng, route);
    if (at == null || !at.along.isFinite || at.offRoute > 75) return null;
    // Multiple nearby, distant route segments mean a loop/crossing. Never
    // choose the first pass merely because it was first in the polyline.
    var accumulated = 0.0;
    for (var i = 1; i < route.length; i++) {
      final segment = [route[i - 1], route[i]];
      final candidate = GeoMath.alongRoute(rider.lat, rider.lng, segment)!;
      if (candidate.offRoute <= 75 &&
          (accumulated + candidate.along - at.along).abs() > 250) {
        return null;
      }
      final end = GeoMath.alongRoute(route[i].$1, route[i].$2, segment)!;
      accumulated += end.along;
    }
    positions[rider.range.riderId] = at.along;
  }

  // Identify bottleneck contributor (the rider who empties earliest along the route)
  String bottleneckRiderId = riders.first.range.riderId;
  double minEmptyM = double.infinity;
  for (final rider in riders) {
    final posM = positions[rider.range.riderId]!;
    final emptyM = posM + (rider.range.usableKm * 1000);
    if (emptyM < minEmptyM) {
      minEmptyM = emptyM;
      bottleneckRiderId = rider.range.riderId;
    }
  }

  final ordered = stations.where((s) => s.category == 'FUEL').toList()
    ..sort((a, b) => a.entryM.compareTo(b.entryM));

  final reachableStops = <({
    RouteEssential station,
    Map<String, double> distances,
    double remaining,
    bool isCoco,
  })>[];

  for (final station in ordered) {
    final distances = <String, double>{};
    var remaining = double.infinity;
    var allCanReach = true;
    for (final rider in riders) {
      final distance = station.roadDistanceM(positions[rider.range.riderId]!);
      if (distance == null ||
          !distance.isFinite ||
          distance < 0 ||
          distance / 1000 > rider.range.usableKm) {
        allCanReach = false;
        break;
      }
      final km = distance / 1000;
      distances[rider.range.riderId] = km;
      final margin = rider.range.usableKm - km;
      if (margin < remaining) remaining = margin;
    }
    if (allCanReach && distances.length == riders.length) {
      final tier = FuelStationBrand.classify(station);
      final isCoco = station.isCoco || tier == FuelBrandTier.coco;
      reachableStops.add((
        station: station,
        distances: distances,
        remaining: remaining,
        isCoco: isCoco,
      ));
    }
  }

  if (reachableStops.isEmpty) return null;

  // Prioritize verified COCO pumps if available and reachable; fallback to closest mapped station
  final selected = (prioritizeCoco && reachableStops.any((s) => s.isCoco))
      ? reachableStops.firstWhere((s) => s.isCoco)
      : reachableStops.first;

  return GroupFuelStop(
    selected.station,
    Map.unmodifiable(selected.distances),
    selected.remaining,
    contributors: riders.length,
    totalRiders: total,
    bottleneckRiderId: bottleneckRiderId,
    isCompleteCoverage: riders.length >= total,
    isVerifiedCoco: selected.isCoco,
  );
}

/// Brand classification tier for fuel stations.
/// COCO (Company Owned Company Operated) represents the highest quality tier.
enum FuelBrandTier {
  coco,
  branded,
  unbranded,
}

/// Helper for classifying fuel stations by brand trust and operation model.
class FuelStationBrand {
  static const Set<String> knownBrands = {
    'iocl',
    'indian oil',
    'indianoil',
    'bpcl',
    'bharat petroleum',
    'hpcl',
    'hindustan petroleum',
    'shell',
    'reliance',
    'jio-bp',
    'jio bp',
    'nayara',
    'total',
    'totalenergies',
    'essar',
  };

  static FuelBrandTier classify(RouteEssential station, {Map<String, dynamic>? tags}) {
    final nameLower = station.name.toLowerCase();
    final opLower = (tags?['operator'] as String? ?? '').toLowerCase();
    final opType = (tags?['operator:type'] as String? ?? '').toLowerCase();
    final brandLower = (tags?['brand'] as String? ?? '').toLowerCase();

    // Check COCO indication
    if (tags?['coco'] == true ||
        opType == 'coco' ||
        nameLower.contains('coco') ||
        opLower.contains('coco') ||
        brandLower.contains('coco')) {
      return FuelBrandTier.coco;
    }

    // Check established national/international brands
    for (final brand in knownBrands) {
      if (nameLower.contains(brand) ||
          opLower.contains(brand) ||
          brandLower.contains(brand)) {
        return FuelBrandTier.branded;
      }
    }

    return FuelBrandTier.unbranded;
  }
}

/// Identifies the bottleneck contributor who will run out of fuel earliest.
class GroupFuelBottleneck {
  final String bottleneckRiderId;
  final double bottleneckUsableKm;
  final double bottleneckRoutePositionM;
  final double emptyAtRouteM;

  const GroupFuelBottleneck({
    required this.bottleneckRiderId,
    required this.bottleneckUsableKm,
    required this.bottleneckRoutePositionM,
    required this.emptyAtRouteM,
  });
}

/// Recommendation with partial contributor awareness, bottleneck analysis,
/// COCO branded prioritization, and unbranded fallback.
class BottleneckFuelRecommendation {
  final RouteEssential station;
  final FuelBrandTier brandTier;
  final bool isCoco;
  final bool isBranded;
  final bool isFallback;
  final GroupFuelBottleneck bottleneck;
  final int contributors;
  final int totalRiders;
  final Map<String, double> distanceKm;
  final double smallestRemainingKm;

  const BottleneckFuelRecommendation({
    required this.station,
    required this.brandTier,
    required this.isCoco,
    required this.isBranded,
    required this.isFallback,
    required this.bottleneck,
    required this.contributors,
    required this.totalRiders,
    required this.distanceKm,
    required this.smallestRemainingKm,
  });
}

/// Recommends a common fuel stop based on reporting contributors,
/// constrained by the bottleneck rider, prioritizing COCO branded pumps
/// with graceful fallback to unbranded pumps.
BottleneckFuelRecommendation? recommendBottleneckFuelStop({
  required List<PositionedFuelRange> riders,
  required int total,
  required int now,
  required List<(double, double)> route,
  required Iterable<RouteEssential> stations,
  required bool reliable,
  int minContributors = 1,
}) {
  if (!reliable ||
      total < 1 ||
      riders.isEmpty ||
      riders.length < minContributors ||
      riders.length > total ||
      route.length < 2) {
    return null;
  }

  // Ensure unique riders
  final riderIds = riders.map((r) => r.range.riderId).toSet();
  if (riderIds.length != riders.length) return null;

  final positions = <String, double>{};
  for (final rider in riders) {
    if (!rider.range.freshAt(now) ||
        !rider.lat.isFinite ||
        !rider.lng.isFinite ||
        rider.lat.abs() > 85 ||
        rider.lng.abs() > 180) {
      return null;
    }
    final at = GeoMath.alongRoute(rider.lat, rider.lng, route);
    if (at == null || !at.along.isFinite || at.offRoute > 75) return null;

    // Detect route crossing or loop ambiguity
    var accumulated = 0.0;
    for (var i = 1; i < route.length; i++) {
      final segment = [route[i - 1], route[i]];
      final candidate = GeoMath.alongRoute(rider.lat, rider.lng, segment)!;
      if (candidate.offRoute <= 75 &&
          (accumulated + candidate.along - at.along).abs() > 250) {
        return null;
      }
      final end = GeoMath.alongRoute(route[i].$1, route[i].$2, segment)!;
      accumulated += end.along;
    }
    positions[rider.range.riderId] = at.along;
  }

  // Identify the bottleneck rider (runs dry earliest along route)
  String? bottleneckId;
  double minEmptyM = double.infinity;
  for (final rider in riders) {
    final id = rider.range.riderId;
    final posM = positions[id]!;
    final emptyM = posM + (rider.range.usableKm * 1000);
    if (emptyM < minEmptyM) {
      minEmptyM = emptyM;
      bottleneckId = id;
    }
  }

  if (bottleneckId == null || !minEmptyM.isFinite) return null;

  final bottleneck = GroupFuelBottleneck(
    bottleneckRiderId: bottleneckId,
    bottleneckUsableKm: riders.firstWhere((r) => r.range.riderId == bottleneckId).range.usableKm,
    bottleneckRoutePositionM: positions[bottleneckId]!,
    emptyAtRouteM: minEmptyM,
  );

  final orderedStations = stations.where((s) => s.category == 'FUEL').toList()
    ..sort((a, b) => a.entryM.compareTo(b.entryM));

  // Find all stations reachable by all reporting contributors
  final reachableCandidates = <({
    RouteEssential station,
    Map<String, double> distances,
    double smallestRemainingKm,
    FuelBrandTier tier,
  })>[];

  for (final station in orderedStations) {
    final distances = <String, double>{};
    var smallestRemaining = double.infinity;
    var allCanReach = true;

    for (final rider in riders) {
      final id = rider.range.riderId;
      final posM = positions[id]!;
      final roadDist = station.roadDistanceM(posM);
      if (roadDist == null ||
          !roadDist.isFinite ||
          roadDist < 0 ||
          (roadDist / 1000) > rider.range.usableKm) {
        allCanReach = false;
        break;
      }
      final km = roadDist / 1000;
      distances[id] = km;
      final margin = rider.range.usableKm - km;
      if (margin < smallestRemaining) smallestRemaining = margin;
    }

    if (allCanReach && distances.length == riders.length) {
      final tier = FuelStationBrand.classify(station);
      reachableCandidates.add((
        station: station,
        distances: distances,
        smallestRemainingKm: smallestRemaining,
        tier: tier,
      ));
    }
  }

  if (reachableCandidates.isEmpty) return null;

  // Prioritize COCO branded, then national branded, then unbranded fallback
  final cocoCandidates = reachableCandidates.where((c) => c.tier == FuelBrandTier.coco).toList();
  final brandedCandidates = reachableCandidates.where((c) => c.tier == FuelBrandTier.branded).toList();
  final unbrandedCandidates = reachableCandidates.where((c) => c.tier == FuelBrandTier.unbranded).toList();

  final selected = cocoCandidates.isNotEmpty
      ? cocoCandidates.first
      : brandedCandidates.isNotEmpty
          ? brandedCandidates.first
          : unbrandedCandidates.first;

  final isFallback = cocoCandidates.isEmpty && brandedCandidates.isEmpty;

  return BottleneckFuelRecommendation(
    station: selected.station,
    brandTier: selected.tier,
    isCoco: selected.tier == FuelBrandTier.coco,
    isBranded: selected.tier == FuelBrandTier.coco || selected.tier == FuelBrandTier.branded,
    isFallback: isFallback,
    bottleneck: bottleneck,
    contributors: riders.length,
    totalRiders: total,
    distanceKm: Map.unmodifiable(selected.distances),
    smallestRemainingKm: selected.smallestRemainingKm,
  );
}
