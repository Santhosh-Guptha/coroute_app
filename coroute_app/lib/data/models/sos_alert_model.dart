import 'medical_info.dart';
import 'network_models.dart';
import 'network_wire.dart';
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

  // ---- 3.15 EmergencyEvent fields (all optional; a 3.14 gateway sends none of them).
  /// Server status; null from an older gateway (see [effectiveStatus]).
  final EmergencyStatus? status;
  final EmergencySource? source;
  final EmergencySeverity? severity;

  /// Last known heading (degrees), speed (km/h) and GPS accuracy (m) of the rider.
  final double? heading;
  final double? speedKmh;
  final double? accuracyM;

  /// Last time the rider's position or the status changed (epoch ms).
  final int? lastUpdateAt;

  /// Who reported it, for a "Rider down" report by another rider ('' otherwise).
  final String reportedBy;
  final String reportedByName;

  /// The search for nearby riders (memory only on the server, sent while open).
  final EmergencyNetwork? network;

  /// The nearest rider of my group to the emergency.
  final OwnNearest? ownNearest;

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
    this.status,
    this.source,
    this.severity,
    this.heading,
    this.speedKmh,
    this.accuracyM,
    this.lastUpdateAt,
    this.reportedBy = '',
    this.reportedByName = '',
    this.network,
    this.ownNearest,
  }) : occurredAt = occurredAt ?? timestamp;

  bool get isCrash => alertType == SosTypes.crash;

  /// The status, or for an alert from an older gateway: resolved, else assistance requested.
  EmergencyStatus get effectiveStatus => status ?? (resolved ? EmergencyStatus.resolved : EmergencyStatus.assistanceRequested);

  /// Where it came from; for an older alert: crash detection when automatic, else manual.
  EmergencySource get effectiveSource => source ?? (auto ? EmergencySource.crashAuto : EmergencySource.manual);

  /// Most recent known time of the rider's position ([lastUpdateAt], else the raise time).
  int get lastKnownAt => lastUpdateAt ?? timestamp;

  /// A (possible) accident: crash, crash detection or a rider reported down.
  bool get isAccident =>
      alertType == SosTypes.crash || alertType == SosTypes.riderDown || effectiveSource == EmergencySource.crashAuto || effectiveSource == EmergencySource.needHelp;

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
    EmergencyStatus? status,
    EmergencySource? source,
    EmergencySeverity? severity,
    double? heading,
    double? speedKmh,
    double? accuracyM,
    int? lastUpdateAt,
    String? reportedBy,
    String? reportedByName,
    EmergencyNetwork? network,
    OwnNearest? ownNearest,
    bool clearOwnNearest = false,
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
      status: status ?? this.status,
      source: source ?? this.source,
      severity: severity ?? this.severity,
      heading: heading ?? this.heading,
      speedKmh: speedKmh ?? this.speedKmh,
      accuracyM: accuracyM ?? this.accuracyM,
      lastUpdateAt: lastUpdateAt ?? this.lastUpdateAt,
      reportedBy: reportedBy ?? this.reportedBy,
      reportedByName: reportedByName ?? this.reportedByName,
      network: network ?? this.network,
      ownNearest: clearOwnNearest ? null : (ownNearest ?? this.ownNearest),
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
      'status': ?status?.wire,
      'source': ?source?.wire,
      'severity': ?severity?.wire,
      'heading': ?heading,
      'speedKmh': ?speedKmh,
      'accuracyM': ?accuracyM,
      'lastUpdateAt': ?lastUpdateAt,
      if (reportedBy.isNotEmpty) 'reportedBy': reportedBy,
      if (reportedByName.isNotEmpty) 'reportedByName': reportedByName,
      'network': ?network?.toJson(),
      'ownNearest': ?ownNearest?.toJson(),
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
      status: EmergencyStatus.fromWire(json['status']?.toString()),
      source: EmergencySource.fromWire(json['source']?.toString()),
      severity: EmergencySeverity.fromWire(json['severity']?.toString()),
      heading: toD(json['heading']),
      speedKmh: toD(json['speedKmh']),
      accuracyM: toD(json['accuracyM']),
      lastUpdateAt: toD(json['lastUpdateAt'])?.toInt(),
      reportedBy: json['reportedBy']?.toString() ?? '',
      reportedByName: json['reportedByName']?.toString() ?? '',
      network: EmergencyNetwork.fromJson(json['network']),
      ownNearest: OwnNearest.fromJson(json['ownNearest']),
    );
  }
}
