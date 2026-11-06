import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/presentation/rider/widgets/minimal_cockpit_stats_row.dart';

void main() {
  testWidgets('Compact cockpit top bar layout and non-overlapping bounds test', (WidgetTester tester) async {
    final me = RiderModel(
      userId: 'u1',
      name: 'Rider 1',
      lat: 12.9716,
      lng: 77.5946,
      speedKmh: 45.0,
      heading: 90.0,
      role: 'LEAD',
      lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
    );
    final convoy = ConvoyModel(
      groupId: 'g1',
      name: 'Trip 1',
      joinCode: '1234',
      createdByUserId: 'u1',
      createdByUserName: 'Rider 1',
      createdAtEpochMs: 0,
      riders: {'u1': me},
    );
    final snap = RideSnapshot(
      me: me,
      remainingM: 1000.0,
      eta: const Duration(minutes: 10),
      nextStop: null,
      nextStopM: null,
      spreadM: 0,
      ladder: [],
      stops: [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SizedBox(
                  key: const Key('compact_cockpit_top_bar'),
                  height: 60,
                  child: MinimalCockpitStatsRow(
                    convoy: convoy,
                    me: me,
                    snap: snap,
                    eta: '12:34',
                    guardianOn: true,
                    now: DateTime.now().millisecondsSinceEpoch,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final topBarFinder = find.byKey(const Key('compact_cockpit_top_bar'));
    expect(topBarFinder, findsOneWidget);
    final topBarRect = tester.getRect(topBarFinder);
    expect(topBarRect.top, greaterThanOrEqualTo(0.0));
    expect(topBarRect.height, lessThanOrEqualTo(80.0));
    debugPrint('Compact cockpit layout bounds verified successfully.');
  });
}
