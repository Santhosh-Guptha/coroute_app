// Behaviour regressions for the 3.13 route following (found by the
// adversarial behaviour pass, see r313/TEST_BEHAVIOUR.md):
// * a drifting fix on hairpins or a short divided out-and-back road must not
//   pull the match onto the next pass of the road (the purge would remove the
//   part still ahead and remaining km would drop);
// * once I have arrived, riding around the destination town never asks for a
//   new route;
// * a new route that does not start where I am (my road is not on the map)
//   backs off like a failure instead of being asked for every minute;
// * a rider who joined halfway (or whose pass was missed in a dead zone) is
//   never routed back to a stop behind them;
// * request budget over a long off-route stretch, and a parked rider.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/constants/route_constants.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/models/stop_point_model.dart';
import 'package:coroute_app/domain/route/route_plan.dart';
import 'package:coroute_app/domain/route/route_progress.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/presentation/ride/route_guide.dart';

const double lat0 = 17.0;
const double lng0 = 78.0;
const double mPerDegLat = GeoMath.earthRadiusM * math.pi / 180;
final double mPerDegLng = mPerDegLat * math.cos(lat0 * math.pi / 180);

(double, double) at(double north, [double east = 0]) => (lat0 + north / mPerDegLat, lng0 + east / mPerDegLng);

List<(double, double)> straight(double lengthM, {double stepM = 100}) => [
      for (var n = 0.0; n <= lengthM + 0.001; n += stepM) at(n),
    ];

RouteModel routeOf(List<(double, double)> pts, {int durationS = 1200}) {
  var d = 0.0;
  for (var i = 1; i < pts.length; i++) {
    d += GeoMath.haversine(pts[i - 1].$1, pts[i - 1].$2, pts[i].$1, pts[i].$2);
  }
  return RouteModel(distanceM: d, durationS: durationS, polyline: GeoMath.encodePolyline(pts));
}

void main() {
  group('RouteProgress: one drifting fix never jumps to a later pass', () {
    test('hairpins 60 m apart: GPS drift of 38 m toward the next bend keeps the match on my bend', () {
      // Six bends of 700 m, each 60 m north of the one before (a ghat road).
      final pts = <(double, double)>[
        for (var k = 0; k < 6; k++)
          for (var s = 0.0; s <= 700; s += 50) at(k * 60.0, k.isOdd ? 700 - s : s),
      ];
      final p = RouteProgress(pts);
      for (var k = 0; k < 6; k++) {
        for (var s = 0.0; s <= 700; s += 20) {
          final drift = (s % 200) > 150 ? 38.0 : 0.0; // every few fixes the fix drifts uphill
          final (la, ln) = at(k * 60.0 + drift, k.isOdd ? 700 - s : s);
          p.update(la, ln, accuracyM: 10);
          final truth = k * 760.0 + s; // 700 m per bend plus the 60 m turn
          expect(p.matched!.alongM, closeTo(truth, 60), reason: 'bend $k at $s m: the line ahead must not be purged');
        }
      }
    });

    test('short out-and-back on a divided road (turn 1 km ahead, lanes 50 m apart): no snap to the way back', () {
      final pts = [
        for (var i = 0; i <= 20; i++) at(i * 100.0),
        for (var i = 0; i <= 20; i++) at((20 - i) * 100.0, 50),
      ];
      final p = RouteProgress(pts);
      final total = p.lengthM;
      for (var n = 0.0; n <= 1900; n += 50) {
        final drift = (n > 0 && n % 300 == 0) ? 38.0 : 2.0;
        final (la, ln) = at(n, drift);
        p.update(la, ln, accuracyM: 10);
        expect(p.matched!.alongM, closeTo(n, 30), reason: 'outbound at $n m');
        expect(p.remainingM, greaterThan(total - n - 40));
      }
    });
  });

  group('Reroute waypoints skip stops that lie behind me on the plan', () {
    StopPointModel stop(String id, double north, int order, [double east = 0]) {
      final (la, ln) = at(north, east);
      return StopPointModel(stopId: id, name: id, lat: la, lng: ln, category: 'REST', status: 'PLANNED', orderIndex: order);
    }

    ConvoyModel convoyWith(List<StopPointModel> stops) {
      final (dl, dn) = at(20000);
      return ConvoyModel(
        groupId: 'G',
        name: 'Run',
        joinCode: '1',
        createdByUserId: 'lead',
        createdByUserName: 'Lead',
        createdAtEpochMs: 0,
        destinationName: 'Goa',
        destinationLat: dl,
        destinationLng: dn,
        stopPoints: stops,
      );
    }

    test('joined at 8 km: the 3 km stop is left out, the 12 km stop and a stop away from the line stay', () {
      final plan = RouteProgress(straight(20000, stepM: 200));
      final c = convoyWith([stop('early', 3000, 1), stop('aside', 5000, 2, 2000), stop('later', 12000, 3)]);
      final wp = RoutePlan.rerouteWaypoints(c, 'me', 1.0, 2.0, plan: plan, myAlongM: 8000);
      expect(wp, [(1.0, 2.0), at(5000, 2000), at(12000), at(20000)]);
      // Without my position on the plan nothing is guessed: every open stop stays.
      expect(RoutePlan.rerouteWaypoints(c, 'me', 1.0, 2.0).length, 5);
    });

    test('out-and-back: a stop on the way back is still ahead when I am on the way out past it', () {
      final pts = [
        for (var i = 0; i <= 50; i++) at(i * 100.0),
        for (var i = 0; i <= 50; i++) at((50 - i) * 100.0, 20),
      ];
      final plan = RouteProgress(pts);
      final c = convoyWith([stop('lunch', 2000, 1, 20)]); // on the return lane, 2 km from the start
      final wp = RoutePlan.rerouteWaypoints(c, 'me', 1.0, 2.0, plan: plan, myAlongM: 3000);
      expect(wp.length, 3, reason: 'lunch is passed on the way back, so it is ahead');
    });
  });

  group('RouteGuide behaviour', () {
    final planPts = straight(20000, stepM: 200);
    final plan = routeOf(planPts);

    ConvoyModel convoy({RouteModel? route, Map<String, StopArrival> arrivals = const {}, (double, double)? dest}) {
      final (dl, dn) = dest ?? planPts.last;
      return ConvoyModel(
        groupId: 'G',
        name: 'Run',
        joinCode: '1',
        createdByUserId: 'lead',
        createdByUserName: 'Lead',
        createdAtEpochMs: 0,
        destinationName: 'Goa',
        destinationLat: dl,
        destinationLng: dn,
        tripStatus: 'STARTED',
        route: route ?? plan,
        destinationArrivals: arrivals,
        riders: {'me': RiderModel(userId: 'me', name: 'Me', lat: 0, lng: 0, lastSeenEpochMs: 0)},
      );
    }

    late List<int> callTimes;
    late List<Completer<RouteModel?>> pending;
    late RouteGuide g;
    var t = 0;
    RouteModel? Function()? instant; // when set, every request answers at once with this

    setUp(() {
      callTimes = [];
      pending = [];
      t = 0;
      instant = null;
      g = RouteGuide(fetchRoute: (wp) {
        callTimes.add(t);
        final now = instant;
        if (now != null) return Future<RouteModel?>.value(now());
        final c = Completer<RouteModel?>();
        pending.add(c);
        return c.future;
      });
      g.setConvoy(convoy(), 'me');
    });
    tearDown(() => g.dispose());

    void fix(double north, [double east = 0, double speed = 40]) {
      final (la, ln) = at(north, east);
      g.onFix(lat: la, lng: ln, speedKmh: speed, accuracyM: 10, nowMs: t, online: true, lowData: false);
      t += 5000;
    }

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('arrived: riding around the destination town never asks for a new route', () {
      for (var n = 0.0; n <= 19800; n += 100) {
        fix(n, 3);
      }
      expect(g.remainingM, lessThanOrEqualTo(RouteConstants.nearDestinationM));
      // To the hotel: 600 m east of the road, moving, for two minutes.
      for (var i = 0; i < 24; i++) {
        fix(19800 + i * 10.0, 600);
      }
      expect(callTimes, isEmpty);
      expect(g.statusLine, isNull);
      expect(g.hasPersonalRoute, isFalse);
    });

    test('arrived according to the gateway: no reroute anywhere', () {
      g.setConvoy(convoy(arrivals: {'me': const StopArrival(name: 'Me', arrivedAt: 1)}), 'me');
      for (var n = 0.0; n <= 1000; n += 100) {
        fix(n);
      }
      for (var n = 1100.0; n <= 4000; n += 100) {
        fix(n, 400);
      }
      expect(callTimes, isEmpty);
      expect(g.handlesOffRoute, isFalse, reason: 'the usual off-route alert shows again');
    });

    test('a loop ride (start next to the destination) still reroutes: arrival is measured along the route', () {
      final loop = <(double, double)>[
        for (var n = 0.0; n <= 5000; n += 200) at(n),
        for (var n = 5000.0; n >= 0; n -= 200) at(n, 30),
      ];
      g.setConvoy(convoy(route: routeOf(loop), dest: loop.last), 'me');
      for (var n = 0.0; n <= 1000; n += 100) {
        fix(n, 2);
      }
      expect(g.remainingM, greaterThan(8000));
      for (var n = 1100.0; callTimes.isEmpty && n <= 3000; n += 100) {
        fix(n, 400);
      }
      expect(callTimes.length, 1);
    });

    test('a new route that does not start where I am backs off like a failure (still shown)', () async {
      for (var n = 0.0; n <= 1000; n += 100) {
        fix(n);
      }
      var n = 1100.0;
      while (callTimes.isEmpty) {
        fix(n, 300);
        n += 100;
      }
      // The route service snapped me to a road 2.7 km away (a track not on the map).
      pending.single.complete(routeOf([at(n, 3000), at(20000)]));
      await settle();
      expect(g.hasPersonalRoute, isTrue);
      expect(g.policy.failures, 1);
      while (callTimes.length < 2) {
        fix(n, 300);
        n += 100;
      }
      expect(callTimes[1] - callTimes[0], greaterThanOrEqualTo(RouteConstants.rerouteMinInterval.inMilliseconds));
      pending.last.complete(routeOf([at(n, 3000), at(20000)]));
      await settle();
      expect(g.policy.failures, 2);
      while (callTimes.length < 3) {
        fix(n, 300);
        n += 100;
      }
      expect(callTimes[2] - callTimes[1], greaterThanOrEqualTo(2 * RouteConstants.rerouteMinInterval.inMilliseconds));
    });

    test('30 minutes off the route with the service down: at most 6 requests, never two at once', () async {
      instant = () => null;
      for (var n = 0.0; n <= 1000; n += 100) {
        fix(n);
      }
      final start = t;
      var east = 300.0;
      while (t - start < const Duration(minutes: 30).inMilliseconds) {
        fix(1500, east); // a long parallel road far from the plan
        east += 50;
        await settle();
      }
      // 60, 120, 240, 480, 600 s apart.
      expect(callTimes.length, lessThanOrEqualTo(6));
      for (var i = 1; i < callTimes.length; i++) {
        expect(callTimes[i] - callTimes[i - 1], greaterThanOrEqualTo(RouteConstants.rerouteMinInterval.inMilliseconds));
      }
      expect(g.policy.inFlight, isFalse);
    });

    test('parked at a dhaba 250 m off the road with GPS jitter: no request, no status', () {
      for (var n = 0.0; n <= 3000; n += 100) {
        fix(n);
      }
      // Rolled in slowly (under 5 km/h), then parked for 20 minutes with jittery fixes.
      for (var i = 0; i < 240; i++) {
        fix(3000 + (i.isEven ? 8 : -8), 250 + (i % 3) * 6, (i % 4).toDouble());
      }
      expect(callTimes, isEmpty);
      expect(g.statusLine, isNull);
      expect(g.remainingM, closeTo(17000, 40), reason: 'remaining km stays where I left the road');
    });
  });
}
