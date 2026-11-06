import 'dart:math' as math;

/// Priority levels for the durable event queue.
/// Lower integer value indicates higher dispatch priority.
/// Emergency/SOS events MUST synchronize before ordinary GPS/analytics.
enum EventPriority {
  /// Emergency SOS, Crash Alarms, Wearable Airbag Deployments (Priority 0: ALWAYS first)
  critical(0),

  /// Trip Completion, Convoy State Dissolution, Emergency Responder Updates (Priority 1)
  high(1),

  /// Ordinary GPS trail records, Breadcrumbs, Speed Telemetry (Priority 2)
  normal(2),

  /// Ride statistics, Analytics, Diagnostics, Low-priority logs (Priority 3)
  low(3);

  final int value;
  const EventPriority(this.value);

  static EventPriority fromValue(int val) {
    switch (val) {
      case 0:
        return EventPriority.critical;
      case 1:
        return EventPriority.high;
      case 2:
        return EventPriority.normal;
      case 3:
      default:
        return EventPriority.low;
    }
  }

  bool isHigherOrEqualPriorityThan(EventPriority other) => value <= other.value;
}

/// Category of the queued durable event.
enum DurableEventType {
  sos,
  crashIncident,
  tripCompletion,
  gpsTrail,
  analytics;

  String get wireName {
    switch (this) {
      case DurableEventType.sos:
        return 'SOS';
      case DurableEventType.crashIncident:
        return 'CRASH_INCIDENT';
      case DurableEventType.tripCompletion:
        return 'TRIP_COMPLETION';
      case DurableEventType.gpsTrail:
        return 'GPS_TRAIL';
      case DurableEventType.analytics:
        return 'ANALYTICS';
    }
  }

  static DurableEventType fromWire(String wire) {
    switch (wire.toUpperCase()) {
      case 'SOS':
        return DurableEventType.sos;
      case 'CRASH_INCIDENT':
        return DurableEventType.crashIncident;
      case 'TRIP_COMPLETION':
        return DurableEventType.tripCompletion;
      case 'GPS_TRAIL':
        return DurableEventType.gpsTrail;
      case 'ANALYTICS':
      default:
        return DurableEventType.analytics;
    }
  }
}

/// Synchronization lifecycle state of an event in the durable queue.
enum EventSyncStatus {
  pending(0),
  inFlight(1),
  synced(2),
  failedPermanent(3);

  final int code;
  const EventSyncStatus(this.code);

  static EventSyncStatus fromCode(int code) {
    switch (code) {
      case 0:
        return EventSyncStatus.pending;
      case 1:
        return EventSyncStatus.inFlight;
      case 2:
        return EventSyncStatus.synced;
      case 3:
        return EventSyncStatus.failedPermanent;
      default:
        return EventSyncStatus.pending;
    }
  }
}

/// Computes the exponential backoff delay in milliseconds based on retry count.
/// Emergency/critical events use an aggressive retry profile with lower initial latency.
int calculateExponentialBackoffMs(int retryCount, {EventPriority priority = EventPriority.normal}) {
  if (retryCount <= 0) return 0;

  if (priority == EventPriority.critical) {
    // Critical: 500ms, 1000ms, 2000ms, 4000ms, 8000ms, max 15000ms
    final exp = math.min(retryCount - 1, 5);
    final delay = 500 * math.pow(2, exp).toInt();
    return math.min(delay, 15000);
  } else {
    // Normal / High: 1000ms, 2000ms, 4000ms, 8000ms, 16000ms, max 60000ms
    final exp = math.min(retryCount - 1, 6);
    final delay = 1000 * math.pow(2, exp).toInt();
    return math.min(delay, 60000);
  }
}

/// A durable event stored locally on device that survives process kill and device reboot.
class DurableEvent {
  final int? id;
  final String eventId;
  final String idempotencyKey;
  final DurableEventType eventType;
  final EventPriority priority;
  final String groupId;
  final Map<String, dynamic> payload;
  final int createdAt;
  final int retryCount;
  final int nextRetryAt;
  final EventSyncStatus status;
  final String? lastError;

  const DurableEvent({
    this.id,
    required this.eventId,
    required this.idempotencyKey,
    required this.eventType,
    required this.priority,
    required this.groupId,
    required this.payload,
    required this.createdAt,
    this.retryCount = 0,
    this.nextRetryAt = 0,
    this.status = EventSyncStatus.pending,
    this.lastError,
  });

  DurableEvent copyWith({
    int? id,
    String? eventId,
    String? idempotencyKey,
    DurableEventType? eventType,
    EventPriority? priority,
    String? groupId,
    Map<String, dynamic>? payload,
    int? createdAt,
    int? retryCount,
    int? nextRetryAt,
    EventSyncStatus? status,
    String? lastError,
  }) {
    return DurableEvent(
      id: id ?? this.id,
      eventId: eventId ?? this.eventId,
      idempotencyKey: idempotencyKey ?? this.idempotencyKey,
      eventType: eventType ?? this.eventType,
      priority: priority ?? this.priority,
      groupId: groupId ?? this.groupId,
      payload: payload ?? this.payload,
      createdAt: createdAt ?? this.createdAt,
      retryCount: retryCount ?? this.retryCount,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
      status: status ?? this.status,
      lastError: lastError ?? this.lastError,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'eventId': eventId,
        'idempotencyKey': idempotencyKey,
        'eventType': eventType.wireName,
        'priority': priority.value,
        'groupId': groupId,
        'payload': payload,
        'createdAt': createdAt,
        'retryCount': retryCount,
        'nextRetryAt': nextRetryAt,
        'status': status.code,
        if (lastError != null) 'lastError': lastError,
      };

  factory DurableEvent.fromJson(Map<String, dynamic> json) {
    return DurableEvent(
      id: json['id'] as int?,
      eventId: json['eventId'] as String,
      idempotencyKey: json['idempotencyKey'] as String,
      eventType: DurableEventType.fromWire(json['eventType'] as String? ?? 'ANALYTICS'),
      priority: EventPriority.fromValue(json['priority'] as int? ?? 2),
      groupId: json['groupId'] as String? ?? '',
      payload: json['payload'] is Map ? Map<String, dynamic>.from(json['payload'] as Map) : <String, dynamic>{},
      createdAt: json['createdAt'] as int? ?? 0,
      retryCount: json['retryCount'] as int? ?? 0,
      nextRetryAt: json['nextRetryAt'] as int? ?? 0,
      status: EventSyncStatus.fromCode(json['status'] as int? ?? 0),
      lastError: json['lastError'] as String?,
    );
  }

  @override
  String toString() =>
      'DurableEvent(id: $id, eventId: $eventId, key: $idempotencyKey, type: ${eventType.wireName}, priority: ${priority.name}, retries: $retryCount, status: ${status.name})';
}
