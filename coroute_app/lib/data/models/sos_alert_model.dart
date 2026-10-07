class SosAlertModel {
  final String alertId;
  final String userId;
  final String userName;
  final double lat;
  final double lng;
  final String alertType; // 'CRASH', 'MEDICAL', 'MECHANICAL', 'POLICE'
  final int timestamp;
  final bool resolved;

  /// Set by the phone that raised it, so a retried SOS is recognised (empty for older alerts).
  final String clientId;

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
  });

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
    );
  }

  Map<String, dynamic> toJson() {
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
    };
  }

  factory SosAlertModel.fromJson(Map<String, dynamic> json) {
    return SosAlertModel(
      alertId: json['alertId'] ?? '',
      userId: json['userId'] ?? '',
      userName: json['userName'] ?? '',
      lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
      alertType: json['alertType'] ?? 'EMERGENCY',
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      resolved: json['resolved'] == true,
      clientId: json['clientId']?.toString() ?? '',
    );
  }
}
