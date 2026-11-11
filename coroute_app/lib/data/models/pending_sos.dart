import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';
import '../../domain/safety/emergency_texts.dart';
import 'network_wire.dart';

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

  /// Raised automatically by crash detection.
  final bool auto;

  /// Speed just before the impact (crash only).
  final double? speedBeforeKmh;

  /// Impact strength in g (crash only).
  final double? impactG;

  /// 3.15: where it came from (manual, crash detection, "Need Help", the notification...).
  final EmergencySource source;

  /// 3.15: my last known heading (degrees), speed (km/h) and GPS accuracy (m), when known.
  final double? heading;
  final double? speedKmh;
  final double? accuracyM;

  /// FEAT-04: Smartwatch biometric trauma & pulse verification payload (trauma level, BPM, history, blood group).
  final Map<String, dynamic>? biometrics;
  final String? traumaLevel;

  /// 3.56: 22 random characters for the live link in this phone's own SOS text
  /// (`https://<site>/e/<linkToken>`). Sent with the SOS as `smsLinkToken`; the gateway
  /// registers it when the SOS arrives, so the link shows the live position from then on.
  /// Empty for an SOS stored by an older version (no link in its text).
  final String linkToken;

  /// A new random link code (16 bytes, base64url without padding = 22 characters).
  static String newLinkToken([Random? random]) {
    final r = random ?? Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static final RegExp _linkTokenRe = RegExp(r'^[A-Za-z0-9_-]{22}$');

  const PendingSos({
    required this.clientId,
    required this.groupId,
    required this.lat,
    required this.lng,
    required this.type,
    required this.createdAt,
    this.auto = false,
    this.speedBeforeKmh,
    this.impactG,
    this.source = EmergencySource.manual,
    this.heading,
    this.speedKmh,
    this.accuracyM,
    this.biometrics,
    this.traumaLevel,
    this.linkToken = '',
  });

  /// The same SOS (same [clientId]) with a newer position, or upgraded to a crash.
  PendingSos copyWith({
    double? lat,
    double? lng,
    String? type,
    int? createdAt,
    bool? auto,
    double? speedBeforeKmh,
    double? impactG,
    EmergencySource? source,
    double? heading,
    double? speedKmh,
    double? accuracyM,
    Map<String, dynamic>? biometrics,
    String? traumaLevel,
  }) =>
      PendingSos(
        clientId: clientId,
        groupId: groupId,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        type: type ?? this.type,
        createdAt: createdAt ?? this.createdAt,
        auto: auto ?? this.auto,
        speedBeforeKmh: speedBeforeKmh ?? this.speedBeforeKmh,
        impactG: impactG ?? this.impactG,
        source: source ?? this.source,
        heading: heading ?? this.heading,
        speedKmh: speedKmh ?? this.speedKmh,
        accuracyM: accuracyM ?? this.accuracyM,
        biometrics: biometrics ?? this.biometrics,
        traumaLevel: traumaLevel ?? this.traumaLevel,
        linkToken: linkToken,
      );

  /// The message the gateway expects. Older gateways ignore the extra fields.
  Map<String, dynamic> toMessage() => {
        'type': 'SOS',
        'lat': lat,
        'lng': lng,
        'alertType': type,
        'clientId': clientId,
        'auto': auto,
        'occurredAt': createdAt,
        'speedBeforeKmh': ?speedBeforeKmh,
        'impactG': ?impactG,
        'source': source.wire,
        if (heading != null) 'heading': heading!.round() % 360,
        if (speedKmh != null) 'speedKmh': double.parse(speedKmh!.clamp(0.0, 300.0).toStringAsFixed(1)),
        if (accuracyM != null) 'accuracyM': accuracyM!.round().clamp(0, 5000),
        if (biometrics != null) 'biometrics': biometrics,
        if (traumaLevel != null) 'traumaLevel': traumaLevel,
        if (_linkTokenRe.hasMatch(linkToken)) 'smsLinkToken': linkToken,
      };

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'groupId': groupId,
        'lat': lat,
        'lng': lng,
        'type': type,
        'createdAt': createdAt,
        if (auto) 'auto': true,
        'speedBeforeKmh': ?speedBeforeKmh,
        'impactG': ?impactG,
        if (source != EmergencySource.manual) 'source': source.wire,
        'heading': ?heading,
        'speedKmh': ?speedKmh,
        'accuracyM': ?accuracyM,
        if (biometrics != null) 'biometrics': biometrics,
        if (traumaLevel != null) 'traumaLevel': traumaLevel,
        if (linkToken.isNotEmpty) 'linkToken': linkToken,
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
      auto: json['auto'] == true,
      speedBeforeKmh: (json['speedBeforeKmh'] as num?)?.toDouble(),
      impactG: (json['impactG'] as num?)?.toDouble(),
      source: EmergencySource.fromWire(json['source']?.toString()) ?? EmergencySource.manual,
      heading: (json['heading'] as num?)?.toDouble(),
      speedKmh: (json['speedKmh'] as num?)?.toDouble(),
      accuracyM: (json['accuracyM'] as num?)?.toDouble(),
      biometrics: (json['biometrics'] is Map) ? Map<String, dynamic>.from(json['biometrics'] as Map) : null,
      traumaLevel: json['traumaLevel']?.toString(),
      linkToken: _linkTokenRe.hasMatch(json['linkToken']?.toString() ?? '') ? json['linkToken'].toString() : '',
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

/// 3.57: the emergency text ledger, kept next to the pending SOS (same SharedPreferences): which
/// incidents were texted from this phone (number hashes only), "safe now" sent, and the send
/// times of the daily cap. The texts themselves wait in the native queue, which survives an app
/// kill on its own (EmergencyTexts.kt).
class EmergencyTextStore {
  static Future<EmergencyTextLedger> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(AppConstants.keyEmergencyTexts);
      if (raw == null || raw.isEmpty) return EmergencyTextLedger.empty();
      return EmergencyTextLedger.fromJson(jsonDecode(raw));
    } catch (_) {
      return EmergencyTextLedger.empty();
    }
  }

  static Future<void> save(EmergencyTextLedger ledger) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.keyEmergencyTexts, jsonEncode(ledger.toJson()));
    } catch (_) {}
  }
}
