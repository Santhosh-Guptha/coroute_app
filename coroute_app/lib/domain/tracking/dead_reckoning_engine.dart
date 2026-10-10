import 'dart:math' as math;
import '../../data/models/rider_model.dart';
import '../safety/accel_bucket.dart';
import 'geo_math.dart';

/// Representation of a known tunnel portal or mountain gorge segment.
class TunnelPortal {
  final String name;
  final double entryLat;
  final double entryLng;
  final double exitLat;
  final double exitLng;
  final double lengthMeters;

  const TunnelPortal({
    required this.name,
    required this.entryLat,
    required this.entryLng,
    required this.exitLat,
    required this.exitLng,
    required this.lengthMeters,
  });
}

/// Result of dead-reckoning projection at a given timestamp.
class CoastingFix {
  final double lat;
  final double lng;
  final double speedKmh;
  final double heading;
  final double alongRouteM;
  final TrackingConfidence confidence;
  final bool isCoasting;
  final bool hasTimedOut;
  final bool isCrashStop;
  final int elapsedSeconds;
  final String statusDescription;

  const CoastingFix({
    required this.lat,
    required this.lng,
    required this.speedKmh,
    required this.heading,
    required this.alongRouteM,
    required this.confidence,
    this.isCoasting = true,
    this.hasTimedOut = false,
    this.isCrashStop = false,
    required this.elapsedSeconds,
    required this.statusDescription,
  });
}

/// Dead-zone tunnel coasting and GPS shadow dead-reckoning engine (REQ-03).
///
/// Keeps smooth, along-route dead-reckoning progression when GPS fix is lost
/// in mountain tunnels (e.g. Atal Tunnel 9.02 km, Dr. Syama Prasad Mookerjee Tunnel)
/// and canyon gorges.
///
/// Conservatively decays speed along the polyline using v(t) = v0 * exp(-alpha * t)
/// for up to 12 minutes (720 seconds) while suppressing false separation and stop alarms.
///
/// Inspects accelerometer sensor buckets for sudden deceleration impacts followed
/// by stationary rest, halting dead-reckoning at the crash point.
class DeadReckoningEngine {
  /// Known tunnel portals in Indian mountain touring corridors.
  static const List<TunnelPortal> knownTunnels = [
    // Atal Tunnel, Rohtang (9.02 km)
    TunnelPortal(
      name: 'Atal Tunnel (Rohtang)',
      entryLat: 32.3639,
      entryLng: 77.1462,
      exitLat: 32.4411,
      exitLng: 77.1594,
      lengthMeters: 9020,
    ),
    // Dr. Syama Prasad Mookerjee (Chenani-Nashri) Tunnel (9.28 km)
    TunnelPortal(
      name: 'Dr. Syama Prasad Mookerjee Tunnel',
      entryLat: 33.0425,
      entryLng: 75.2842,
      exitLat: 33.1258,
      exitLng: 75.3121,
      lengthMeters: 9280,
    ),
    // Banihal Qazigund Road Tunnel (8.45 km)
    TunnelPortal(
      name: 'Banihal-Qazigund Tunnel',
      entryLat: 33.5186,
      entryLng: 75.1950,
      exitLat: 33.5932,
      exitLng: 75.1685,
      lengthMeters: 8450,
    ),
    // Jawahar Tunnel (2.85 km)
    TunnelPortal(
      name: 'Jawahar Tunnel',
      entryLat: 33.5147,
      entryLng: 75.1931,
      exitLat: 33.5398,
      exitLng: 75.1884,
      lengthMeters: 2850,
    ),
    // Kuthiran Tunnel, Kerala (0.96 km)
    TunnelPortal(
      name: 'Kuthiran Tunnel',
      entryLat: 10.5843,
      entryLng: 76.3812,
      exitLat: 10.5925,
      exitLng: 76.3845,
      lengthMeters: 962,
    ),
    // Z-Morh Tunnel, Sonamarg (6.5 km)
    TunnelPortal(
      name: 'Z-Morh Tunnel',
      entryLat: 34.2980,
      entryLng: 75.2310,
      exitLat: 34.3090,
      exitLng: 75.2950,
      lengthMeters: 6500,
    ),
  ];

  /// Maximum coasting duration: 12 minutes (720 seconds).
  static const int maxCoastingDurationSec = 720;

  /// Proximity threshold to identify a tunnel portal entry/exit in meters.
  static const double portalProximityRadiusM = 150.0;

  /// Conservative exponential decay constant alpha:
  /// v(t) = v0 * exp(-alpha * t)
  /// At alpha = 0.0025, after 60s speed is 86%, after 120s speed is 74%,
  /// after 300s speed is 47%, keeping realistic cruising pace.
  static const double speedDecayAlpha = 0.0025;

  /// Crash detection threshold on accelerometer peak impact during coasting.
  static const double crashDecelPeakG = 3.2;

  /// Stationary vibration threshold (phone resting or bike halted).
  static const double stationaryStdGThreshold = 0.09;

  DeadReckoningEngine({
    List<(double, double)>? plannedRoute,
  }) : _plannedRoute = plannedRoute ?? const [];

  List<(double, double)> _plannedRoute;
  bool _isCoasting = false;
  int _coastingStartMs = 0;
  double _entrySpeedKmh = 0.0;
  double _entryAlongM = 0.0;
  double _lastKnownLat = 0.0;
  double _lastKnownLng = 0.0;
  double _lastKnownHeading = 0.0;
  bool _crashDetectedInTunnel = false;
  double _frozenLat = 0.0;
  double _frozenLng = 0.0;
  double _frozenAlongM = 0.0;

  bool get isCoasting => _isCoasting;
  bool get crashDetectedInTunnel => _crashDetectedInTunnel;
  List<(double, double)> get plannedRoute => _plannedRoute;

  void setPlannedRoute(List<(double, double)> route) {
    _plannedRoute = List.unmodifiable(route);
  }

  /// Checks if given coordinates are within [radiusM] of any known tunnel portal.
  static bool isNearTunnelPortal(
    double lat,
    double lng, {
    double radiusM = portalProximityRadiusM,
  }) {
    if (!lat.isFinite || !lng.isFinite) return false;
    for (final tunnel in knownTunnels) {
      final dEntry = GeoMath.haversine(lat, lng, tunnel.entryLat, tunnel.entryLng);
      final dExit = GeoMath.haversine(lat, lng, tunnel.exitLat, tunnel.exitLng);
      if (dEntry <= radiusM || dExit <= radiusM) {
        return true;
      }
    }
    return false;
  }

  /// Finds closest tunnel portal within [radiusM] or null if none.
  static TunnelPortal? findNearbyTunnel(
    double lat,
    double lng, {
    double radiusM = portalProximityRadiusM,
  }) {
    if (!lat.isFinite || !lng.isFinite) return null;
    TunnelPortal? best;
    double bestDist = double.infinity;
    for (final tunnel in knownTunnels) {
      final dEntry = GeoMath.haversine(lat, lng, tunnel.entryLat, tunnel.entryLng);
      final dExit = GeoMath.haversine(lat, lng, tunnel.exitLat, tunnel.exitLng);
      final m = math.min(dEntry, dExit);
      if (m <= radiusM && m < bestDist) {
        bestDist = m;
        best = tunnel;
      }
    }
    return best;
  }

  /// Resets or cancels coasting (e.g. when valid GPS fix is recovered).
  void onGpsRecovered() {
    _isCoasting = false;
    _coastingStartMs = 0;
    _crashDetectedInTunnel = false;
  }

  /// Initiates tunnel coasting mode when GPS fix is lost.
  void startCoasting({
    required double lat,
    required double lng,
    required double speedKmh,
    required double heading,
    required int timestampMs,
  }) {
    _isCoasting = true;
    _coastingStartMs = timestampMs;
    _entrySpeedKmh = speedKmh.clamp(10.0, 120.0);
    _lastKnownLat = lat;
    _lastKnownLng = lng;
    _lastKnownHeading = heading;
    _crashDetectedInTunnel = false;

    // Calculate along-route distance at entry point
    if (_plannedRoute.length >= 2) {
      final along = GeoMath.alongRoute(lat, lng, _plannedRoute);
      _entryAlongM = along?.along ?? 0.0;
    } else {
      _entryAlongM = 0.0;
    }
    _frozenAlongM = _entryAlongM;
    _frozenLat = lat;
    _frozenLng = lng;
  }

  /// Ingests accelerometer buckets while in tunnel coasting to detect deceleration crashes.
  void checkAccelerometer(AccelBucket bucket) {
    if (!_isCoasting || _crashDetectedInTunnel) return;

    if (bucket.peakG >= crashDecelPeakG && bucket.stdG <= stationaryStdGThreshold) {
      _crashDetectedInTunnel = true;
      _frozenLat = _lastKnownLat;
      _frozenLng = _lastKnownLng;
    }
  }

  /// Calculates dead-reckoning position projection for the given [nowMs].
  CoastingFix computeFix(int nowMs) {
    if (!_isCoasting) {
      return CoastingFix(
        lat: _lastKnownLat,
        lng: _lastKnownLng,
        speedKmh: _entrySpeedKmh,
        heading: _lastKnownHeading,
        alongRouteM: _entryAlongM,
        confidence: TrackingConfidence.gpsFix,
        isCoasting: false,
        elapsedSeconds: 0,
        statusDescription: 'GPS Fix Active',
      );
    }

    final elapsedMs = nowMs - _coastingStartMs;
    final elapsedSec = math.max(0, elapsedMs ~/ 1000);

    // Case 1: In-tunnel crash / sudden deceleration halt
    if (_crashDetectedInTunnel) {
      return CoastingFix(
        lat: _frozenLat,
        lng: _frozenLng,
        speedKmh: 0.0,
        heading: _lastKnownHeading,
        alongRouteM: _frozenAlongM,
        confidence: TrackingConfidence.degradedMultipath,
        isCoasting: true,
        isCrashStop: true,
        elapsedSeconds: elapsedSec,
        statusDescription: 'Tunnel Impact Stop Detected',
      );
    }

    // Case 2: Coasting timeout (> 12 minutes = 720 seconds)
    if (elapsedSec >= maxCoastingDurationSec) {
      return CoastingFix(
        lat: _frozenLat,
        lng: _frozenLng,
        speedKmh: 0.0,
        heading: _lastKnownHeading,
        alongRouteM: _frozenAlongM,
        confidence: TrackingConfidence.lost,
        isCoasting: false,
        hasTimedOut: true,
        elapsedSeconds: elapsedSec,
        statusDescription: 'Tunnel Signal Lost',
      );
    }

    // Case 3: Conservative exponential decay along route polyline
    // v(t) = v0 * exp(-alpha * t)
    final vCurrentKmh = _entrySpeedKmh * math.exp(-speedDecayAlpha * elapsedSec);
    final v0Mps = _entrySpeedKmh / 3.6;

    // Integrated distance: integral_0^t (v0 * exp(-alpha * t)) dt = (v0 / alpha) * (1 - exp(-alpha * t))
    final projectedDistanceM = (v0Mps / speedDecayAlpha) * (1.0 - math.exp(-speedDecayAlpha * elapsedSec));
    final targetAlongM = _entryAlongM + projectedDistanceM;

    final projected = pointAlongRoute(targetAlongM, _plannedRoute);
    if (projected != null) {
      _lastKnownLat = projected.$1;
      _lastKnownLng = projected.$2;
      _lastKnownHeading = projected.$3;
      _frozenAlongM = targetAlongM;
      _frozenLat = projected.$1;
      _frozenLng = projected.$2;

      return CoastingFix(
        lat: projected.$1,
        lng: projected.$2,
        speedKmh: vCurrentKmh,
        heading: projected.$3,
        alongRouteM: targetAlongM,
        confidence: TrackingConfidence.tunnelCoasting,
        isCoasting: true,
        elapsedSeconds: elapsedSec,
        statusDescription: 'Tunnel Coasting (${elapsedSec}s)',
      );
    }

    // Fallback if no route polyline: project along entry heading
    final fallbackPt = _projectDeadReckoningCoord(
      _lastKnownLat,
      _lastKnownLng,
      projectedDistanceM,
      _lastKnownHeading,
    );
    _frozenLat = fallbackPt.$1;
    _frozenLng = fallbackPt.$2;

    return CoastingFix(
      lat: fallbackPt.$1,
      lng: fallbackPt.$2,
      speedKmh: vCurrentKmh,
      heading: _lastKnownHeading,
      alongRouteM: targetAlongM,
      confidence: TrackingConfidence.tunnelCoasting,
      isCoasting: true,
      elapsedSeconds: elapsedSec,
      statusDescription: 'Tunnel Coasting (${elapsedSec}s)',
    );
  }

  /// Locates the coordinate and segment bearing at [targetAlongM] meters from route start.
  /// Returns (lat, lng, headingDegrees) or null if route is invalid.
  static (double, double, double)? pointAlongRoute(
    double targetAlongM,
    List<(double, double)> line,
  ) {
    if (line.length < 2) return null;
    if (targetAlongM <= 0) {
      final b = GeoMath.haversine(line[0].$1, line[0].$2, line[1].$1, line[1].$2) > 0
          ? _bearingBetween(line[0].$1, line[0].$2, line[1].$1, line[1].$2)
          : 0.0;
      return (line[0].$1, line[0].$2, b);
    }

    var accumulatedM = 0.0;
    for (var i = 0; i < line.length - 1; i++) {
      final a = line[i];
      final b = line[i + 1];
      final segLengthM = GeoMath.haversine(a.$1, a.$2, b.$1, b.$2);
      if (segLengthM <= 0) continue;

      if (accumulatedM + segLengthM >= targetAlongM) {
        final remainingM = targetAlongM - accumulatedM;
        final fraction = (remainingM / segLengthM).clamp(0.0, 1.0);
        final lat = a.$1 + (b.$1 - a.$1) * fraction;
        final lng = a.$2 + (b.$2 - a.$2) * fraction;
        final bearing = _bearingBetween(a.$1, a.$2, b.$1, b.$2);
        return (lat, lng, bearing);
      }
      accumulatedM += segLengthM;
    }

    // Past end of route: clamp to last point
    final last = line.last;
    final secondLast = line[line.length - 2];
    final b = _bearingBetween(secondLast.$1, secondLast.$2, last.$1, last.$2);
    return (last.$1, last.$2, b);
  }

  static double _bearingBetween(double lat1, double lng1, double lat2, double lng2) {
    final phi1 = lat1 * math.pi / 180.0;
    final phi2 = lat2 * math.pi / 180.0;
    final deltaLambda = (lng2 - lng1) * math.pi / 180.0;
    final y = math.sin(deltaLambda) * math.cos(phi2);
    final x = math.cos(phi1) * math.sin(phi2) - math.sin(phi1) * math.cos(phi2) * math.cos(deltaLambda);
    final bearingRad = math.atan2(y, x);
    return ((bearingRad * 180.0 / math.pi) + 360.0) % 360.0;
  }

  static (double, double) _projectDeadReckoningCoord(
    double lat,
    double lng,
    double distanceM,
    double bearingDeg,
  ) {
    final dDivR = distanceM / GeoMath.earthRadiusM;
    final bRad = bearingDeg * math.pi / 180.0;
    final lat1Rad = lat * math.pi / 180.0;
    final lng1Rad = lng * math.pi / 180.0;

    final lat2Rad = math.asin(
      math.sin(lat1Rad) * math.cos(dDivR) + math.cos(lat1Rad) * math.sin(dDivR) * math.cos(bRad),
    );
    final lng2Rad = lng1Rad +
        math.atan2(
          math.sin(bRad) * math.sin(dDivR) * math.cos(lat1Rad),
          math.cos(dDivR) - math.sin(lat1Rad) * math.sin(lat2Rad),
        );

    return (lat2Rad * 180.0 / math.pi, lng2Rad * 180.0 / math.pi);
  }
}
