import 'dart:typed_data';
import 'sos_packet_codec.dart';

/// Explicit lifecycle states for emergency SOS delivery.
enum SosDeliveryState {
  /// Event instantiated in memory.
  created('CREATED', 'Created'),

  /// Persisted to local queue; ready for transmission.
  queued('QUEUED', 'Queued in Buffer'),

  /// Transmission attempt in-flight.
  attempting('ATTEMPTING', 'Attempting Transmission'),

  /// Zero cellular connectivity; user handoff to 112 / Satellite Assistant required.
  handoffRequired('HANDOFF_REQUIRED', 'Handoff Required'),

  /// Provider or remote gateway acknowledged packet ingestion.
  providerAccepted('PROVIDER_ACCEPTED', 'Accepted by Provider'),

  /// End-to-end receipt explicitly confirmed by emergency dispatch or server echo.
  deliveredIfConfirmedByProvider('DELIVERED_CONFIRMED', 'Confirmed Delivered'),

  /// Transmission attempt failed; pending retry or fallback.
  failed('FAILED', 'Failed / Retrying'),

  /// Time-to-live expired (e.g., > 24 hours).
  expired('EXPIRED', 'Expired'),

  /// Cancelled by user.
  cancelled('CANCELLED', 'Cancelled');

  final String wire;
  final String label;

  const SosDeliveryState(this.wire, this.label);

  bool get isTerminal =>
      this == SosDeliveryState.deliveredIfConfirmedByProvider ||
      this == SosDeliveryState.expired ||
      this == SosDeliveryState.cancelled;

  bool get isPending =>
      this == SosDeliveryState.queued ||
      this == SosDeliveryState.attempting ||
      this == SosDeliveryState.failed ||
      this == SosDeliveryState.handoffRequired;

  bool get isSuccessful =>
      this == SosDeliveryState.providerAccepted ||
      this == SosDeliveryState.deliveredIfConfirmedByProvider;

  static SosDeliveryState fromWire(String wire) {
    for (final state in SosDeliveryState.values) {
      if (state.wire == wire) return state;
    }
    return SosDeliveryState.created;
  }
}

/// Result of an emergency SOS transmission attempt.
class SosTransmissionResult {
  final bool success;
  final SosDeliveryState state;
  final String providerId;
  final String? message;
  final bool isSimulated;
  final DateTime timestamp;

  const SosTransmissionResult({
    required this.success,
    required this.state,
    required this.providerId,
    this.message,
    this.isSimulated = false,
    required this.timestamp,
  });

  factory SosTransmissionResult.accepted({
    required String providerId,
    String? message,
    bool isSimulated = false,
  }) =>
      SosTransmissionResult(
        success: true,
        state: SosDeliveryState.providerAccepted,
        providerId: providerId,
        message: message,
        isSimulated: isSimulated,
        timestamp: DateTime.now().toUtc(),
      );

  factory SosTransmissionResult.handoffRequired({
    required String providerId,
    String? message,
    bool isSimulated = false,
  }) =>
      SosTransmissionResult(
        success: true,
        state: SosDeliveryState.handoffRequired,
        providerId: providerId,
        message: message,
        isSimulated: isSimulated,
        timestamp: DateTime.now().toUtc(),
      );

  factory SosTransmissionResult.failed({
    required String providerId,
    required String reason,
    bool isSimulated = false,
  }) =>
      SosTransmissionResult(
        success: false,
        state: SosDeliveryState.failed,
        providerId: providerId,
        message: reason,
        isSimulated: isSimulated,
        timestamp: DateTime.now().toUtc(),
      );
}

/// Complete SOS Event model representing a distress lifecycle.
class SosEvent {
  final String id;
  final double latitude;
  final double longitude;
  final double? altitudeMeters;
  final DateTime timestamp;
  final SosSeverity severity;
  final String? bloodGroup;
  final SosDeliveryState deliveryState;
  final int retryCount;
  final DateTime? lastAttemptAt;
  final String? lastProviderId;
  final bool isSimulated;
  final String? failureReason;

  const SosEvent({
    required this.id,
    required this.latitude,
    required this.longitude,
    this.altitudeMeters,
    required this.timestamp,
    this.severity = SosSeverity.manual,
    this.bloodGroup,
    this.deliveryState = SosDeliveryState.created,
    this.retryCount = 0,
    this.lastAttemptAt,
    this.lastProviderId,
    this.isSimulated = false,
    this.failureReason,
  });

  /// Encodes this event into the compact 16-byte internal binary representation.
  Uint8List toBinaryPacket() => SosPacketCodec.encode(
        latitude: latitude,
        longitude: longitude,
        altitudeMeters: altitudeMeters,
        timestamp: timestamp,
        severity: severity,
        bloodGroup: bloodGroup,
      );

  /// Human-readable coordinates formatted for Indian ERSS 112 SMS / dispatch.
  String toIndiaErssMessage() {
    final latStr = latitude.toStringAsFixed(6);
    final lngStr = longitude.toStringAsFixed(6);
    final gmaps = 'https://maps.google.com/?q=$latStr,$lngStr';
    final timeStr = '${timestamp.toUtc().toIso8601String().substring(11, 19)}Z';
    final bg = (bloodGroup != null && bloodGroup!.isNotEmpty) ? ' | Blood: $bloodGroup' : '';
    final alt = altitudeMeters != null ? ' | Alt: ${altitudeMeters!.round()}m' : '';

    return 'EMERGENCY SOS: CoRoute Rider in distress!\n'
        'Severity: ${severity.label}\n'
        'Location: $latStr, $lngStr$alt\n'
        'Map: $gmaps\n'
        'Time: $timeStr$bg';
  }

  SosEvent copyWith({
    String? id,
    double? latitude,
    double? longitude,
    double? altitudeMeters,
    DateTime? timestamp,
    SosSeverity? severity,
    String? bloodGroup,
    SosDeliveryState? deliveryState,
    int? retryCount,
    DateTime? lastAttemptAt,
    String? lastProviderId,
    bool? isSimulated,
    String? failureReason,
  }) {
    return SosEvent(
      id: id ?? this.id,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      altitudeMeters: altitudeMeters ?? this.altitudeMeters,
      timestamp: timestamp ?? this.timestamp,
      severity: severity ?? this.severity,
      bloodGroup: bloodGroup ?? this.bloodGroup,
      deliveryState: deliveryState ?? this.deliveryState,
      retryCount: retryCount ?? this.retryCount,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      lastProviderId: lastProviderId ?? this.lastProviderId,
      isSimulated: isSimulated ?? this.isSimulated,
      failureReason: failureReason ?? this.failureReason,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'lat': latitude,
        'lng': longitude,
        if (altitudeMeters != null) 'alt': altitudeMeters,
        'ts': timestamp.toIso8601String(),
        'severity': severity.code,
        if (bloodGroup != null && bloodGroup!.isNotEmpty) 'bloodGroup': bloodGroup,
        'state': deliveryState.wire,
        'retryCount': retryCount,
        if (lastAttemptAt != null) 'lastAttemptAt': lastAttemptAt!.toIso8601String(),
        if (lastProviderId != null) 'lastProviderId': lastProviderId,
        'isSimulated': isSimulated,
        if (failureReason != null) 'failureReason': failureReason,
      };

  factory SosEvent.fromJson(Map<String, dynamic> json) {
    return SosEvent(
      id: json['id'] as String? ?? 'sos_${DateTime.now().millisecondsSinceEpoch}',
      latitude: (json['lat'] as num).toDouble(),
      longitude: (json['lng'] as num).toDouble(),
      altitudeMeters: (json['alt'] as num?)?.toDouble(),
      timestamp: DateTime.parse(json['ts'] as String),
      severity: SosSeverity.fromCode(json['severity'] as int? ?? 0),
      bloodGroup: json['bloodGroup'] as String?,
      deliveryState: SosDeliveryState.fromWire(json['state'] as String? ?? 'CREATED'),
      retryCount: json['retryCount'] as int? ?? 0,
      lastAttemptAt: json['lastAttemptAt'] != null
          ? DateTime.parse(json['lastAttemptAt'] as String)
          : null,
      lastProviderId: json['lastProviderId'] as String?,
      isSimulated: json['isSimulated'] as bool? ?? false,
      failureReason: json['failureReason'] as String?,
    );
  }
}
