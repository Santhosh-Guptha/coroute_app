import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/data/models/trip_history_model.dart';
import 'package:coroute_app/data/models/trip_report_model.dart';
import 'package:coroute_app/domain/tracking/replay_math.dart';
import 'package:coroute_app/presentation/timeline/member_colors.dart';
import 'package:coroute_app/presentation/timeline/timeline_list.dart';

const int t0 = 1800000000000;
const int min = 60000;

void main() {
  group('Replay', () {
    final track = ReplayTrack.fromJson({
      'userId': 'a',
      'name': 'Asha',
      'points': [
        [t0, 17.0, 78.0, 60],
        [t0 + min, 17.01, 78.0, 60],
        [t0 + 30 * min, 17.02, 78.0, 0], // 29 min without points: signal lost
        'garbage',
      ],
    });

    test('parses the compact wire form and skips junk', () {
      expect(track.points.length, 3);
      expect(track.firstTs, t0);
      expect(track.lastTs, t0 + 30 * min);
    });

    test('interpolates between points, never across a long gap or outside the ride', () {
      final mid = track.positionAt(t0 + 30000)!;
      expect(mid.lat, closeTo(17.005, 1e-9));
      expect(mid.kmh, 60);
      expect(track.positionAt(t0 + min)!.lat, 17.01);
      expect(track.positionAt(t0 + 10 * min), isNull); // inside the gap
      expect(track.positionAt(t0 - 1), isNull);
      expect(track.positionAt(t0 + 31 * min), isNull);
    });

    test('tail ends exactly at the current position', () {
      final tail = track.tail(t0 + 45000);
      expect(tail.first.ts, t0);
      expect(tail.last.ts, t0 + 45000);
    });
  });

  group('Report and history models', () {
    test('trip report parses group and member statistics', () {
      final r = TripReportModel.fromJson({
        'group': {'name': 'Hyd to Kurnool', 'members': 3, 'arrived': 2, 'plannedStops': 1, 'visitedStops': 1, 'distanceM': 210400},
        'members': [
          {'userId': 'a', 'name': 'Asha', 'trackAvailable': true, 'distanceM': 210400, 'movingMs': 3 * 3600000, 'restMs': 40 * min, 'stops': 3, 'maxKmh': 96, 'reachedDestination': true},
          {'userId': 'b', 'name': 'Bala'},
        ],
      });
      expect(r.memberCount, 3);
      expect(r.members.first.trackAvailable, isTrue);
      expect(r.members.first.restMs, 40 * min);
      expect(r.members.last.trackAvailable, isFalse);
      expect(r.members.last.distanceM, 0);
    });

    test('only server-built trips open the full report, and that survives local storage', () {
      final server = TripHistoryModel.fromJson({'tripId': 'T1', 'tripName': 'x', 'source': 'server', 'groupId': 'GRP-1', 'startTimeEpochMs': t0, 'endTimeEpochMs': t0 + min});
      final device = TripHistoryModel.fromJson({'tripId': 'T2', 'tripName': 'y', 'groupId': 'GRP-2', 'startTimeEpochMs': t0, 'endTimeEpochMs': t0 + min});
      expect(server.hasReport, isTrue);
      expect(device.hasReport, isFalse);
      expect(TripHistoryModel.fromJson(server.toJson()).groupId, 'GRP-1');
    });

    test('member colours are stable and distinct for a small group', () {
      final c = MemberColors.assign(['a', 'b', 'c', 'a', '']);
      expect(c.length, 3);
      expect({c['a'], c['b'], c['c']}.length, 3);
      expect(MemberColors.assign(['a', 'b'])['b'], c['b']);
      expect(MemberColors.initials('Priya Sharma'), 'PS');
      expect(MemberColors.initials('asha'), 'A');
      expect(MemberColors.initials('  '), '?');
    });
  });

  group('Timeline list', () {
    TimelineEventModel ev(String id, String type, {String? user, String name = '', int at = 0, Map<String, dynamic> data = const {}, int dur = 0, bool open = false}) =>
        TimelineEventModel(eventId: id, groupId: 'G', userId: user, userName: name, type: type, startedAt: t0 + at, durationMs: dur, data: data, open: open);

    final events = [
      ev('1', 'TRIP_STARTED', user: 'a', name: 'Asha'),
      ev('2', 'JOINED', user: 'b', name: 'Bala', at: min),
      ev('3', 'STOPPED', user: 'b', name: 'Bala', at: 10 * min, dur: 6 * min, data: {'reason': 'FUELING'}),
      ev('4', 'SEPARATED', user: 'b', name: 'Bala', at: 12 * min, dur: 7 * min, data: {'maxDistanceM': 6000}),
      ev('5', 'SOS', user: 'c', name: 'Chitra', at: 41 * min, open: true, data: {'alertType': 'MECHANICAL'}),
      ev('6', 'TRIP_ENDED', at: 52 * min),
    ];

    Future<void> pump(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TimelineList(
            events: events,
            colors: MemberColors.assign(['a', 'b', 'c']),
            memberNames: const {'a': 'Asha', 'b': 'Bala', 'c': 'Chitra'},
          ),
        ),
      ));
    }

    testWidgets('shows who did what, and filters by type and by rider', (tester) async {
      await pump(tester);
      expect(find.text('Bala stopped for 6 min'), findsOneWidget);
      expect(find.text('fuelling'), findsOneWidget);
      expect(find.text('Bala fell behind 6.0 km'), findsOneWidget);
      expect(find.text('Chitra raised an SOS (mechanical issue)'), findsOneWidget);
      expect(find.text('NOW'), findsOneWidget);
      expect(find.text('Trip ended'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Alerts'));
      await tester.pumpAndSettle();
      expect(find.text('Bala stopped for 6 min'), findsNothing);
      expect(find.text('Bala fell behind 6.0 km'), findsOneWidget);
      expect(find.text('Chitra raised an SOS (mechanical issue)'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
      await tester.tap(find.widgetWithText(FilterChip, 'Chitra'));
      await tester.pumpAndSettle();
      expect(find.text('Chitra raised an SOS (mechanical issue)'), findsOneWidget);
      expect(find.text('Bala joined'), findsNothing);
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('fits a phone in landscape without overflow', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 360));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: TimelineList(events: events, colors: MemberColors.assign(['a', 'b', 'c']), memberNames: const {'a': 'Asha', 'b': 'Bala', 'c': 'Chitra'})),
      ));
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
    });
  });
}
