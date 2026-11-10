// 3.55 friends: the app parses the real gateway answers (owner bug "a friend request is not
// appearing anywhere in the app"). The fixture was captured from an end-to-end run against the real
// gateway; gateway/test/friends_app_contract_355.test.js checks the live answers keep its shape.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/notify/notice_dedupe.dart';
import 'package:coroute_app/domain/social/friends_models.dart';

Map<String, dynamic> _fixture() {
  final f = File('test/fixtures/friends_355_gateway.json');
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  final fx = _fixture();
  final names = fx['names'] as Map<String, dynamic>;
  final sender = names['sender'] as String;
  final target = names['target'] as String;
  final coder = names['coder'] as String;

  group('GET /friends', () {
    test('the target sees both incoming requests (by username and by invite code)', () {
      final snap = FriendsSnapshot.parse(fx['targetFriends'])!;
      expect(snap.incoming.map((r) => r.username), [coder, sender]);
      expect(snap.incoming.every((r) => r.requestId.startsWith('fr_')), isTrue);
      expect(snap.incoming.every((r) => r.at > 0), isTrue);
      expect(snap.incoming.first.avatarUrl, isNull);
      expect(snap.outgoing, isEmpty);
      expect(snap.friends, isEmpty);
      expect(snap.inviteCode, matches(RegExp(r'^[A-HJ-NP-Z2-9]{8}$')));
    });

    test('the sender sees the request under Sent with the same id the target got', () {
      final snap = FriendsSnapshot.parse(fx['senderFriends'])!;
      expect(snap.outgoing.map((r) => r.username), [target]);
      final inTarget = FriendsSnapshot.parse(fx['targetFriends'])!.incoming.firstWhere((r) => r.username == sender);
      expect(snap.outgoing.single.requestId, inTarget.requestId);
      expect(snap.incoming, isEmpty);
    });

    test('after accepting, the friend row parses with its totals', () {
      final snap = FriendsSnapshot.parse(fx['senderAfterAccept'])!;
      expect(snap.friends.single.username, target);
      expect(snap.friends.single.displayName, 'Fixture');
      expect(snap.friends.single.since, greaterThan(0));
      expect(snap.outgoing, isEmpty);
    });

    test('something that is not a friends answer keeps what the app has', () {
      expect(FriendsSnapshot.parse(null), isNull);
      expect(FriendsSnapshot.parse({'ok': true}), isNull);
      expect(FriendsSnapshot.parse(fx['sendUnknown']['body']), isNull);
      // Rows without an id cannot be answered: left out.
      final s = FriendsSnapshot.parse({
        'incoming': [
          {'username': 'NoId'},
          {'requestId': 'fr_1', 'username': 'Ok'},
        ],
      })!;
      expect(s.incoming.map((r) => r.username), ['Ok']);
    });
  });

  group('POST /friends/requests', () {
    test('202 REQUESTED carries the row shown under Sent at once', () {
      final r = FriendRequestResult.fromJson(fx['sendByUsername']['body']);
      expect(r.ok, isTrue);
      expect(r.status, 'REQUESTED');
      expect(r.request!.username, target);
      expect(r.request!.requestId, startsWith('fr_'));
      expect(r.confirmation, 'Request sent to $target. It is under Sent until they answer.');
      final byCode = FriendRequestResult.fromJson(fx['sendByInviteCode']['body']);
      expect(byCode.request!.username, target);
    });

    test('the Sent list gets the row once, even if GET /friends already has it', () {
      final r = FriendRequestResult.fromJson(fx['sendByUsername']['body']).request!;
      final listed = FriendsSnapshot.parse(fx['senderFriends'])!.outgoing;
      expect(withRequest(listed, r), hasLength(1));
      expect(withRequest(const [], r).single.requestId, r.requestId);
    });

    test('FRIENDS / ALREADY_FRIENDS / older gateways', () {
      expect(FriendRequestResult.fromJson({'status': 'FRIENDS', 'friend': {'username': 'Kiran7'}}).confirmation, 'You and Kiran7 are now friends');
      expect(FriendRequestResult.fromJson({'status': 'ALREADY_FRIENDS'}).confirmation, 'You are already friends');
      final old = FriendRequestResult.fromJson({'ok': true, 'status': 'REQUESTED'});
      expect(old.request, isNull);
      expect(old.confirmation, 'Request sent. You will be friends once they accept.');
    });

    test('a leading @ and spaces are ignored', () {
      expect(usernameInput('  @$target '), target);
      expect(usernameInput('@@x_rider'), 'x_rider');
      expect(usernameInput('Plain'), 'Plain');
    });
  });

  group('socket pushes', () {
    test('FRIEND_REQUEST: notice line and an incoming row before GET /friends answers', () {
      final p = FriendPush.parse(fx['socketFriendRequest'])!;
      expect(p.isRequest, isTrue);
      expect(p.username, sender);
      expect(p.line, '$sender wants to be friends');
      expect(p.eventId, 'FRIEND_REQUEST:${p.requestId}');
      final row = p.asIncoming!;
      final listed = FriendsSnapshot.parse(fx['targetFriends'])!.incoming;
      expect(listed.any((r) => r.requestId == row.requestId), isTrue, reason: 'same id as GET /friends');
      expect(withRequest(listed, row), hasLength(listed.length), reason: 'no duplicate');
      expect(withRequest(const [], row).single.username, sender);
    });

    test('FRIEND_ACCEPTED', () {
      final p = FriendPush.parse(fx['socketFriendAccepted'])!;
      expect(p.isRequest, isFalse);
      expect(p.line, '$target accepted your friend request');
      expect(p.asIncoming, isNull);
    });

    test('other messages are ignored', () {
      expect(FriendPush.parse({'type': 'CREW_INVITE'}), isNull);
      expect(FriendPush.parse('x'), isNull);
    });

    test('the first notice of an event is shown; its FCM copy is not', () {
      final d = NoticeDedupe(clock: () => 1000);
      final p = FriendPush.parse(fx['socketFriendRequest'])!;
      expect(d.firstTime(p.eventId), isTrue);
      expect(d.firstTime(p.eventId), isFalse);
      // A different request from the same rider is a new notice.
      expect(d.firstTime('FRIEND_REQUEST:fr_other'), isTrue);
    });
  });
}
