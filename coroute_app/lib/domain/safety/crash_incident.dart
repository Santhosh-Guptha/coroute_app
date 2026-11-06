import '../sync/durable_event.dart';

/// Lifecycle status of a locally detected crash incident.
enum IncidentStatus {
  /// Crash algorithm detected impact; local rider countdown is active.
  countdownActive,

  /// Rider confirmed "I'm OK"; false alarm suppressed, SOS not sent.
  confirmedOk,

  /// Rider tapped "Need Help" or 15s countdown expired; emergency SOS dispatched.
  dispatched,

  /// Emergency response resolved by user, convoy lead, or dispatcher.
  resolved;

  String get wireName {
    switch (this) {
      case IncidentStatus.countdownActive:
        return 'COUNTDOWN_ACTIVE';
      case IncidentStatus.confirmedOk:
        return 'CONFIRMED_OK';
      case IncidentStatus.dispatched:
        return 'DISPATCHED';
      case IncidentStatus.resolved:
        return 'RESOLVED';
    }
  }

  static IncidentStatus fromWire(String wire) {
    switch (wire.toUpperCase()) {
      case 'COUNTDOWN_ACTIVE':
        return IncidentStatus.countdownActive;
      case 'CONFIRMED_OK':
        return IncidentStatus.confirmedOk;
      case 'DISPATCHED':
        return IncidentStatus.dispatched;
      case 'RESOLVED':
      default:
        return IncidentStatus.resolved;
    }
  }
}

/// Motorcycle crash pattern scenarios recognized by Phase 2 detection.
enum CrashScenario {
  highImpactCollision,
  lowsideSlide,
  highsideFall,
  stationaryDrop,
  impactWithStillness,
  unknown;

  String get wireName {
    switch (this) {
      case CrashScenario.highImpactCollision:
        return 'HIGH_IMPACT_COLLISION';
      case CrashScenario.lowsideSlide:
        return 'LOWSIDE_SLIDE';
      case CrashScenario.highsideFall:
        return 'HIGHSIDE_FALL';
      case CrashScenario.stationaryDrop:
        return 'STATIONARY_DROP';
      case CrashScenario.impactWithStillness:
        return 'IMPACT_WITH_STILLNESS';
      case CrashScenario.unknown:
        return 'UNKNOWN';
    }
  }

  static CrashScenario fromWire(String? wire) {
    switch (wire?.toUpperCase()) {
      case 'HIGH_IMPACT_COLLISION':
        return CrashScenario.highImpactCollision;
      case 'LOWSIDE_SLIDE':
        return CrashScenario.lowsideSlide;
      case 'HIGHSIDE_FALL':
        return CrashScenario.highsideFall;
      case 'STATIONARY_DROP':
        return CrashScenario.stationaryDrop;
      case 'IMPACT_WITH_STILLNESS':
        return CrashScenario.impactWithStillness;
      default:
        return CrashScenario.unknown;
    }
  }
}

/// Movement state of rider and motorcycle.
enum MovementState {
  moving,
  stopped,
  unknown,
  degraded;

  String get wireName => name.toUpperCase();

  static MovementState fromWire(String? wire) {
    switch (wire?.toUpperCase()) {
      case 'MOVING':
        return MovementState.moving;
      case 'STOPPED':
        return MovementState.stopped;
      case 'DEGRADED':
        return MovementState.degraded;
      case 'UNKNOWN':
      default:
        return MovementState.unknown;
    }
  }
}

/// Durable local representation of a motorcycle crash or emergency incident.
class CrashIncident {
  final String incidentId;
  final int timestamp;
  final double lat;
  final double lng;
  final double impactG;
  final double speedBeforeKmh;
  final double peakGyroRadS;
  final double tiltDeg;
  final bool isSlideFall;
  final CrashScenario scenario;
  final double confidence;
  final double peakJerkGPerS;
  final String source;
  final IncidentStatus status;
  final String idempotencyKey;
  final Map<String, dynamic>? vitals;
  final int? resolvedAt;
  final String? groupId;

  const CrashIncident({
    required this.incidentId,
    required this.timestamp,
    required this.lat,
    required this.lng,
    required this.impactG,
    required this.speedBeforeKmh,
    this.peakGyroRadS = 0.0,
    this.tiltDeg = 0.0,
    this.isSlideFall = false,
    this.scenario = CrashScenario.unknown,
    this.confidence = 1.0,
    this.peakJerkGPerS = 0.0,
    required this.source,
    this.status = IncidentStatus.countdownActive,
    required this.idempotencyKey,
    this.vitals,
    this.resolvedAt,
    this.groupId,
  });

  CrashIncident copyWith({
    String? incidentId,
    int? timestamp,
    double? lat,
    double? lng,
    double? impactG,
    double? speedBeforeKmh,
    double? peakGyroRadS,
    double? tiltDeg,
    bool? isSlideFall,
    CrashScenario? scenario,
    double? confidence,
    double? peakJerkGPerS,
    String? source,
    IncidentStatus? status,
    String? idempotencyKey,
    Map<String, dynamic>? vitals,
    int? resolvedAt,
    String? groupId,
  }) {
    return CrashIncident(
      incidentId: incidentId ?? this.incidentId,
      timestamp: timestamp ?? this.timestamp,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      impactG: impactG ?? this.impactG,
      speedBeforeKmh: speedBeforeKmh ?? this.speedBeforeKmh,
      peakGyroRadS: peakGyroRadS ?? this.peakGyroRadS,
      tiltDeg: tiltDeg ?? this.tiltDeg,
      isSlideFall: isSlideFall ?? this.isSlideFall,
      scenario: scenario ?? this.scenario,
      confidence: confidence ?? this.confidence,
      peakJerkGPerS: peakJerkGPerS ?? this.peakJerkGPerS,
      source: source ?? this.source,
      status: status ?? this.status,
      idempotencyKey: idempotencyKey ?? this.idempotencyKey,
      vitals: vitals ?? this.vitals,
      resolvedAt: resolvedAt ?? this.resolvedAt,
      groupId: groupId ?? this.groupId,
    );
  }

  /// Converts this incident into a [DurableEvent] for priority queueing.
  DurableEvent toDurableEvent() {
    return DurableEvent(
      eventId: 'evt_$incidentId',
      idempotencyKey: idempotencyKey,
      eventType: DurableEventType.crashIncident,
      priority: EventPriority.critical, // Emergency events ALWAYS priority 0
      groupId: groupId ?? '',
      payload: toJson(),
      createdAt: timestamp,
      status: EventSyncStatus.pending,
    );
  }

  Map<String, dynamic> toJson() => {
        'incidentId': incidentId,
        'timestamp': timestamp,
        'lat': lat,
        'lng': lng,
        'impactG': impactG,
        'speedBeforeKmh': speedBeforeKmh,
        'peakGyroRadS': peakGyroRadS,
        'tiltDeg': tiltDeg,
        'isSlideFall': isSlideFall,
        'scenario': scenario.wireName,
        'confidence': confidence,
        'peakJerkGPerS': peakJerkGPerS,
        'source': source,
        'status': status.wireName,
        'idempotencyKey': idempotencyKey,
        if (vitals != null) 'vitals': vitals,
        if (resolvedAt != null) 'resolvedAt': resolvedAt,
        if (groupId != null) 'groupId': groupId,
      };

  factory CrashIncident.fromJson(Map<String, dynamic> json) {
    return CrashIncident(
      incidentId: json['incidentId'] as String,
      timestamp: json['timestamp'] as int? ?? 0,
      lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
      impactG: (json['impactG'] as num?)?.toDouble() ?? 0.0,
      speedBeforeKmh: (json['speedBeforeKmh'] as num?)?.toDouble() ?? 0.0,
      peakGyroRadS: (json['peakGyroRadS'] as num?)?.toDouble() ?? 0.0,
      tiltDeg: (json['tiltDeg'] as num?)?.toDouble() ?? 0.0,
      isSlideFall: json['isSlideFall'] == true,
      scenario: CrashScenario.fromWire(json['scenario'] as String?),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
      peakJerkGPerS: (json['peakJerkGPerS'] as num?)?.toDouble() ?? 0.0,
      source: json['source'] as String? ?? 'CRASH_AUTO',
      status: IncidentStatus.fromWire(json['status'] as String? ?? 'COUNTDOWN_ACTIVE'),
      idempotencyKey: json['idempotencyKey'] as String? ?? 'crash_${json['incidentId']}',
      vitals: json['vitals'] is Map ? Map<String, dynamic>.from(json['vitals'] as Map) : null,
      resolvedAt: json['resolvedAt'] as int?,
      groupId: json['groupId'] as String?,
    );
  }
}
