import 'dart:math' as math;

/// Classifications of road anomalies detected through inertial and kinematic sensors.
enum RoadHazardClassification {
  /// Localized depression or hole in road surface with vertical drop and handlebar twitch.
  pothole,

  /// Raised asphalt ridge, sharp pavement displacement, or broken expansion joint.
  severeRidge,

  /// Transverse joint, bridge plate, or railway line across both wheels with minimal yaw.
  transverseJoint,

  /// Intentional traffic calming speed breaker or tabletop humps.
  speedBreaker,

  /// Anomalies that cannot be conclusively separated into physical potholes with inertial
  /// sensors alone (e.g. potential surface slick, loose gravel patches, manhole covers).
  uncertainSurfaceAnomaly;

  String get wireName => switch (this) {
        pothole => 'POTHOLE',
        severeRidge => 'SEVERE_RIDGE',
        transverseJoint => 'TRANSVERSE_JOINT',
        speedBreaker => 'SPEED_BREAKER',
        uncertainSurfaceAnomaly => 'UNCERTAIN_SURFACE_ANOMALY',
      };

  static RoadHazardClassification fromWire(String? s) {
    switch (s?.toUpperCase()) {
      case 'POTHOLE':
        return pothole;
      case 'SEVERE_RIDGE':
        return severeRidge;
      case 'TRANSVERSE_JOINT':
        return transverseJoint;
      case 'SPEED_BREAKER':
        return speedBreaker;
      default:
        return uncertainSurfaceAnomaly;
    }
  }
}

/// Severity level of the road hazard based on impact peak and speed.
enum RoadHazardSeverity {
  low,
  medium,
  high,
  critical;

  String get wireName => switch (this) {
        low => 'LOW',
        medium => 'MEDIUM',
        high => 'HIGH',
        critical => 'CRITICAL',
      };

  static RoadHazardSeverity fromWire(String? s) {
    switch (s?.toUpperCase()) {
      case 'LOW':
        return low;
      case 'MEDIUM':
        return medium;
      case 'CRITICAL':
        return critical;
      case 'HIGH':
      default:
        return high;
    }
  }
}

/// A high-frequency inertial sensor reading containing 3-axis acceleration and gyro angular rates.
class KinematicSample {
  final int timestampMs;
  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;

  const KinematicSample({
    required this.timestampMs,
    required this.ax,
    required this.ay,
    required this.az,
    this.gx = 0.0,
    this.gy = 0.0,
    this.gz = 0.0,
  });

  /// Total acceleration magnitude in m/s^2.
  double get totalAccel => math.sqrt(ax * ax + ay * ay + az * az);

  /// Total acceleration magnitude in g (1g = 9.80665 m/s^2).
  double get totalAccelG => totalAccel / 9.80665;
}

/// An accepted, validated observation of a road surface hazard tagged with telemetry.
class RoadHazardObservation {
  final String eventId;
  final int timestamp;
  final double lat;
  final double lng;
  final double accuracyM;
  final double speedKmh;
  final double heading;
  final double peakVerticalG;
  final double peakYawRateDegS;
  final double confidence;
  final RoadHazardSeverity severity;
  final RoadHazardClassification classification;
  final String pseudonymousRiderId;
  final String schemaVersion;

  const RoadHazardObservation({
    required this.eventId,
    required this.timestamp,
    required this.lat,
    required this.lng,
    required this.accuracyM,
    required this.speedKmh,
    required this.heading,
    required this.peakVerticalG,
    required this.peakYawRateDegS,
    required this.confidence,
    required this.severity,
    required this.classification,
    this.pseudonymousRiderId = '',
    this.schemaVersion = '2.0',
  });

  RoadHazardObservation copyWith({
    String? eventId,
    int? timestamp,
    double? lat,
    double? lng,
    double? accuracyM,
    double? speedKmh,
    double? heading,
    double? peakVerticalG,
    double? peakYawRateDegS,
    double? confidence,
    RoadHazardSeverity? severity,
    RoadHazardClassification? classification,
    String? pseudonymousRiderId,
    String? schemaVersion,
  }) {
    return RoadHazardObservation(
      eventId: eventId ?? this.eventId,
      timestamp: timestamp ?? this.timestamp,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      accuracyM: accuracyM ?? this.accuracyM,
      speedKmh: speedKmh ?? this.speedKmh,
      heading: heading ?? this.heading,
      peakVerticalG: peakVerticalG ?? this.peakVerticalG,
      peakYawRateDegS: peakYawRateDegS ?? this.peakYawRateDegS,
      confidence: confidence ?? this.confidence,
      severity: severity ?? this.severity,
      classification: classification ?? this.classification,
      pseudonymousRiderId: pseudonymousRiderId ?? this.pseudonymousRiderId,
      schemaVersion: schemaVersion ?? this.schemaVersion,
    );
  }

  Map<String, dynamic> toJson() => {
        'type': 'ROAD_HAZARD',
        'hazardId': eventId,
        'timestamp': timestamp,
        'lat': lat,
        'lng': lng,
        'accuracyM': accuracyM,
        'speedKmh': speedKmh,
        'heading': heading,
        'peakVerticalG': double.parse(peakVerticalG.toStringAsFixed(2)),
        'peakYawRateDegS': double.parse(peakYawRateDegS.toStringAsFixed(1)),
        'confidence': double.parse(confidence.toStringAsFixed(2)),
        'severity': severity.wireName,
        'classification': classification.wireName,
        'pseudonymousRiderId': pseudonymousRiderId,
        'schemaVersion': schemaVersion,
      };

  factory RoadHazardObservation.fromJson(Map<String, dynamic> j) {
    return RoadHazardObservation(
      eventId: j['hazardId']?.toString() ?? j['eventId']?.toString() ?? '',
      timestamp: (j['timestamp'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      lat: (j['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (j['lng'] as num?)?.toDouble() ?? 0.0,
      accuracyM: (j['accuracyM'] as num?)?.toDouble() ?? 0.0,
      speedKmh: (j['speedKmh'] as num?)?.toDouble() ?? 0.0,
      heading: (j['heading'] as num?)?.toDouble() ?? 0.0,
      peakVerticalG: (j['peakVerticalG'] as num?)?.toDouble() ?? 0.0,
      peakYawRateDegS: (j['peakYawRateDegS'] as num?)?.toDouble() ?? 0.0,
      confidence: (j['confidence'] as num?)?.toDouble() ?? 0.0,
      severity: RoadHazardSeverity.fromWire(j['severity']?.toString()),
      classification: RoadHazardClassification.fromWire(j['classification']?.toString()),
      pseudonymousRiderId: j['pseudonymousRiderId']?.toString() ?? '',
      schemaVersion: j['schemaVersion']?.toString() ?? '2.0',
    );
  }
}
