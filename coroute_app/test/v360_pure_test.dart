// v3.60 pure checks: push routes for chat and community notices.
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/notify/push_routing.dart';

void main() {
  test('chat message push opens that chat; bad ids go nowhere', () {
    final r = PushRouting.routeFor('CHAT_MESSAGE', {'chatId': 'dm_0123456789abcdef01234567', 'messageId': 'cm_1'});
    expect(r.destination, PushDestination.chat);
    expect(r.chatId, 'dm_0123456789abcdef01234567');
    expect(PushRouting.routeFor('CHAT_MESSAGE', {'chatId': '../../x y'}).destination, PushDestination.none);
    expect(PushRouting.knownTypes, containsAll(['CHAT_MESSAGE', 'CREW_JOIN_REQUEST', 'CREW_JOIN_APPROVED', 'CREW_RIDE_NEW']));
  });

  test('community notices open the community page', () {
    for (final t in ['CREW_JOIN_REQUEST', 'CREW_JOIN_APPROVED', 'CREW_RIDE_NEW']) {
      final r = PushRouting.routeFor(t, {'crewId': 'cr_0123456789abcdef'});
      expect(r.destination, PushDestination.crewPoll, reason: t);
      expect(r.crewId, 'cr_0123456789abcdef');
      expect(PushRouting.routeFor(t, const {}).destination, PushDestination.crewInvites, reason: t);
    }
  });
}
