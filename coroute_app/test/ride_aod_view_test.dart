// Ride AOD view: minimal content on black, burn-in shift once a minute, "Hold SOS" stays reachable.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/route/next_turn.dart';
import 'package:coroute_app/domain/tracking/screen_awake_policy.dart';
import 'package:coroute_app/presentation/rider/widgets/ride_aod_view.dart';

void main() {
  var clock = DateTime(2026, 11, 12, 14, 32, 10);

  Widget app({VoidCallback? onSos, VoidCallback? onWake, String? group, double? leader = 1200}) => MaterialApp(
        home: RideAodView(
          speedKmh: 47.6,
          turn: const NextTurn(direction: TurnDirection.right, distanceM: 400, road: 'MG Road'),
          leaderDistanceM: leader,
          leaderRelativeBearing: 30,
          groupLine: group,
          batteryPercent: 72,
          onHoldSos: onSos,
          onWake: onWake,
          now: () => clock,
        ),
      );

  Offset shiftOf(WidgetTester tester) {
    final t = tester.widget<Transform>(find.byKey(const Key('ride_aod_content')));
    final v = t.transform.getTranslation();
    return Offset(v.x, v.y);
  }

  testWidgets('speed, next turn, leader, time and battery on pure black', (tester) async {
    clock = DateTime(2026, 11, 12, 14, 32, 10);
    await tester.pumpWidget(app());
    expect(find.text('48'), findsOneWidget);
    expect(find.text('km/h'), findsOneWidget);
    expect(find.text('400 m'), findsOneWidget);
    expect(find.text('MG Road'), findsOneWidget);
    expect(find.byIcon(Icons.turn_right), findsOneWidget);
    expect(find.text('Leader 1.2 km'), findsOneWidget);
    expect(find.text('14:32'), findsOneWidget);
    expect(find.text('72%'), findsOneWidget);
    expect(find.text('Hold SOS'), findsOneWidget);
    expect(tester.widget<ColoredBox>(find.byKey(const Key('ride_aod'))).color, Colors.black);
  });

  testWidgets('no leader to point at: the group status', (tester) async {
    await tester.pumpWidget(app(leader: null, group: '3 of 5 riding'));
    expect(find.text('3 of 5 riding'), findsOneWidget);
    expect(find.byKey(const Key('ride_aod_leader')), findsNothing);
  });

  testWidgets('the content shifts a few pixels once a minute (burn-in), and the clock follows', (tester) async {
    clock = DateTime(2026, 11, 12, 14, 32, 10);
    await tester.pumpWidget(app());
    final first = shiftOf(tester);
    final expected = ScreenAwakePolicy.burnInShift(clock.millisecondsSinceEpoch);
    expect(first, Offset(expected.dx.toDouble(), expected.dy.toDouble()));
    expect(first.dx.abs(), lessThanOrEqualTo(ScreenAwakePolicy.burnInMaxPx));

    clock = clock.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    final next = ScreenAwakePolicy.burnInShift(clock.millisecondsSinceEpoch);
    expect(shiftOf(tester), Offset(next.dx.toDouble(), next.dy.toDouble()));
    expect(shiftOf(tester), isNot(first));
    expect(find.text('14:33'), findsOneWidget);
  });

  testWidgets('holding the SOS hint opens the SOS hold screen; a short tap wakes the cockpit', (tester) async {
    var sos = 0, wake = 0;
    await tester.pumpWidget(app(onSos: () => sos++, onWake: () => wake++));
    await tester.longPress(find.byKey(const Key('ride_aod_sos')));
    expect(sos, 1);
    expect(RideAodView.sosPointerDown, isFalse);
    await tester.tap(find.byKey(const Key('ride_aod_sos')));
    expect(wake, 1);
  });

  test('turn icons for every direction', () {
    for (final d in TurnDirection.values) {
      expect(RideAodView.turnIcon(d), isNotNull);
    }
  });
}
