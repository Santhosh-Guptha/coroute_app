import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/trip_plan_model.dart';
import 'package:coroute_app/data/models/trip_report_model.dart';
import 'package:coroute_app/domain/tracking/replay_math.dart';
import 'package:coroute_app/presentation/report/trip_route_map.dart';

void main() {
  const t0 = 1800000000000;
  const min = 60000;

  group('Routes on the trip map', () {
    test('a dead zone is cut out of the route instead of drawn as a straight ride', () {
      final track = ReplayTrack.fromJson({
        'userId': 'a',
        'name': 'Asha',
        'points': [
          [t0, 17.000, 78.4, 50],
          [t0 + min, 17.010, 78.4, 50],
          [t0 + 2 * min, 17.020, 78.4, 50],
          // 25 minutes without signal, 9 km further on
          [t0 + 27 * min, 17.100, 78.4, 50],
          [t0 + 28 * min, 17.110, 78.4, 50],
          // one bad fix 40 km away a second later
          [t0 + 28 * min + 1000, 17.470, 78.4, 50],
        ],
      });
      final s = track.split();
      expect(s.pieces.length, 2);
      expect(s.pieces.first.length, 3);
      expect(s.pieces.last.length, 2);
      expect(s.gaps.length, 2, reason: 'the dead zone and the bad fix are both left undrawn');
      expect(s.gaps.first.$1.ts, t0 + 2 * min);
      expect(s.gaps.first.$2.ts, t0 + 27 * min);
    });

    test('a short pause without moving is not a gap', () {
      final track = ReplayTrack.fromJson({
        'userId': 'a',
        'points': [
          [t0, 17.0, 78.4, 0],
          [t0 + 30 * min, 17.0001, 78.4, 0],
          [t0 + 31 * min, 17.01, 78.4, 40],
        ],
      });
      final s = track.split();
      expect(s.pieces.length, 1);
      expect(s.gaps, isEmpty);
    });

    test('the tail follows the rider and ends at the current position', () {
      final track = ReplayTrack.fromJson({
        'userId': 'a',
        'points': [for (var i = 0; i <= 20; i++) [t0 + i * min, 17.0 + i * 0.01, 78.4, 40]],
      });
      final tail = track.tail(t0 + 15 * min + 30000);
      expect(tail.first.ts, t0 + 6 * min);
      expect(tail.last.ts, t0 + 15 * min + 30000);
      expect(tail.last.lat, closeTo(17.155, 1e-9));
    });

    test('labels and readable text on rider colours', () {
      expect(TripRouteMap.shortDuration(12 * min), '12m');
      expect(TripRouteMap.shortDuration(65 * min), '1h 05m');
      expect(TripRouteMap.shortDuration(10000), '1m');
      expect(TripRouteMap.onColor(const Color(0xFFFFD54F)), Colors.black);
      expect(TripRouteMap.onColor(const Color(0xFF1565C0)), Colors.white);
    });
  });

  group('Trip plan and rider report', () {
    test('the plan keeps stops in order with who reached them', () {
      final p = TripPlan.fromJson({
        'start': {'lat': 17.38, 'lng': 78.48, 'name': 'Gachibowli'},
        'destination': {'lat': 16.07, 'lng': 78.86, 'name': 'Srisailam'},
        'stops': [
          {'stopId': 's2', 'name': 'Lunch', 'lat': 16.5, 'lng': 78.7, 'orderIndex': 2, 'arrivals': {'a': {'name': 'Asha', 'arrivedAt': t0, 'leftAt': t0 + 20 * min}}},
          {'stopId': 's1', 'name': 'Fuel', 'lat': 17.1, 'lng': 78.6, 'orderIndex': 1, 'isVisited': true},
          {'stopId': 'x', 'name': 'Broken', 'lat': 'bad'},
        ],
      })!;
      expect(p.start!.name, 'Gachibowli');
      expect(p.destination!.name, 'Srisailam');
      expect(p.stops.map((s) => s.name), ['Fuel', 'Lunch']);
      expect(p.stops.last.arrivals['a']!.reached, isTrue);
      expect(TripPlan.fromJson({'destination': {'lat': 0, 'lng': 0}})!.destination, isNull, reason: 'no destination set');
    });

    test('each rider\'s start and finish come with the report', () {
      final m = MemberReport.fromJson({
        'userId': 'a', 'name': 'Asha', 'firstFixAt': t0, 'lastFixAt': t0 + 240 * min,
        'startPlace': 'Gachibowli, Hyderabad', 'endPlace': 'Srisailam', 'joinedAt': t0 - min,
      });
      expect(m.startPlace, 'Gachibowli, Hyderabad');
      expect(m.endPlace, 'Srisailam');
      expect(m.lastFixAt - m.firstFixAt, 240 * min);
      expect(m.joinedAt, t0 - min);
    });
  });
}
