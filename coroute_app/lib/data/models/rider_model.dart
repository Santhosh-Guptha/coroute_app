import 'safety_wire.dart';

class RiderModel {
  final String userId;
  final String name;
  final String vehicleType;
  final String vehicleColor;
  final double lat;
  final double lng;
  final double speedKmh;
  final double heading;
  final int batteryLevel;
  final bool isCharging;
  final String role; // 'LEAD', 'SWEEPER', 'PACK'
  final String statusReason; // '', 'FUELING', 'REST_BREAK', 'MECHANICAL', 'FLAT_TIRE', 'TRAFFIC', 'RAIN_DELAY', 'PHOTO_STOP', 'MEDICAL', 'REGROUP', 'CUSTOM'
  final String statusMessage;
  final int lastSeenEpochMs;
  final String phone;
  final String emergencyContact;
  final String emergencyContactName;
  final String vehicleNo;
  final bool isCoRiding;
  final String ridingWithUserId;
  final int stoppedSince;

  /// Server presence: '', ONLINE, NO_SIGNAL or APP_CLOSED (empty from older gateways).
  final String presence;

  /// When [presence] last changed (epoch ms, 0 when unknown).
  final int presenceAt;

  RiderPresence get presenceState => RiderPresence.fromWire(presence);

  RiderModel({
    required this.userId,
    required this.name,
    this.vehicleType = 'Motorcycle',
    this.vehicleColor = 'Black',
    required this.lat,
    required this.lng,
    this.speedKmh = 0.0,
    this.heading = 0.0,
    this.batteryLevel = 100,
    this.isCharging = false,
    this.role = 'PACK',
    this.statusReason = '',
    this.statusMessage = '',
    required this.lastSeenEpochMs,
    this.phone = '',
    this.emergencyContact = '',
    this.emergencyContactName = '',
    this.vehicleNo = '',
    this.isCoRiding = false,
    this.ridingWithUserId = '',
    this.stoppedSince = 0,
    this.presence = '',
    this.presenceAt = 0,
  });

  RiderModel copyWith({
    String? userId,
    String? name,
    String? vehicleType,
    String? vehicleColor,
    double? lat,
    double? lng,
    double? speedKmh,
    double? heading,
    int? batteryLevel,
    bool? isCharging,
    String? role,
    String? statusReason,
    String? statusMessage,
    int? lastSeenEpochMs,
    String? phone,
    String? emergencyContact,
    String? emergencyContactName,
    String? vehicleNo,
    bool? isCoRiding,
    String? ridingWithUserId,
    int? stoppedSince,
    String? presence,
    int? presenceAt,
  }) {
    return RiderModel(
      userId: userId ?? this.userId,
      name: name ?? this.name,
      vehicleType: vehicleType ?? this.vehicleType,
      vehicleColor: vehicleColor ?? this.vehicleColor,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      speedKmh: speedKmh ?? this.speedKmh,
      heading: heading ?? this.heading,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      isCharging: isCharging ?? this.isCharging,
      role: role ?? this.role,
      statusReason: statusReason ?? this.statusReason,
      statusMessage: statusMessage ?? this.statusMessage,
      lastSeenEpochMs: lastSeenEpochMs ?? this.lastSeenEpochMs,
      phone: phone ?? this.phone,
      emergencyContact: emergencyContact ?? this.emergencyContact,
      emergencyContactName: emergencyContactName ?? this.emergencyContactName,
      vehicleNo: vehicleNo ?? this.vehicleNo,
      isCoRiding: isCoRiding ?? this.isCoRiding,
      ridingWithUserId: ridingWithUserId ?? this.ridingWithUserId,
      stoppedSince: stoppedSince ?? this.stoppedSince,
      presence: presence ?? this.presence,
      presenceAt: presenceAt ?? this.presenceAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'name': name,
      'vehicleType': vehicleType,
      'vehicleColor': vehicleColor,
      'lat': lat,
      'lng': lng,
      'speedKmh': speedKmh,
      'heading': heading,
      'batteryLevel': batteryLevel,
      'isCharging': isCharging,
      'role': role,
      'statusReason': statusReason,
      'statusMessage': statusMessage,
      'lastSeenEpochMs': lastSeenEpochMs,
      'phone': phone,
      'emergencyContact': emergencyContact,
      'emergencyContactName': emergencyContactName,
      'vehicleNo': vehicleNo,
      'isCoRiding': isCoRiding,
      'ridingWithUserId': ridingWithUserId,
      'stoppedSince': stoppedSince,
      if (presence.isNotEmpty) 'presence': presence,
      if (presenceAt > 0) 'presenceAt': presenceAt,
    };
  }

  factory RiderModel.fromJson(Map<String, dynamic> json) {
    return RiderModel(
      userId: json['userId'] ?? '',
      name: json['name'] ?? '',
      vehicleType: json['vehicleType'] ?? 'Motorcycle',
      vehicleColor: json['vehicleColor'] ?? 'Black',
      lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
      speedKmh: (json['speedKmh'] as num?)?.toDouble() ?? 0.0,
      heading: (json['heading'] as num?)?.toDouble() ?? 0.0,
      batteryLevel: (json['batteryLevel'] as num?)?.toInt() ?? 100,
      isCharging: json['isCharging'] ?? false,
      role: json['role'] ?? 'PACK',
      statusReason: json['statusReason'] ?? '',
      statusMessage: json['statusMessage'] ?? '',
      lastSeenEpochMs: (json['lastSeenEpochMs'] as num?)?.toInt() ?? 0,
      phone: json['phone'] ?? '',
      emergencyContact: json['emergencyContact'] ?? '',
      emergencyContactName: json['emergencyContactName'] ?? '',
      vehicleNo: json['vehicleNo'] ?? '',
      isCoRiding: json['isCoRiding'] ?? false,
      ridingWithUserId: json['ridingWithUserId'] ?? '',
      stoppedSince: (json['stoppedSince'] as num?)?.toInt() ?? 0,
      presence: json['presence']?.toString() ?? '',
      presenceAt: (json['presenceAt'] as num?)?.toInt() ?? 0,
    );
  }
}
