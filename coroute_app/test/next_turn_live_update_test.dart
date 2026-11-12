// Next turn on the line I follow (Ride AOD, Live Update) and the Android 16 Live Update content.
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/domain/notify/live_update.dart';
import 'package:coroute_app/domain/notify/notification_snapshot.dart';
import 'package:coroute_app/domain/route/next_turn.dart';
import 'package:coroute_app/domain/route/route_progress.dart';

/// North 500 m, then east (a right turn), then north again (a left turn).
RouteProgress _zigzag() => RouteProgress(const [(12.0, 77.0), (12.0045, 77.0), (12.0045, 77.0046), (12.009, 77.0046)]);

List<RouteStep> _steps(RouteProgress line) => [
      RouteStep(name: 'MG Road', distanceM: line.alongAtVertex(1), startM: 0, endM: line.alongAtVertex(1)),
      RouteStep(name: 'Brigade Road', ref: '', distanceM: 500, startM: line.alongAtVertex(1), endM: line.alongAtVertex(2)),
      RouteStep(name: '', ref: 'NH 44', distanceM: 500, startM: line.alongAtVertex(2), endM: line.lengthM),
    ];

void main() {
  group('NextTurn', () {
    test('the next step start ahead, with direction, distance and road', () {
      final line = _zigzag();
      final t = NextTurn.compute(steps: _steps(line), line: line, alongM: 100)!;
      expect(t.direction, TurnDirection.right);
      expect(t.distanceM, closeTo(line.alongAtVertex(1) - 100, 0.01));
      expect(t.distanceText, '400 m');
      expect(t.road, 'Brigade Road');
      expect(t.line, 'Turn right in 400 m');

      final second = NextTurn.compute(steps: _steps(line), line: line, alongM: line.alongAtVertex(1) + 50)!;
      expect(second.direction, TurnDirection.left);
      expect(second.road, 'NH 44');
    });

    test('nothing past the last step, without steps or without a line', () {
      final line = _zigzag();
      expect(NextTurn.compute(steps: _steps(line), line: line, alongM: line.alongAtVertex(2) + 10), isNull);
      expect(NextTurn.compute(steps: const [], line: line, alongM: 0), isNull);
      expect(NextTurn.compute(steps: _steps(line), line: RouteProgress(const [(12.0, 77.0)]), alongM: 0), isNull);
    });

    test('directions from the angle (right positive)', () {
      expect(NextTurn.classify(5), TurnDirection.straight);
      expect(NextTurn.classify(-30), TurnDirection.slightLeft);
      expect(NextTurn.classify(30), TurnDirection.slightRight);
      expect(NextTurn.classify(90), TurnDirection.right);
      expect(NextTurn.classify(-90), TurnDirection.left);
      expect(NextTurn.classify(150), TurnDirection.sharpRight);
      expect(NextTurn.classify(-179), TurnDirection.uTurn);
      expect(NextTurn.signedDelta(350, 10), closeTo(20, 1e-9));
      expect(NextTurn.signedDelta(10, 350), closeTo(-20, 1e-9));
    });
  });

  group('Live Update content (Android 16)', () {
    const ahead = [RiderLine(name: 'Arjun', distanceM: 1200, ahead: true)];
    const behind = [RiderLine(name: 'Meera', distanceM: 800, ahead: false)];

    test('next turn first: title, road, short chip and progress', () {
      final line = _zigzag();
      final turn = NextTurn.compute(steps: _steps(line), line: line, alongM: 100);
      final c = LiveUpdateContent.build(mode: NotifMode.ride, turn: turn, ahead: ahead, behind: behind, progress01: 0.25)!;
      expect(c['title'], 'Turn right in 400 m');
      expect(c['text'], 'Brigade Road');
      expect(c['chip'], '400 m');
      expect((c['chip'] as String).length, lessThanOrEqualTo(LiveUpdateContent.chipMax));
      expect(c['progress'], 25);
    });

    test('no turn: the group status (the rider ahead, or "You lead")', () {
      final c = LiveUpdateContent.build(mode: NotifMode.ride, ahead: ahead, behind: behind)!;
      expect(c['title'], 'Arjun 1.2 km ahead');
      expect(c['text'], 'Pack #2 of 3');
      expect(c['chip'], '1.2 km');
      expect(c['progress'], -1);
      final lead = LiveUpdateContent.build(mode: NotifMode.ride, behind: behind)!;
      expect(lead['title'], 'You lead · 2 riders');
      expect(lead['chip'], 'Lead');
    });

    test('emergencies, assists and hazards keep the full notification; nothing to say: none', () {
      for (final m in [NotifMode.groupEmergency, NotifMode.assist, NotifMode.hazard]) {
        expect(LiveUpdateContent.build(mode: m, ahead: ahead), isNull, reason: '$m');
      }
      expect(LiveUpdateContent.build(mode: NotifMode.ride), isNull, reason: 'solo without a route');
    });
  });
}
