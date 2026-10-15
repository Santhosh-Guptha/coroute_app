/// Represents a peer-to-peer telemetry and safety packet exchanged directly
/// between motorcycle riders over offline wireless mesh (e.g. UDP broadcast / BLE).
class MeshTelemetryPacket {
  static const int currentVersion = 1;
  static const int magicByte1 = 0x43; // 'C'
  static const int magicByte2 = 0x52; // 'R'

  final int version;

  /// 16-bit CRC or hash of the convoy's join code (e.g. "HAWK7").
  /// Ensures only riders in the same active convoy process the packet.
  final int joinCodeHash;

  final String userId;
  final String userName;
  final double lat;
  final double lng;
  final double speedKmh;
  final double heading;
  final int batteryLevel;
  final bool isCharging;
  final String role; // 'LEAD', 'SWEEPER', 'PACK'

  /// Safety & distress beacon flags
  final bool isSos;
  final String sosType; // 'CRASH', 'BREAKDOWN', 'MEDICAL', 'STOPPED', 'CUSTOM'

  /// Mesh multi-hop routing
  final int seq;
  final int ttl; // Time-to-live (max hops remaining)
  final int hopCount; // Hops taken so far (0 = direct single-hop)
  final int timestampMs;
  final double? fuelUsableKm;

  const MeshTelemetryPacket({
    this.version = currentVersion,
    required this.joinCodeHash,
    required this.userId,
    required this.userName,
    required this.lat,
    required this.lng,
    required this.speedKmh,
    required this.heading,
    this.batteryLevel = 100,
    this.isCharging = false,
    this.role = 'PACK',
    this.isSos = false,
    this.sosType = 'CRASH',
    required this.seq,
    this.ttl = 3,
    this.hopCount = 0,
    required this.timestampMs,
    this.fuelUsableKm,
  });

  /// Whether this packet was received directly from the sender without intermediate hops.
  bool get isDirectPeer => hopCount == 0;

  /// Whether this packet was relayed across intermediate bikes.
  bool get isRelayed => hopCount > 0;

  /// Creates a copy of this packet prepared for multi-hop relay forwarding.
  MeshTelemetryPacket copyForRelay() {
    return MeshTelemetryPacket(
      version: version,
      joinCodeHash: joinCodeHash,
      userId: userId,
      userName: userName,
      lat: lat,
      lng: lng,
      speedKmh: speedKmh,
      heading: heading,
      batteryLevel: batteryLevel,
      isCharging: isCharging,
      role: role,
      isSos: isSos,
      sosType: sosType,
      seq: seq,
      ttl: ttl - 1,
      hopCount: hopCount + 1,
      timestampMs: timestampMs,
      fuelUsableKm: fuelUsableKm,
    );
  }

  /// Calculates a stable 16-bit integer hash from a join code string (e.g. "HAWK7").
  static int hashJoinCode(String joinCode) {
    var hash = 0x811C9DC5;
    final upper = joinCode.trim().toUpperCase();
    for (var i = 0; i < upper.length; i++) {
      hash ^= upper.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash & 0xFFFF;
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'joinCodeHash': joinCodeHash,
        'userId': userId,
        'userName': userName,
        'lat': lat,
        'lng': lng,
        'speedKmh': speedKmh,
        'heading': heading,
        'batteryLevel': batteryLevel,
        'isCharging': isCharging,
        'role': role,
        'isSos': isSos,
        'sosType': sosType,
        'seq': seq,
        'ttl': ttl,
        'hopCount': hopCount,
        'timestampMs': timestampMs,
        if (fuelUsableKm != null) 'fuelUsableKm': fuelUsableKm,
      };

  factory MeshTelemetryPacket.fromJson(Map<String, dynamic> json) {
    return MeshTelemetryPacket(
      version: (json['version'] as num?)?.toInt() ?? currentVersion,
      joinCodeHash: (json['joinCodeHash'] as num?)?.toInt() ?? 0,
      userId: json['userId']?.toString() ?? '',
      userName: json['userName']?.toString() ?? 'Rider',
      lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
      speedKmh: (json['speedKmh'] as num?)?.toDouble() ?? 0.0,
      heading: (json['heading'] as num?)?.toDouble() ?? 0.0,
      batteryLevel: (json['batteryLevel'] as num?)?.toInt() ?? 100,
      isCharging: json['isCharging'] == true,
      role: json['role']?.toString() ?? 'PACK',
      isSos: json['isSos'] == true,
      sosType: json['sosType']?.toString() ?? 'CRASH',
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      ttl: (json['ttl'] as num?)?.toInt() ?? 3,
      hopCount: (json['hopCount'] as num?)?.toInt() ?? 0,
      timestampMs: (json['timestampMs'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      fuelUsableKm: (json['fuelUsableKm'] as num?)?.toDouble(),
    );
  }
}
