// 3.55 "You left the group's route": when to offer the way back to the group, where it goes,
// and RouteGuide.routeToGroup (a personal stop that clears itself near the group or on the plan).
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/domain/places/route_corridor.dart';
import 'package:coroute_app/domain/route/off_route_group.dart';
import 'package:coroute_app/domain/route/route_guide.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';

const t0 = 5000000;
GroupPeer peer(String id, double lat, double lng, {int seen = t0, String name = ''}) =>
    GroupPeer(userId: id, name: name.isEmpty ? id : name, lat: lat, lng: lng, lastSeenMs: seen);

void main() {
  group('OffRouteGroupMonitor', () {
    OffRouteGroupDecision step(OffRouteGroupMonitor m, {required bool off, required int at, int riders = 3, List<GroupPeer>? others}) =>
        m.update(offPlan: off, nowMs: at, riderCount: riders, myLat: 17.0, myLng: 78.0, others: others ?? [peer('a', 17.05, 78.0, seen: at)]);

    test('shown after 20 s off the route, spoken once per departure', () {
      final m = OffRouteGroupMonitor();
      expect(step(m, off: false, at: t0).show, isFalse);
      expect(step(m, off: true, at: t0).show, isFalse);
      expect(step(m, off: true, at: t0 + 19000).show, isFalse);
      final d = step(m, off: true, at: t0 + 20000);
      expect(d.show, isTrue);
      expect(d.speak, isTrue);
      final d2 = step(m, off: true, at: t0 + 25000);
      expect(d2.show, isTrue);
      expect(d2.speak, isFalse, reason: 'said once');
    });

    test('a choice keeps it quiet until back on the route; then a new departure asks again', () {
      final m = OffRouteGroupMonitor();
      step(m, off: true, at: t0);
      expect(step(m, off: true, at: t0 + 21000).show, isTrue);
      m.resolve();
      expect(step(m, off: true, at: t0 + 60000).show, isFalse);
      expect(step(m, off: false, at: t0 + 70000).show, isFalse);
      step(m, off: true, at: t0 + 80000);
      final again = step(m, off: true, at: t0 + 101000);
      expect(again.show, isTrue);
      expect(again.speak, isTrue);
    });

    test('only in a group ride; not when every fresh rider is with me (the group follows me)', () {
      final solo = OffRouteGroupMonitor();
      step(solo, off: true, at: t0, riders: 1);
      expect(step(solo, off: true, at: t0 + 30000, riders: 1).show, isFalse);

      final lead = OffRouteGroupMonitor();
      final close = [peer('a', 17.001, 78.0, seen: t0 + 30000), peer('b', 17.002, 78.0, seen: t0 + 30000)];
      step(lead, off: true, at: t0, others: close);
      expect(step(lead, off: true, at: t0 + 30000, others: close).show, isFalse, reason: 'all within 300 m');
      // An old position of a far rider does not count; a fresh one does.
      final staleFar = [...close, peer('c', 17.1, 78.0, seen: t0 - 600000)];
      expect(step(lead, off: true, at: t0 + 31000, others: staleFar).show, isFalse);
      final freshFar = [...close, peer('c', 17.1, 78.0, seen: t0 + 31000)];
      expect(step(lead, off: true, at: t0 + 32000, others: freshFar).show, isTrue);
    });

    test('target: the point of the plan nearest the closest fresh rider, else that rider', () {
      final plan = RoutePath([for (var i = 0; i <= 20; i++) (17.0 + i * 0.01, 78.0)]);
      final others = [
        peer('far', 17.18, 78.0, seen: t0, name: 'Far Rider'),
        peer('near', 17.05, 78.003, seen: t0, name: 'Ravi Kumar'),
        peer('stale', 17.01, 78.0, seen: t0 - 600000),
      ];
      final t = OffRouteGroupMonitor.target(myLat: 17.04, myLng: 78.01, others: others, nowMs: t0, plan: plan)!;
      expect(t.peer.userId, 'near');
      expect(t.onRoute, isTrue);
      expect(t.lat, closeTo(17.05, 0.0005));
      expect(t.lng, closeTo(78.0, 0.0001), reason: 'snapped onto the plan');
      expect(t.name, 'Group near Ravi Kumar');
      final noPlan = OffRouteGroupMonitor.target(myLat: 17.04, myLng: 78.01, others: others, nowMs: t0)!;
      expect(noPlan.onRoute, isFalse);
      expect(noPlan.lng, 78.003);
      expect(OffRouteGroupMonitor.target(myLat: 17.0, myLng: 78.0, others: [peer('s', 17.1, 78.0, seen: 0)], nowMs: t0), isNull);
    });
  });

  group('RouteGuide.routeToGroup', () {
    final groupLine = [(17.40, 78.37), (17.50, 78.37)];
    ConvoyModel convoy(List<(double, double)> line) => ConvoyModel(
          groupId: 'g1',
          name: 'Group',
          joinCode: 'ABC12',
          createdByUserId: 'lead',
          createdByUserName: 'Lead',
          createdAtEpochMs: 1000,
          route: RouteModel(distanceM: 11000, durationS: 700, polyline: GeoMath.encodePolyline(line)),
          destinationLat: line.last.$1,
          destinationLng: line.last.$2,
          riders: {'me': RiderModel(userId: 'me', name: 'Me', lat: 17.42, lng: 78.39, lastSeenEpochMs: 1000)},
        );

    test('routes through the target first, then clears itself near it', () async {
      final asked = <List<(double, double)>>[];
      final back = RouteModel(distanceM: 3000, durationS: 200, polyline: GeoMath.encodePolyline([(17.42, 78.39), (17.45, 78.37), (17.50, 78.37)]));
      final guide = RouteGuide(fetchRoute: (wp) async {
        asked.add(wp);
        return back;
      });
      guide.setConvoy(convoy(groupLine), 'me');
      guide.onFix(lat: 17.42, lng: 78.39, speedKmh: 40, nowMs: t0, online: true, lowData: false);
      final ok = await guide.routeToGroup(lat: 17.45, lng: 78.37, name: 'Group near Ravi');
      expect(ok, isTrue);
      expect(guide.hasPersonalRoute, isTrue);
      expect(guide.groupTarget?.name, 'Group near Ravi');
      expect(guide.offGroupPlan, isFalse, reason: 'riding back to the group is not leaving it');
      expect(asked.single[1], (17.45, 78.37), reason: 'the target is the first waypoint after me');
      expect(asked.single.last, (17.50, 78.37), reason: 'then on to the destination');

      // Within 150 m of the target: done, the plan takes over.
      guide.onFix(lat: 17.4495, lng: 78.3705, speedKmh: 40, nowMs: t0 + 60000, online: true, lowData: false);
      expect(guide.groupTarget, isNull);
      expect(guide.hasPersonalRoute, isFalse);
    });

    test('a new group plan drops the way back; no fix yet returns false and keeps it pending', () async {
      final guide = RouteGuide(fetchRoute: (wp) async => null);
      guide.setConvoy(convoy(groupLine), 'me');
      expect(await guide.routeToGroup(lat: 17.45, lng: 78.37, name: 'Group'), isFalse);
      expect(guide.groupTarget, isNotNull);
      guide.setConvoy(convoy([(17.40, 78.37), (17.60, 78.37)]), 'me');
      expect(guide.groupTarget, isNull);
      guide.dispose();
    });
  });
}
