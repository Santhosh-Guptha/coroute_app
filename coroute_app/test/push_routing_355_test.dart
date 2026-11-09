import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/notify/push_routing.dart';

/// 3.55 push notifications: the type -> screen map and the untrusted-extras checks.
void main() {
  test('friend pushes open the friends screen', () {
    expect(PushRouting.routeFor('FRIEND_REQUEST', {'requestId': 'fr_0123456789abcdef0123'}).destination, PushDestination.friends);
    expect(PushRouting.routeFor('FRIEND_REQUEST', {'requestId': 'fr_0123456789abcdef0123'}).requestId, 'fr_0123456789abcdef0123');
    expect(PushRouting.routeFor('FRIEND_ACCEPTED', const {}).destination, PushDestination.friends);
  });

  test('crew invite -> crews (invites); poll -> crew detail; poll without crew -> crews', () {
    final inv = PushRouting.routeFor('CREW_INVITE', {'crewId': 'cr_1', 'inviteId': 'ci_2'});
    expect(inv.destination, PushDestination.crewInvites);
    expect(inv.crewId, 'cr_1');
    expect(inv.inviteId, 'ci_2');
    final poll = PushRouting.routeFor('POLL_CREATED', {'crewId': 'cr_1', 'pollId': 'po_9'});
    expect(poll.destination, PushDestination.crewPoll);
    expect(poll.crewId, 'cr_1');
    expect(poll.pollId, 'po_9');
    expect(PushRouting.routeFor('POLL_CREATED', const {}).destination, PushDestination.crewInvites);
  });

  test('ride invite needs a valid invite id', () {
    final r = PushRouting.routeFor('RIDE_INVITE', {'inviteId': 'ri_abc'});
    expect(r.destination, PushDestination.rideInvite);
    expect(r.inviteId, 'ri_abc');
    expect(PushRouting.routeFor('RIDE_INVITE', const {}).destination, PushDestination.none);
    expect(PushRouting.routeFor('RIDE_INVITE', {'inviteId': '../../etc'}).destination, PushDestination.none);
  });

  test('admin warning and subscription events', () {
    expect(PushRouting.routeFor('ADMIN_WARNING', const {}).destination, PushDestination.adminWarnings);
    expect(PushRouting.routeFor('SUBSCRIPTION_EXPIRING', const {}).destination, PushDestination.membership);
  });

  test('unknown or malformed types go nowhere', () {
    for (final t in [null, '', 'friend_request', 'X', 'SOMETHING_NEW', 'A' * 40, 'FRIEND REQUEST']) {
      expect(PushRouting.routeFor(t, const {}).destination, PushDestination.none, reason: '$t');
    }
  });

  test('bad ids are dropped', () {
    final r = PushRouting.routeFor('POLL_CREATED', {'crewId': 'cr 1; drop', 'pollId': 'po_1'});
    expect(r.destination, PushDestination.crewInvites);
    expect(PushRouting.idOf('x' * 81), isNull);
    expect(PushRouting.idOf(42), isNull);
    expect(PushRouting.idOf(' cr_1 '), 'cr_1');
  });

  test('payload decoding: JSON object of strings only', () {
    expect(PushRouting.decodePayload('{"crewId":"cr_1","n":3,"x":{"a":1}}'), {'crewId': 'cr_1', 'n': '3'});
    expect(PushRouting.decodePayload('not json'), isEmpty);
    expect(PushRouting.decodePayload('[1,2]'), isEmpty);
    expect(PushRouting.decodePayload(null), isEmpty);
    expect(PushRouting.decodePayload({'pollId': 'po_1'}), {'pollId': 'po_1'});
    expect(PushRouting.decodePayload('x' * 5000), isEmpty);
  });

  test('every known type routes somewhere', () {
    for (final t in PushRouting.knownTypes) {
      final payload = {'crewId': 'cr_1', 'inviteId': 'ri_1', 'pollId': 'po_1', 'requestId': 'fr_1'};
      expect(PushRouting.routeFor(t, payload).destination, isNot(PushDestination.none), reason: t);
    }
  });
}
