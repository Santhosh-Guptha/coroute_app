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

/// Result of re-converging coasted coordinate towards a recovered GPS fix.
class ConvergencePoint {
  final double lat;
  final double lng;
  final double speedKmh;
  final double heading;
  final double distanceM;
  final bool isCompleted;

  const ConvergencePoint({
    required this.lat,
    required this.lng,
    required this.speedKmh,
    required this.heading,
    required this.distanceM,
    required this.isCompleted,
  });
}

/// Dead-zone tunnel coasting and GPS shadow dead-reckoning engine (REQ-03, FEAT-09).
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

  /// Powered cruising speed decay alpha (engine running, throttle or gearing engaged):
  /// v(t) = v0 * exp(-alpha * t)
  /// At alpha = 0.0008, after 120s speed remains ~90%, after 300s speed remains ~78%.
  static const double poweredDecayAlpha = 0.0008;

  /// Unpowered coasting speed decay alpha (engine idle or neutral roll):
  /// At alpha = 0.0055, after 60s speed is 71%, after 180s speed is 37%.
  static const double unpoweredDecayAlpha = 0.0055;

  /// Crash detection threshold on accelerometer peak impact during coasting.
  static const double crashDecelPeakG = 3.2;

  /// Severe impact threshold in G for in-tunnel collision detection.
  static const double severeImpactG = 4.0;

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
  bool _engineRunning = true;
  int _lastVibrationMs = 0;
  int _lowVibrationSeconds = 0;

  // Convergence state when GPS recovers upon tunnel exit
  bool _isConverging = false;
  int _convergenceStartMs = 0;
  int _convergenceDurationMs = 4000;
  double _convStartLat = 0.0;
  double _convStartLng = 0.0;
  double _convTargetGpsLat = 0.0;
  double _convTargetGpsLng = 0.0;
  double _convGpsSpeedKmh = 0.0;
  double _convGpsHeading = 0.0;

  bool get isCoasting => _isCoasting;
  bool get isConverging => _isConverging;
  bool get crashDetectedInTunnel => _crashDetectedInTunnel;
  bool get isEngineRunning => _engineRunning;
  int get lastVibrationMs => _lastVibrationMs;
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
    _isConverging = false;
    _coastingStartMs = 0;
    _crashDetectedInTunnel = false;
    _engineRunning = true;
    _lowVibrationSeconds = 0;
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
    _isConverging = false;
    _coastingStartMs = timestampMs;
    _entrySpeedKmh = speedKmh.clamp(10.0, 120.0);
    _lastKnownLat = lat;
    _lastKnownLng = lng;
    _lastKnownHeading = heading;
    _crashDetectedInTunnel = false;
    _engineRunning = true;
    _lastVibrationMs = timestampMs;
    _lowVibrationSeconds = 0;

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

  /// Ingests accelerometer buckets while in tunnel coasting to detect deceleration crashes
  /// and analyze structural motorcycle engine/road vibration signatures.
  void checkAccelerometer(AccelBucket bucket) {
    if (!_isCoasting || _crashDetectedInTunnel) return;

    // Severe impact detection (> 4.0G) or standard deceleration threshold with stationary rest
    if (bucket.peakG >= severeImpactG ||
        (bucket.peakG >= crashDecelPeakG && bucket.stdG <= stationaryStdGThreshold)) {
      _crashDetectedInTunnel = true;
      _frozenLat = _lastKnownLat;
      _frozenLng = _lastKnownLng;
      return;
    }

    // Heavy braking / deceleration adjustment
    if (bucket.peakG >= 1.8 && bucket.peakG < crashDecelPeakG) {
      _entrySpeedKmh = math.max(5.0, _entrySpeedKmh * 0.85);
    }

    // Road & engine vibration signature analysis:
    // Single / multi-cylinder motorcycle engines produce characteristic high-frequency
    // vibration with stdG >= 0.08 and meanG around 1.0G.
    final hasEngineVibration = bucket.stdG >= 0.08 && bucket.meanG >= 0.7 && bucket.meanG <= 1.6;
    if (hasEngineVibration) {
      _engineRunning = true;
      _lastVibrationMs = bucket.tMs;
      _lowVibrationSeconds = 0;
    } else if (bucket.stdG < 0.05) {
      _lowVibrationSeconds++;
      if (_lowVibrationSeconds >= 4) {
        _engineRunning = false;
      }
    }
  }

  /// Returns whether the vehicle is actively moving inside the tunnel or canyon dead-zone,
  /// suppressing false "Rider Stopped" or "Rider Lost" alerts.
  bool isVehicularMoving(int nowMs) {
    if (!_isCoasting || _crashDetectedInTunnel) return false;
    final fix = computeFix(nowMs);
    return !fix.hasTimedOut && fix.speedKmh >= 5.0;
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
    // Uses powered decay alpha if engine vibration confirms engine is running,
    // otherwise higher decay for unpowered roll.
    final decayAlpha = _engineRunning ? poweredDecayAlpha : unpoweredDecayAlpha;
    final vCurrentKmh = _entrySpeedKmh * math.exp(-decayAlpha * elapsedSec);
    final v0Mps = _entrySpeedKmh / 3.6;

    // Integrated distance: integral_0^t (v0 * exp(-alpha * t)) dt = (v0 / alpha) * (1 - exp(-alpha * t))
    final projectedDistanceM = (v0Mps / decayAlpha) * (1.0 - math.exp(-decayAlpha * elapsedSec));
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

  /// Begins smooth convergence towards newly re-acquired GPS fix over [durationMs] (3-5s).
  void startConvergence({
    required double gpsLat,
    required double gpsLng,
    required double gpsSpeedKmh,
    required double gpsHeading,
    required int nowMs,
    int durationMs = 4000,
  }) {
    _isConverging = true;
    _isCoasting = false;
    _convergenceStartMs = nowMs;
    _convergenceDurationMs = durationMs;
    _convStartLat = _lastKnownLat;
    _convStartLng = _lastKnownLng;
    _convTargetGpsLat = gpsLat;
    _convTargetGpsLng = gpsLng;
    _convGpsSpeedKmh = gpsSpeedKmh;
    _convGpsHeading = gpsHeading;
  }

  /// Updates the target GPS coordinates during an active convergence window.
  void updateConvergenceTarget({
    required double gpsLat,
    required double gpsLng,
    required double gpsSpeedKmh,
    required double gpsHeading,
  }) {
    _convTargetGpsLat = gpsLat;
    _convTargetGpsLng = gpsLng;
    _convGpsSpeedKmh = gpsSpeedKmh;
    _convGpsHeading = gpsHeading;
  }

  /// Computes the current convergence coordinate at [nowMs].
  ConvergencePoint computeConvergence(int nowMs) {
    if (!_isConverging) {
      return ConvergencePoint(
        lat: _convTargetGpsLat,
        lng: _convTargetGpsLng,
        speedKmh: _convGpsSpeedKmh,
        heading: _convGpsHeading,
        distanceM: 0.0,
        isCompleted: true,
      );
    }
    final elapsedMs = nowMs - _convergenceStartMs;
    final blendFactor = (elapsedMs / _convergenceDurationMs).clamp(0.0, 1.0);
    final point = convergeToGps(
      coastedLat: _convStartLat,
      coastedLng: _convStartLng,
      gpsLat: _convTargetGpsLat,
      gpsLng: _convTargetGpsLng,
      blendFactor: blendFactor,
      gpsSpeedKmh: _convGpsSpeedKmh,
      gpsHeading: _convGpsHeading,
    );
    if (point.isCompleted) {
      _isConverging = false;
      _lastKnownLat = point.lat;
      _lastKnownLng = point.lng;
    }
    return point;
  }

  /// Terminates convergence session immediately.
  void finishConvergence() {
    _isConverging = false;
  }

  /// Smoothly converges coasted coordinate towards newly acquired GPS fix over time,
  /// preventing map avatars from abruptly snapping across the screen upon tunnel exit.
  static ConvergencePoint convergeToGps({
    required double coastedLat,
    required double coastedLng,
    required double gpsLat,
    required double gpsLng,
    required double blendFactor,
    required double gpsSpeedKmh,
    required double gpsHeading,
  }) {
    final dist = GeoMath.haversine(coastedLat, coastedLng, gpsLat, gpsLng);
    if (dist < 3.0 || blendFactor >= 1.0) {
      return ConvergencePoint(
        lat: gpsLat,
        lng: gpsLng,
        speedKmh: gpsSpeedKmh,
        heading: gpsHeading,
        distanceM: dist,
        isCompleted: true,
      );
    }
    final factor = blendFactor.clamp(0.0, 1.0);
    final lat = coastedLat + (gpsLat - coastedLat) * factor;
    final lng = coastedLng + (gpsLng - coastedLng) * factor;
    return ConvergencePoint(
      lat: lat,
      lng: lng,
      speedKmh: gpsSpeedKmh,
      heading: gpsHeading,
      distanceM: dist,
      isCompleted: false,
    );
  }

  /// Proactive GPS blackout & canyon shadow detector.
  /// Activates when GPS position reports accuracy > 50m, or no GPS fix is received
  /// for > 3 seconds while moving (> 15 km/h) near a tunnel portal or along an active route.
  static bool shouldInitiateCoasting({
    required double fixAgeSec,
    required double accuracyM,
    required double lat,
    required double lng,
    double speedKmh = 0.0,
    bool hasActiveRoute = false,
  }) {
    if (speedKmh <= 15.0) return false;
    if (isNearTunnelPortal(lat, lng) || hasActiveRoute) {
      if (accuracyM > 50.0 || fixAgeSec > 3.0) {
        return true;
      }
    }
    if (fixAgeSec < 3.5 && accuracyM <= 80.0) return false;
    if (isNearTunnelPortal(lat, lng)) return true;
    if (fixAgeSec >= 4.0 && accuracyM > 80.0 && speedKmh >= 10.0) return true;
    return false;
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
    distanceM,
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
