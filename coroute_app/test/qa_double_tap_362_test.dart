// v3.62 QA: a double tap sends one answer (needs the Flutter SDK: flutter test test/qa_double_tap_362_test.dart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/presentation/rider/widgets/gathering_card.dart';
import 'package:coroute_app/presentation/rider/widgets/join_requests_card.dart';

void main() {
  testWidgets('Let in: a double tap calls the host decision once; the buttons wait for the answer', (tester) async {
    var calls = 0;
    final answer = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: JoinRequestsCard(pending: const {'u1': 'Anu'}, onDecide: (id, ok) { calls++; return answer.future; }),
      ),
    ));
    await tester.tap(find.byKey(const Key('join_approve_u1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('join_approve_u1')), warnIfMissed: false);
    await tester.tap(find.byKey(const Key('join_decline_u1')), warnIfMissed: false);
    await tester.pump();
    expect(calls, 1);
    answer.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('Start ride: a double tap starts once and shows "Starting…" meanwhile', (tester) async {
    var calls = 0;
    final done = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GatheringCard(placeName: 'Nandi Hills gate', arrived: 3, total: 5, canStart: true, onStart: () { calls++; return done.future; }),
      ),
    ));
    await tester.tap(find.byKey(const Key('gathering_start')));
    await tester.pump();
    expect(find.text('Starting…'), findsOneWidget);
    await tester.tap(find.byKey(const Key('gathering_start')), warnIfMissed: false);
    await tester.pump();
    expect(calls, 1);
    done.complete();
    await tester.pumpAndSettle();
    expect(find.text('Start ride'), findsOneWidget);
  });
}
