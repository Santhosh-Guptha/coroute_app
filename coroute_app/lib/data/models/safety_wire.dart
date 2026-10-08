// Wire names for the 3.14 rider safety messages (shared by the app and the gateway).

/// SOS alert types the app raises.
class SosTypes {
  SosTypes._();
  static const String emergency = 'EMERGENCY', crashOrEmergency = 'CRASH_OR_EMERGENCY', crash = 'CRASH';

  /// "Rider down here" reported by another rider (3.15).
  static const String riderDown = 'RIDER_DOWN';
}

/// Timeline entry types added in 3.14.
class SafetyEventTypes {
  SafetyEventTypes._();
  static const String possibleIncident = 'POSSIBLE_INCIDENT', noReply = 'NO_REPLY', sosResponse = 'SOS_RESPONSE', checkIn = 'CHECK_IN';
}

/// A rider's answer to someone else's SOS.
enum SosResponseKind {
  going,
  withThem,
  cancel;

  /// Wire name: GOING, WITH_THEM, CANCEL.
  String get wire => switch (this) {
        SosResponseKind.going => 'GOING',
        SosResponseKind.withThem => 'WITH_THEM',
        SosResponseKind.cancel => 'CANCEL',
      };

  static SosResponseKind? fromWire(String? s) => switch (s?.toUpperCase()) {
        'GOING' => SosResponseKind.going,
        'WITH_THEM' => SosResponseKind.withThem,
        'CANCEL' => SosResponseKind.cancel,
        _ => null,
      };
}

/// Answer to the solo "Are you OK?" check.
enum CheckInResult {
  ok,
  noReply;

  /// Wire name: OK, NO_REPLY.
  String get wire => switch (this) {
        CheckInResult.ok => 'OK',
        CheckInResult.noReply => 'NO_REPLY',
      };

  static CheckInResult? fromWire(String? s) => switch (s?.toUpperCase()) {
        'OK' => CheckInResult.ok,
        'NO_REPLY' => CheckInResult.noReply,
        _ => null,
      };
}

/// Why a rider is or is not live, as the server knows it.
enum RiderPresence {
  unknown,
  online,
  noSignal,
  appClosed;

  /// Wire name: '' (unknown, old gateway), ONLINE, NO_SIGNAL, APP_CLOSED.
  String get wire => switch (this) {
        RiderPresence.unknown => '',
        RiderPresence.online => 'ONLINE',
        RiderPresence.noSignal => 'NO_SIGNAL',
        RiderPresence.appClosed => 'APP_CLOSED',
      };

  static RiderPresence fromWire(String? s) => switch (s?.toUpperCase()) {
        'ONLINE' => RiderPresence.online,
        'NO_SIGNAL' => RiderPresence.noSignal,
        'APP_CLOSED' => RiderPresence.appClosed,
        _ => RiderPresence.unknown,
      };
}

/// One rider who answered an SOS ("I'm going" / "I'm with them").
class SosResponder {
  final String userId;
  final String name;
  final SosResponseKind kind;
  final int at;

  const SosResponder({required this.userId, required this.name, required this.kind, required this.at});

  factory SosResponder.fromJson(Map<String, dynamic> j) => SosResponder(
        userId: j['userId']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        kind: SosResponseKind.fromWire(j['kind']?.toString()) ?? SosResponseKind.going,
        at: (j['at'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {'userId': userId, 'name': name, 'kind': kind.wire, 'at': at};

  /// Responders from the wire (an array) or the database form (a map by userId).
  /// Entries without a user, or with CANCEL, are left out.
  static List<SosResponder> listFrom(Object? raw) {
    final Iterable<Object?> items = raw is List ? raw : (raw is Map ? raw.values : const <Object?>[]);
    final out = <SosResponder>[];
    for (final it in items) {
      if (it is! Map) continue;
      final r = SosResponder.fromJson(Map<String, dynamic>.from(it));
      if (r.userId.isEmpty || r.kind == SosResponseKind.cancel) continue;
      out.add(r);
    }
    return out;
  }
}

/// Features the gateway announces in HELLO. The app only uses a feature the gateway names,
/// so a 3.14 app on an older gateway behaves like 3.13.
class ProtocolFeatures {
  ProtocolFeatures._();
  static const String ack = 'ack', sos2 = 'sos2', respond = 'respond', presence = 'presence', checkIn = 'checkin', roster = 'roster';

  /// 3.15: Rider Safety Network (assistance requests, hazards, emergency status).
  static const String safetyNet = 'net1';

  /// 3.15: Rider Discovery Network (public groups nearby, wave).
  static const String discovery = 'discovery1';
}
