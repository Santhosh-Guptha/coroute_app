import 'package:coroute_app/domain/voice/call_alert_queue.dart';
import 'package:flutter_test/flutter_test.dart';

HeldAlert _a(String kind, String text, int priority, int at) => HeldAlert(kind: kind, text: text, priority: priority, atMs: at);

void main() {
  group('CallAlertQueue', () {
    test('navigation is not held; the rest is', () {
      final q = CallAlertQueue();
      expect(q.hold(_a('NAV:left', 'Turn left', 3, 0)), isFalse);
      expect(q.hold(_a('hz1', 'Pothole ahead', 2, 0)), isTrue);
      expect(q.length, 1);
    });

    test('latest per kind is kept', () {
      final q = CallAlertQueue();
      q.hold(_a('BEHIND:asha', 'Asha fell behind, 1 km', 4, 0));
      q.hold(_a('BEHIND:asha', 'Asha fell behind, 2 km', 4, 1000));
      expect(q.length, 1);
      expect(q.items.single.text, contains('2 km'));
    });

    test('summary matches the example: counts per category, single lines in full', () {
      final q = CallAlertQueue();
      q.hold(_a('hz1', 'Pothole ahead.', 2, 0));
      q.hold(_a('hz2', 'Speed breaker ahead.', 2, 1000));
      q.hold(_a('BEHIND:asha', 'Asha fell behind.', 4, 2000));
      final s = q.summarize(10000);
      expect(s.ordinaryLine, 'While you were on the call: 2 road warnings, Asha fell behind.');
      expect(s.criticalLine, isNull);
      expect(s.ordinaryCount, 3);
      expect(q.isEmpty, isTrue, reason: 'summarize empties the queue');
    });

    test('ordinary lines older than 60 s are dropped; critical kept 5 min', () {
      final q = CallAlertQueue();
      q.hold(_a('hz1', 'Pothole ahead', 2, 0));
      q.hold(_a('sos', 'Rahul needs help', 0, 0));
      q.hold(_a('fuel', 'Low fuel', 5, 50000));
      final s = q.summarize(70000);
      expect(s.ordinaryLine, 'While you were on the call: Low fuel.');
      expect(s.criticalLine, 'Safety alert during your call: Rahul needs help.');
      expect(q.summarize(70000).isEmpty, isTrue);
    });

    test('everything stale gives an empty summary', () {
      final q = CallAlertQueue();
      q.hold(_a('hz1', 'Pothole ahead', 2, 0));
      expect(q.summarize(120000).isEmpty, isTrue);
    });

    test('critical lines: two in full, then a count', () {
      final q = CallAlertQueue();
      q.hold(_a('a', 'Crash alarm for Ravi', 0, 0));
      q.hold(_a('b', 'Siren close behind', 0, 1000));
      q.hold(_a('c', 'Rider down: Meena', 0, 2000));
      final s = q.summarize(3000);
      expect(s.criticalLine, 'Safety alert during your call: Rider down: Meena. Siren close behind. And 1 more safety alert.');
      expect(s.criticalCount, 3);
    });

    test('updates and informational lines are grouped together', () {
      final q = CallAlertQueue();
      q.hold(_a('fuel', 'Low fuel', 5, 0));
      q.hold(_a('weather', 'Rain ahead', 5, 0));
      expect(q.summarize(1000).ordinaryLine, 'While you were on the call: 2 updates.');
    });

    test('the queue is capped, dropping the least important oldest line', () {
      final q = CallAlertQueue(maxItems: 2);
      q.hold(_a('x', 'Update one', 5, 0));
      q.hold(_a('y', 'Hazard', 2, 1));
      q.hold(_a('z', 'Group', 4, 2));
      expect(q.items.map((h) => h.kind), unorderedEquals(['y', 'z']));
    });

    test('kindOf drops a trailing time bucket', () {
      expect(CallAlertQueue.kindOf('overspeed_29034811'), 'overspeed');
      expect(CallAlertQueue.kindOf('NAV:left:29034811'), 'NAV:left');
      expect(CallAlertQueue.kindOf('STOPPED:u1'), 'STOPPED:u1');
      expect(CallAlertQueue.kindOf('123456'), '123456');
    });

    test('shortPhrase: first sentence, two when the first is tiny, cut at a word', () {
      expect(CallAlertQueue.shortPhrase('SOS emergency from Sweeper'), 'SOS emergency from Sweeper');
      expect(CallAlertQueue.shortPhrase('Emergency. Rahul may have met with an accident 4.8 kilometers behind you.'),
          'Emergency. Rahul may have met with an accident 4.8 kilometers behind');
      expect(CallAlertQueue.shortPhrase('Crash detected. Countdown 15 seconds. Say OK to cancel.'), 'Crash detected.');
      final long = CallAlertQueue.shortPhrase('${'a' * 10} ${'b' * 50} ${'c' * 30}', maxChars: 70);
      expect(long.length, lessThanOrEqualTo(70));
      expect(long.endsWith('b'), isTrue);
    });
  });
}
