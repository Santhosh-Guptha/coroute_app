import 'dart:convert';

/// 3.55 push notifications: where a tapped push (or a push received with the app open) leads.
/// Pure Dart (no Flutter), so the map is unit-tested (test/push_routing_355_test.dart).
///
/// Types come from the gateway (gateway/src/push.js). Every id is checked before use: the
/// activity that receives a tap is exported, so the extras are treated as untrusted input.
enum PushDestination {
  /// Friends screen (requests and friends).
  friends,

  /// Crews screen (crew invites are listed at the top).
  crewInvites,

  /// One crew's page (its polls); needs [PushRoute.crewId].
  crewPoll,

  /// The ride invitation screen; needs [PushRoute.inviteId].
  rideInvite,

  /// Moderator warnings (shown on Home): refresh them.
  adminWarnings,

  /// Plan / membership page.
  membership,

  /// Unknown type or bad ids: nothing happens.
  none,
}

class PushRoute {
  final PushDestination destination;
  final String? crewId;
  final String? pollId;
  final String? inviteId;
  final String? requestId;

  const PushRoute(this.destination, {this.crewId, this.pollId, this.inviteId, this.requestId});

  static const PushRoute nowhere = PushRoute(PushDestination.none);

  @override
  String toString() => 'PushRoute($destination, crew: $crewId, poll: $pollId, invite: $inviteId, request: $requestId)';
}

class PushRouting {
  PushRouting._();

  /// Every type the app knows how to open.
  static const Set<String> knownTypes = {
    'FRIEND_REQUEST',
    'FRIEND_ACCEPTED',
    'CREW_INVITE',
    'POLL_CREATED',
    'RIDE_INVITE',
    'ADMIN_WARNING',
  };

  static final RegExp _id = RegExp(r'^[A-Za-z0-9_\-:.]{1,80}$');
  static final RegExp _type = RegExp(r'^[A-Z][A-Z_]{2,31}$');

  /// A safe id or null.
  static String? idOf(Object? v) {
    if (v is! String) return null;
    final s = v.trim();
    return _id.hasMatch(s) ? s : null;
  }

  /// The payload extra (a JSON object of strings) as a map; anything else is an empty map.
  static Map<String, String> decodePayload(Object? raw) {
    Object? v = raw;
    if (v is String) {
      if (v.isEmpty || v.length > 4096) return const {};
      try {
        v = jsonDecode(v);
      } catch (_) {
        return const {};
      }
    }
    if (v is! Map) return const {};
    final out = <String, String>{};
    v.forEach((k, val) {
      if (k is String && (val is String || val is num || val is bool)) out[k] = '$val';
    });
    return out;
  }

  /// Where [type] with [payload] leads.
  static PushRoute routeFor(String? type, Map<String, String> payload) {
    if (type == null || !_type.hasMatch(type)) return PushRoute.nowhere;
    switch (type) {
      case 'FRIEND_REQUEST':
      case 'FRIEND_ACCEPTED':
        return PushRoute(PushDestination.friends, requestId: idOf(payload['requestId']));
      case 'CREW_INVITE':
        return PushRoute(PushDestination.crewInvites, crewId: idOf(payload['crewId']), inviteId: idOf(payload['inviteId']));
      case 'POLL_CREATED':
        final crewId = idOf(payload['crewId']);
        if (crewId == null) return const PushRoute(PushDestination.crewInvites);
        return PushRoute(PushDestination.crewPoll, crewId: crewId, pollId: idOf(payload['pollId']));
      case 'RIDE_INVITE':
        final inviteId = idOf(payload['inviteId']);
        if (inviteId == null) return PushRoute.nowhere;
        return PushRoute(PushDestination.rideInvite, inviteId: inviteId);
      case 'ADMIN_WARNING':
        return const PushRoute(PushDestination.adminWarnings);
    }
    if (type.startsWith('SUBSCRIPTION')) return const PushRoute(PushDestination.membership);
    return PushRoute.nowhere;
  }
}
