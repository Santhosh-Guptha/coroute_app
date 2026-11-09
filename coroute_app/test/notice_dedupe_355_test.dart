// 3.55 follow-up: one notice per event (NoticeDedupe). The gateway gives the socket message and
// the FCM push of the same friend request / crew invite / poll / ride invite one eventId; the app
// shows the first and ignores a second within 10 minutes.
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/notify/notice_dedupe.dart';

void main() {
  group('NoticeDedupe', () {
    test('the second notice with the same eventId within 10 minutes is ignored', () {
      var now = 1000;
      final d = NoticeDedupe(clock: () => now);
      expect(d.firstTime('FRIEND_REQUEST:fr_1'), isTrue, reason: 'the socket notice');
      now += 30 * 1000;
      expect(d.firstTime('FRIEND_REQUEST:fr_1'), isFalse, reason: 'its push a moment later');
      expect(d.seen('FRIEND_REQUEST:fr_1'), isTrue);
      expect(d.firstTime('FRIEND_ACCEPTED:fr_1'), isTrue, reason: 'another event about the same request');
      now += const Duration(minutes: 10).inMilliseconds;
      expect(d.seen('FRIEND_REQUEST:fr_1'), isFalse);
      expect(d.firstTime('FRIEND_REQUEST:fr_1'), isTrue, reason: 'after the window it is a new notice');
    });

    test('no id (an older gateway) or a bad id: always shown', () {
      final d = NoticeDedupe(clock: () => 0);
      expect(d.firstTime(null), isTrue);
      expect(d.firstTime(null), isTrue);
      expect(d.firstTime(''), isTrue);
      expect(d.firstTime(''), isTrue);
      expect(d.firstTime('bad id with spaces'), isTrue);
      expect(d.firstTime('bad id with spaces'), isTrue);
      expect(d.firstTime(42), isTrue);
      expect(NoticeDedupe.idOf(' POLL_CREATED:p_1 '), 'POLL_CREATED:p_1');
    });

    test('bounded memory: the oldest ids make room', () {
      final d = NoticeDedupe(clock: () => 0, maxIds: 3);
      for (final id in ['A:1', 'A:2', 'A:3', 'A:4']) {
        expect(d.firstTime(id), isTrue);
      }
      expect(d.firstTime('A:1'), isTrue, reason: 'dropped when the 4th came');
      expect(d.firstTime('A:4'), isFalse);
      d.clear();
      expect(d.firstTime('A:4'), isTrue);
    });
  });
}
