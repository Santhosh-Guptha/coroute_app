import 'dart:math' as math;
import '../tracking/geo_math.dart';
import '../tracking/track_point.dart';

/// Guidance target for a lost or off-route rider.
enum RecoveryTargetType { routeLine, sweeper, convoyLead, backtrackFork }

/// Offline homing vector providing bearing, distance and directions to rejoin.
class RecoveryVector {
  final RecoveryTargetType targetType;
  final double targetLat;
  final double targetLng;
  final double distanceMeters;
  final double bearingDegrees;
  final String instruction;
  final bool usingGpsCourse;

  const RecoveryVector({
    required this.targetType,
    required this.targetLat,
    required this.targetLng,
    required this.distanceMeters,
    required this.bearingDegrees,
    required this.instruction,
    required this.usingGpsCourse,
  });

  /// Cardinal direction string (e.g. N, NE, E, SE, S, SW, W, NW).
  String get cardinalDirection {
    const cardinals = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    final idx = ((bearingDegrees + 22.5) % 360 / 45).floor();
    return cardinals[idx.clamp(0, cardinals.length - 1)];
  }
}

/// Offline coordinator for calculating homing vectors and backtrack breadcrumbs
/// for lost riders in remote or zero-connectivity terrain.
class LostRiderRecoveryCoordinator {
  LostRiderRecoveryCoordinator._();

  static double _rad(double d) => d * math.pi / 180.0;

  /// Calculates bearing from (lat1, lng1) to (lat2, lng2) in degrees (0..360).
  static double calculateBearing(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    final y = math.sin(_rad(lng2 - lng1)) * math.cos(_rad(lat2));
    final x = math.cos(_rad(lat1)) * math.sin(_rad(lat2)) -
        math.sin(_rad(lat1)) * math.cos(_rad(lat2)) * math.cos(_rad(lng2 - lng1));
    final b = math.atan2(y, x) * 180.0 / math.pi;
    return (b + 360.0) % 360.0;
  }

  /// Finds the closest point on a route polyline to the given coordinates.
  static (double lat, double lng)? closestPointOnRoute(
    double lat,
    double lng,
    List<(double, double)> route,
  ) {
    if (route.length < 2) return null;
    var bestDist = double.infinity;
    (double, double)? bestPoint;

    for (var i = 0; i < route.length - 1; i++) {
      final (aLat, aLng) = route[i];
      final (bLat, bLng) = route[i + 1];

      final dLat = bLat - aLat;
      final dLng = bLng - aLng;
      final len2 = dLat * dLat + dLng * dLng;

      var t = len2 > 0 ? ((lat - aLat) * dLat + (lng - aLng) * dLng) / len2 : 0.0;
      t = t.clamp(0.0, 1.0);

      final cLat = aLat + t * dLat;
      final cLng = aLng + t * dLng;
      final d = GeoMath.haversine(lat, lng, cLat, cLng);

      if (d < bestDist) {
        bestDist = d;
        bestPoint = (cLat, cLng);
      }
    }
    return bestPoint;
  }

  /// Computes a homing recovery vector for a rider.
  /// Prioritizes:
  /// 1. Route line if off route.
  /// 2. Sweeper position if available.
  /// 3. Backtrack along recorded breadcrumbs if available.
  static RecoveryVector? computeRecovery({
    required double riderLat,
    required double riderLng,
    double? compassHeading,
    double? gpsHeading,
    double speedKmh = 0,
    List<(double, double)>? plannedRoute,
    double? sweeperLat,
    double? sweeperLng,
    List<TrackPoint>? breadcrumbs,
  }) {
    if (!riderLat.isFinite || !riderLng.isFinite) return null;

    // Determine heading: use compass heading, or fallback to GPS course if moving > 4 km/h
    final usingGps = compassHeading == null && speedKmh >= 4.0 && gpsHeading != null;

    // Target 1: Closest point on the planned route
    if (plannedRoute != null && plannedRoute.length >= 2) {
      final closest = closestPointOnRoute(riderLat, riderLng, plannedRoute);
      if (closest != null) {
        final dist = GeoMath.haversine(riderLat, riderLng, closest.$1, closest.$2);
        final b = calculateBearing(riderLat, riderLng, closest.$1, closest.$2);

        String distStr;
        if (dist >= 1000) {
          distStr = '${(dist / 1000).toStringAsFixed(1)} km';
        } else {
          distStr = '${dist.round()} m';
        }

        final cardinal = _cardinalFromBearing(b);
        final instruction = 'Rejoin Route: Head $cardinal for $distStr';

        return RecoveryVector(
          targetType: RecoveryTargetType.routeLine,
          targetLat: closest.$1,
          targetLng: closest.$2,
          distanceMeters: dist,
          bearingDegrees: b,
          instruction: instruction,
          usingGpsCourse: usingGps,
        );
      }
    }

    // Target 2: Sweeper position
    if (sweeperLat != null && sweeperLng != null && sweeperLat.isFinite && sweeperLng.isFinite) {
      final dist = GeoMath.haversine(riderLat, riderLng, sweeperLat, sweeperLng);
      final b = calculateBearing(riderLat, riderLng, sweeperLat, sweeperLng);
      final cardinal = _cardinalFromBearing(b);
      final distStr = dist >= 1000 ? '${(dist / 1000).toStringAsFixed(1)} km' : '${dist.round()} m';

      return RecoveryVector(
        targetType: RecoveryTargetType.sweeper,
        targetLat: sweeperLat,
        targetLng: sweeperLng,
        distanceMeters: dist,
        bearingDegrees: b,
        instruction: 'Homing to Sweeper: Head $cardinal for $distStr',
        usingGpsCourse: usingGps,
      );
    }

    // Target 3: Backtrack along breadcrumbs
    if (breadcrumbs != null && breadcrumbs.length >= 5) {
      // Point from ~2 minutes ago or 500m back
      final origin = breadcrumbs.first;
      final dist = GeoMath.haversine(riderLat, riderLng, origin.lat, origin.lng);
      final b = calculateBearing(riderLat, riderLng, origin.lat, origin.lng);
      final distStr = dist >= 1000 ? '${(dist / 1000).toStringAsFixed(1)} km' : '${dist.round()} m';

      return RecoveryVector(
        targetType: RecoveryTargetType.backtrackFork,
        targetLat: origin.lat,
        targetLng: origin.lng,
        distanceMeters: dist,
        bearingDegrees: b,
        instruction: 'Backtrack along trail for $distStr',
        usingGpsCourse: usingGps,
      );
    }

    return null;
  }

  static String _cardinalFromBearing(double b) {
    const cardinals = ['North', 'Northeast', 'East', 'Southeast', 'South', 'Southwest', 'West', 'Northwest'];
    final idx = ((b + 22.5) % 360 / 45).floor();
    return cardinals[idx.clamp(0, cardinals.length - 1)];
  }
}
