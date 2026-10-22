import 'dart:math' as math;
import '../../data/models/road_hazard_telemetry.dart';
import '../tracking/geo_math.dart';

/// An aggregated road hazard pin representing a physical road defect.
/// Consolidates multiple independent observations within a 100-meter road corridor.
class AggregatedRoadHazardPin {
  final String hazardId;
  final double lat;
  final double lng;
  final double heading;
  RoadHazardSeverity severity;
  RoadHazardClassification classification;
  double confidence;
  final int firstDetectedAt;
  int lastCorroboratedAt;
  int corroborationCount;
  final Set<String> contributingRiderIds;
  final List<RoadHazardObservation> rawObservations;

  AggregatedRoadHazardPin({
    required this.hazardId,
    required this.lat,
    required this.lng,
    required this.heading,
    required this.severity,
    required this.classification,
    required this.confidence,
    required this.firstDetectedAt,
    required this.lastCorroboratedAt,
    this.corroborationCount = 1,
    Set<String>? contributingRiderIds,
    List<RoadHazardObservation>? rawObservations,
  })  : contributingRiderIds = contributingRiderIds ?? <String>{},
        rawObservations = rawObservations ?? <RoadHazardObservation>[];

  Map<String, dynamic> toJson() => {
        'hazardId': hazardId,
        'lat': lat,
        'lng': lng,
        'heading': heading,
        'severity': severity.wireName,
        'classification': classification.wireName,
        'confidence': double.parse(confidence.toStringAsFixed(2)),
        'firstDetectedAt': firstDetectedAt,
        'lastCorroboratedAt': lastCorroboratedAt,
        'corroborationCount': corroborationCount,
        'distinctRiders': contributingRiderIds.length,
      };
}

/// Intelligent spatial deduplication and multi-rider corroboration aggregator.
/// Enforces the requirement of 1 hazard pin per 100 meters while preserving
/// distinct physical defects and tracking corroboration from independent riders.
class RoadHazardAggregator {
  /// Deduplication spatial radius in meters along the road segment (100m).
  final double deduplicationRadiusM;

  /// Angular tolerance in degrees for matching carriageway direction (60 degrees).
  final double directionToleranceDeg;

  /// Stale hazard expiry duration in milliseconds (default 12 hours).
  final int hazardTtlMs;

  final Map<String, AggregatedRoadHazardPin> _pins = {};

  RoadHazardAggregator({
    this.deduplicationRadiusM = 100.0,
    this.directionToleranceDeg = 60.0,
    this.hazardTtlMs = 12 * 60 * 60 * 1000,
  });

  /// All active aggregated hazard pins.
  List<AggregatedRoadHazardPin> get activePins => _pins.values.toList();

  /// Ingests a new road hazard observation.
  /// If a pin exists within 100m in the same direction, it corroborates and updates the pin.
  /// Otherwise, it creates a new distinct hazard pin.
  AggregatedRoadHazardPin ingestObservation(RoadHazardObservation obs) {
    pruneStale(obs.timestamp);

    AggregatedRoadHazardPin? match;
    double minDistance = double.infinity;

    for (final pin in _pins.values) {
      final distance = GeoMath.haversine(pin.lat, pin.lng, obs.lat, obs.lng);
      if (distance <= deduplicationRadiusM) {
        // Verify carriageway direction if headings are available.
        if (pin.heading > 0 && obs.heading > 0) {
          final diff = _angleDiff(pin.heading, obs.heading);
          if (diff > directionToleranceDeg) {
            // Opposite carriageway on a dual-lane highway; keep separate!
            continue;
          }
        }
        if (distance < minDistance) {
          minDistance = distance;
          match = pin;
        }
      }
    }

    if (match != null) {
      // Corroborate existing pin within 100m.
      match.rawObservations.add(obs);
      match.lastCorroboratedAt = obs.timestamp;

      // Only increment independent corroboration count if rider ID is distinct or non-empty.
      final isNewRider = obs.pseudonymousRiderId.isNotEmpty &&
          !match.contributingRiderIds.contains(obs.pseudonymousRiderId);
      if (isNewRider) {
        match.contributingRiderIds.add(obs.pseudonymousRiderId);
        match.corroborationCount++;
        // Boost confidence with corroborating reports.
        match.confidence = math.min(1.0, match.confidence + 0.15);
      }

      // Escalate severity if subsequent observation encountered higher impact.
      if (obs.severity.index > match.severity.index) {
        match.severity = obs.severity;
      }

      return match;
    }

    // Create a new distinct hazard pin.
    final pinId = 'pin_${obs.timestamp}_${_pins.length + 1}';
    final newPin = AggregatedRoadHazardPin(
      hazardId: pinId,
      lat: obs.lat,
      lng: obs.lng,
      heading: obs.heading,
      severity: obs.severity,
      classification: obs.classification,
      confidence: obs.confidence,
      firstDetectedAt: obs.timestamp,
      lastCorroboratedAt: obs.timestamp,
      corroborationCount: 1,
      contributingRiderIds: obs.pseudonymousRiderId.isNotEmpty ? {obs.pseudonymousRiderId} : {},
      rawObservations: [obs],
    );

    _pins[pinId] = newPin;
    return newPin;
  }

  /// Removes pins older than TTL.
  void pruneStale(int currentTimeMs) {
    _pins.removeWhere((id, pin) => currentTimeMs - pin.lastCorroboratedAt > hazardTtlMs);
  }

  static double _angleDiff(double a, double b) {
    final d = ((a - b) % 360 + 360) % 360;
    return d > 180 ? 360 - d : d;
  }
}
