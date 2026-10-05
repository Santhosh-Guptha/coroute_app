import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/models/stop_point_model.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/domain/notify/alert_policy.dart';

const int t0 = 1800000000000;
const int min = 60000;

TimelineEventModel ev(String id, String type, {String? user, String name = '', int at = 0, bool open = false, Map<String, dynamic> data = const {}, String place = ''}) =>
    TimelineEventModel(eventId: id, groupId: 'G', userId: user, userName: name, type: type, startedAt: t0 + at, open: open, data: data, placeName: place);

void main() {
  group('Route and stops models', () {
    test('route from the gateway decodes once; plan falls back to the old breadcrumbs', () {
      final c = ConvoyModel.fromJson({
        'groupId': 'G', 'name': 'x', 'joinCode': '1', 'createdByUserId': 'a', 'createdByUserName': 'A', 'createdAtEpochMs': t0,
        'route': {'distanceM': 210400, 'durationS': 12600, 'polyline': '_p~iF~ps|U_ulLnnqC_mqNvxq`@', 'legs': [{'distanceM': 100000, 'durationS': 6000}], 'approximate': false},
        'start': {'lat': 17.0, 'lng': 78.0, 'name': 'Home'},
        'routeBreadcrumbs': [{'lat': 1.0, 'lng': 2.0}, {'lat': 3.0, 'lng': 4.0}],
        'stopPoints': [
          {'stopId': 's2', 'name': 'Lunch', 'lat': 17.2, 'lng': 78, 'orderIndex': 2},
          {'stopId': 's1', 'name': 'Fuel', 'lat': 17.1, 'lng': 78, 'orderIndex': 1, 'status': 'PLANNED'},
          {'stopId': 's3', 'name': 'Tea', 'lat': 17.15, 'lng': 78, 'orderIndex': 3, 'status': 'SUGGESTED', 'suggestedByName': 'Mani'},
          {'stopId': 's4', 'name': 'View', 'lat': 17.25, 'lng': 78, 'orderIndex': 4, 'status': 'SKIPPED'},
        ],
      });
      expect(c.route!.points.length, 3);
      expect(c.routeLine.first, (38.5, -120.2));
      expect(c.route!.legs.single.durationS, 6000);
      expect(c.startLat, 17.0);
      expect(c.plannedStops.map((s) => s.name), ['Fuel', 'Lunch']);
      expect(c.suggestedStops.single.suggestedByName, 'Mani');
      final noRoute = c.copyWith(clearRoute: true);
      expect(noRoute.route, isNull);
      expect(noRoute.routeLine, [(1.0, 2.0), (3.0, 4.0)]);
      expect(ConvoyModel.fromJson(c.toJson()).route!.distanceM, 210400);
    });

    test('old stops without a status are planned', () {
      final s = StopPointModel.fromJson({'stopId': 'x', 'name': 'Old', 'lat': 1, 'lng': 2});
      expect(s.isPlanned, isTrue);
      expect(s.copyWith(isVisited: true).status, 'PLANNED');
      expect(RouteModel.fromJson({'polyline': '@@@'}).points, isEmpty);
    });
  });

  group('Alert policy', () {
    final policy = AlertPolicy();
    const lead = AlertViewer(userId: 'lead', isLead: true);
    const rider = AlertViewer(userId: 'r1');

    test('SOS goes to everyone except the sender, and clears when resolved', () {
      final sos = ev('e1', 'SOS', user: 'r1', name: 'Priya', open: true, data: {'alertId': 'SOS-1', 'alertType': 'MECHANICAL'}, place: 'NH44');
      final forLead = policy.standing([sos], lead, nowMs: t0 + min);
      expect(forLead.single.channel, AlertChannel.sos);
      expect(forLead.single.title, 'SOS from Priya');
      expect(forLead.single.body, startsWith('mechanical issue near NH44'));
      expect(policy.standing([sos], rider, nowMs: t0 + min), isEmpty);
      final resolved = ev('e1', 'SOS', user: 'r1', name: 'Priya', data: {'alertId': 'SOS-1'});
      expect(policy.standing([resolved], lead, nowMs: t0 + min), isEmpty);
    });

    test('a long stop alerts the lead only after the limit', () {
      final stop = ev('e2', 'STOPPED', user: 'r1', name: 'Priya', open: true, data: {'reason': 'FUELING'});
      expect(policy.standing([stop], lead, nowMs: t0 + 19 * min), isEmpty);
      final a = policy.standing([stop], lead, nowMs: t0 + 21 * min).single;
      expect(a.title, 'Priya has been stopped for 21 min');
      expect(a.body, 'fuelling.');
      expect(policy.standing([stop], const AlertViewer(userId: 'r2'), nowMs: t0 + 30 * min), isEmpty);
    });

    test('separation tells the separated rider and the lead; same key while it lasts', () {
      final sep = ev('e3', 'SEPARATED', user: 'r1', name: 'Bala', open: true, data: {'maxDistanceM': 2400});
      final mine = policy.standing([sep], rider, nowMs: t0 + 2 * min).single;
      expect(mine.title, 'You are 2.4 km from your group');
      final leads = policy.standing([sep], lead, nowMs: t0 + 2 * min).single;
      expect(leads.title, 'Bala is 2.4 km from the group');
      expect(leads.id, policy.standing([sep], lead, nowMs: t0 + 5 * min).single.id);
      expect(leads.id, greaterThanOrEqualTo(2000));
    });

    test('no signal alerts only the lead, after the limit', () {
      final off = ev('e4', 'OFFLINE', user: 'r1', name: 'Ravi', open: true);
      expect(policy.standing([off], lead, nowMs: t0 + 4 * min), isEmpty);
      expect(policy.standing([off], lead, nowMs: t0 + 6 * min).single.title, 'No signal from Ravi for 6 min');
      expect(policy.standing([off], const AlertViewer(userId: 'x'), nowMs: t0 + 6 * min), isEmpty);
    });

    test('one-time alerts: arrivals for all, suggestions for the lead, never about yourself', () {
      expect(policy.oneShot(ev('e5', 'DESTINATION_REACHED', user: 'r1', name: 'Priya'), lead)!.title, 'Priya reached the destination');
      expect(policy.oneShot(ev('e6', 'STOP_SUGGESTED', user: 'r1', name: 'Priya', data: {'name': 'Tea stall'}), lead)!.body, startsWith('Tea stall'));
      expect(policy.oneShot(ev('e6', 'STOP_SUGGESTED', user: 'r1', name: 'Priya'), const AlertViewer(userId: 'r2')), isNull);
      expect(policy.oneShot(ev('e7', 'JOINED', user: 'r1', name: 'Priya'), rider), isNull);
      expect(policy.oneShot(ev('e8', 'STOPPED', user: 'r2'), lead), isNull);
    });
  });
}
