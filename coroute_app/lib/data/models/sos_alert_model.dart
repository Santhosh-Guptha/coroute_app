import 'medical_info.dart';
import 'safety_wire.dart';

class SosAlertModel {
  final String alertId;
  final String userId;
  final String userName;
  final double lat;
  final double lng;
  final String alertType; // 'EMERGENCY', 'CRASH_OR_EMERGENCY', 'CRASH', 'MEDICAL', 'MECHANICAL', 'POLICE'
  final int timestamp;
  final bool resolved;

  /// Set by the phone that raised it, so a retried SOS is recognised (empty for older alerts).
  final String clientId;

  /// Raised automatically (crash detection), not by a button press.
  final bool auto;

  /// Speed just before the impact (crash alerts only).
  final double? speedBeforeKmh;

  /// Impact strength in g (crash alerts only).
  final double? impactG;

  /// When it happened on the rider's phone (epoch ms); the raise time for older alerts.
  final int occurredAt;

  /// Riders who answered "I'm going" / "I'm with them".
  final List<SosResponder> responders;

  /// The rider's medical details, sent by the gateway only while the alert is open.
  final MedicalInfo? medical;

  SosAlertModel({
    required this.alertId,
    required this.userId,
    required this.userName,
    required this.lat,
    required this.lng,
    this.alertType = 'EMERGENCY',
    required this.timestamp,
    this.resolved = false,
    this.clientId = '',
    this.auto = false,
    this.speedBeforeKmh,
    this.impactG,
    int? occurredAt,
    this.responders = const [],
    this.medical,
  }) : occurredAt = occurredAt ?? timestamp;

  bool get isCrash => alertType == SosTypes.crash;

  SosAlertModel copyWith({
    String? alertId,
    String? userId,
    String? userName,
    double? lat,
    double? lng,
    String? alertType,
    int? timestamp,
    bool? resolved,
    String? clientId,
    bool? auto,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAt,
    List<SosResponder>? responders,
    MedicalInfo? medical,
    bool clearMedical = false,
  }) {
    return SosAlertModel(
      alertId: alertId ?? this.alertId,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      alertType: alertType ?? this.alertType,
      timestamp: timestamp ?? this.timestamp,
      resolved: resolved ?? this.resolved,
      clientId: clientId ?? this.clientId,
      auto: auto ?? this.auto,
      speedBeforeKmh: speedBeforeKmh ?? this.speedBeforeKmh,
      impactG: impactG ?? this.impactG,
      occurredAt: occurredAt ?? this.occurredAt,
      responders: responders ?? this.responders,
      medical: clearMedical ? null : (medical ?? this.medical),
    );
  }

  Map<String, dynamic> toJson() {
    final med = medical;
    return {
      'alertId': alertId,
      'userId': userId,
      'userName': userName,
      'lat': lat,
      'lng': lng,
      'alertType': alertType,
      'timestamp': timestamp,
      'resolved': resolved,
      if (clientId.isNotEmpty) 'clientId': clientId,
      if (auto) 'auto': true,
      if (speedBeforeKmh != null || impactG != null)
        'details': {'speedBeforeKmh': ?speedBeforeKmh, 'impactG': ?impactG},
      'occurredAt': occurredAt,
      if (responders.isNotEmpty) 'responders': [for (final r in responders) r.toJson()],
      if (med != null && !med.isEmpty) 'medical': med.toJson(),
    };
  }

  factory SosAlertModel.fromJson(Map<String, dynamic> json) {
    final details = json['details'] is Map ? Map<String, dynamic>.from(json['details'] as Map) : const <String, dynamic>{};
    double? toD(Object? v) => v is num ? v.toDouble() : null;
    final timestamp = (json['timestamp'] as num?)?.toInt() ?? 0;
    return SosAlertModel(
      alertId: json['alertId'] ?? '',
      userId: json['userId'] ?? '',
      userName: json['userName'] ?? '',
      lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
      alertType: json['alertType'] ?? 'EMERGENCY',
      timestamp: timestamp,
      resolved: json['resolved'] == true,
      clientId: json['clientId']?.toString() ?? '',
      auto: json['auto'] == true,
      speedBeforeKmh: toD(details['speedBeforeKmh']) ?? toD(json['speedBeforeKmh']),
      impactG: toD(details['impactG']) ?? toD(json['impactG']),
      occurredAt: (json['occurredAt'] as num?)?.toInt() ?? timestamp,
      responders: SosResponder.listFrom(json['responders']),
      medical: MedicalInfo.fromJson(json['medical']),
    );
  }
}
