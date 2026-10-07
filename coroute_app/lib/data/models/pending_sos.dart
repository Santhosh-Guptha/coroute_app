import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';

/// What happened when the rider pressed SOS.
///
/// [sent]: handed to the live connection (delivery is confirmed when the
/// server echoes the alert back). [queued]: no connection; it is kept on the
/// phone and sent as soon as the connection is back. [notInConvoy]: there is
/// no convoy to send it to.
enum SosDelivery { sent, queued, notInConvoy }

/// An SOS that the convoy has not confirmed yet. Kept in memory and on disk,
/// so it survives a dead zone and an app restart, and is sent again (with the
/// same [clientId], so the server never creates it twice) after reconnecting.
class PendingSos {
  final String clientId;
  final String groupId;
  final double lat;
  final double lng;
  final String type;
  final int createdAt;

  const PendingSos({
    required this.clientId,
    required this.groupId,
    required this.lat,
    required this.lng,
    required this.type,
    required this.createdAt,
  });

  PendingSos copyWith({double? lat, double? lng}) => PendingSos(
        clientId: clientId,
        groupId: groupId,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        type: type,
        createdAt: createdAt,
      );

  /// The message the gateway expects.
  Map<String, dynamic> toMessage() => {'type': 'SOS', 'lat': lat, 'lng': lng, 'alertType': type, 'clientId': clientId};

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'groupId': groupId,
        'lat': lat,
        'lng': lng,
        'type': type,
        'createdAt': createdAt,
      };

  static PendingSos? fromJson(Object? json) {
    if (json is! Map) return null;
    final clientId = json['clientId']?.toString() ?? '';
    final groupId = json['groupId']?.toString() ?? '';
    if (clientId.isEmpty || groupId.isEmpty) return null;
    return PendingSos(
      clientId: clientId,
      groupId: groupId,
      lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
      type: json['type']?.toString() ?? 'EMERGENCY',
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    );
  }

  String encode() => jsonEncode(toJson());

  static PendingSos? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// True when an alert echoed by the server is this SOS.
  bool matches(String? alertClientId) => alertClientId != null && alertClientId.isNotEmpty && alertClientId == clientId;
}

/// Disk copy of the pending SOS (SharedPreferences, one key).
class PendingSosStore {
  static Future<PendingSos?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return PendingSos.decode(prefs.getString(AppConstants.keyPendingSos));
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(PendingSos sos) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.keyPendingSos, sos.encode());
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(AppConstants.keyPendingSos);
    } catch (_) {}
  }
}
