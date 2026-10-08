import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/constants/route_constants.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/ui/ui.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/models/stop_point_model.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/domain/notify/alert_policy.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/domain/route/off_route_detector.dart';
import 'package:coroute_app/domain/route/reroute_policy.dart';
import 'package:coroute_app/domain/route/route_plan.dart';
import 'package:coroute_app/domain/route/route_progress.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/presentation/alerts/alert_tiers.dart';
import 'package:coroute_app/presentation/ride/map_focus.dart';
import 'package:coroute_app/presentation/ride/meet_here_sheet.dart';
import 'package:coroute_app/presentation/ride/route_guide.dart';

// Positions in metres north and east of a fixed origin, so the expected
// distances can be read straight from the test.
const double lat0 = 17.0;
const double lng0 = 78.0;
const double mPerDegLat = GeoMath.earthRadiusM * math.pi / 180;
final double mPerDegLng = mPerDegLat * math.cos(lat0 * math.pi / 180);

(double, double) at(double north, [double east = 0]) => (lat0 + north / mPerDegLat, lng0 + east / mPerDegLng);

/// A straight line north from 0 to [lengthM], one point every [stepM].
List<(double, double)> straight(double lengthM, {double stepM = 100}) => [
      for (var n = 0.0; n <= lengthM + 0.001; n += stepM) at(n),
    ];

RouteModel routeOf(List<(double, double)> pts, {double? distanceM, int durationS = 1200}) {
  var d = 0.0;
  for (var i = 1; i < pts.length; i++) {
    d += GeoMath.haversine(pts[i - 1].$1, pts[i - 1].$2, pts[i].$1, pts[i].$2);
  }
  return RouteModel(distanceM: distanceM ?? d, durationS: durationS, polyline: GeoMath.encodePolyline(pts));
}

void main() {
  group('RouteProgress', () {
    test('straight line: along, distance off, remaining and the trimmed line', () {
      final p = RouteProgress(straight(5000));
      final m = p.update(at(1234, 10).$1, at(1234, 10).$2)!;
      expect(m.onLine, isTrue);
      expect(m.alongM, closeTo(1234, 3));
      expect(m.offM, closeTo(10, 1));
      expect(p.remainingM, closeTo(5000 - 1234, 4));
      final rest = p.remainingLine();
      expect(rest.first.$1, closeTo(m.lat, 1e-9));
      expect(rest.length, p.points.length - (m.index + 1) + 1);
      expect(rest.last, p.points.last);
    });

    test('each fix searches only a window around the last match, not the whole line', () {
      final p = RouteProgress(straight(20000)); // 200 segments
      final (a, b) = at(1000, 5);
      p.update(a, b); // first fix: whole line
      for (var n = 1100.0; n <= 3000; n += 100) {
        final (la, ln) = at(n, 5);
        final m = p.update(la, ln)!;
        expect(m.alongM, closeTo(n, 3));
        expect(p.lastSearchWasGlobal, isFalse);
        expect(p.lastSearchCount, lessThan(40), reason: 'window of ${RouteConstants.matchAheadM} m, not 200 segments');
      }
    });

    test('curve: progress follows the bend', () {
      // Quarter circle of radius 1 km, 50 points.
      final pts = [
        for (var i = 0; i <= 50; i++) at(1000 * math.sin(i * math.pi / 100), 1000 - 1000 * math.cos(i * math.pi / 100)),
      ];
      final p = RouteProgress(pts);
      const quarter = 1000 * math.pi / 2;
      double last = -1;
      for (var i = 0; i <= 50; i += 5) {
        final a = i * math.pi / 100;
        final (la, ln) = at(990 * math.sin(a), 1000 - 990 * math.cos(a)); // 10 m inside the bend
        final m = p.update(la, ln)!;
        expect(m.onLine, isTrue);
        expect(m.offM, closeTo(10, 2));
        expect(m.alongM, greaterThanOrEqualTo(last));
        last = m.alongM;
      }
      expect(last, closeTo(quarter, 5));
    });

    test('out-and-back road: never snaps to the return leg on the way out, follows it after the U-turn', () {
      // North 2 km, U-turn, back south 15 m to the east (a divided road).
      final pts = [
        for (var i = 0; i <= 20; i++) at(i * 100.0),
        for (var i = 0; i <= 20; i++) at((20 - i) * 100.0, 15),
      ];
      final p = RouteProgress(pts);
      final total = p.lengthM;
      for (var n = 0.0; n <= 1950; n += 50) {
        final (la, ln) = at(n, 2);
        final m = p.update(la, ln)!;
        expect(m.alongM, closeTo(n, 3), reason: 'outbound at $n m');
      }
      for (var n = 1900.0; n >= 0; n -= 100) {
        final (la, ln) = at(n, 14);
        final m = p.update(la, ln)!;
        expect(m.alongM, closeTo(total - n, 4), reason: 'return at $n m');
      }
      expect(p.remainingM, closeTo(0, 4));
    });

    test('loop that crosses itself: the earlier pass wins until it is really passed', () {
      // North 1 km, east 300 m, south 500 m, west 600 m: crosses the first leg at north 500.
      final pts = <(double, double)>[
        for (var n = 0.0; n <= 1000; n += 50) at(n),
        for (var e = 50.0; e <= 300; e += 50) at(1000, e),
        for (var n = 950.0; n >= 500; n -= 50) at(n, 300),
        for (var e = 250.0; e >= -300; e -= 50) at(500, e),
      ];
      final p = RouteProgress(pts);
      final (a, b) = at(400, 3);
      p.update(a, b);
      final (c, d) = at(500, 3); // the crossing, first time
      expect(p.update(c, d)!.alongM, closeTo(500, 4));
      // Ride the loop.
      for (var n = 600.0; n <= 1000; n += 100) {
        final (la, ln) = at(n, 3);
        p.update(la, ln);
      }
      for (var e = 100.0; e <= 300; e += 100) {
        final (la, ln) = at(1000, e);
        p.update(la, ln);
      }
      for (var n = 900.0; n >= 500; n -= 100) {
        final (la, ln) = at(n, 300);
        p.update(la, ln);
      }
      for (var e = 200.0; e >= 0; e -= 50) {
        final (la, ln) = at(500, e);
        p.update(la, ln);
      }
      // At the crossing the second time: the later pass (1000 + 300 + 500 + 300 = 2100 m).
      expect(p.matched!.alongM, closeTo(2100, 5));
    });

    test('a fix far from the line is not matched; the purge stays where I left the line', () {
      final p = RouteProgress(straight(5000));
      final (a, b) = at(1000, 5);
      p.update(a, b);
      final (c, d) = at(1300, 400);
      final m = p.update(c, d)!;
      expect(m.onLine, isFalse);
      expect(m.offM, greaterThan(350));
      expect(p.matched!.alongM, closeTo(1000, 3));
      expect(p.remainingM, closeTo(4000, 4));
    });

    test('rejoining much farther ahead is found by the occasional whole-line search', () {
      final p = RouteProgress(straight(20000));
      final (a, b) = at(1000);
      p.update(a, b);
      // A bypass 500 m to the east, then back on the route at 9 km.
      for (var n = 1500.0; n <= 8500; n += 500) {
        final (la, ln) = at(n, 500);
        expect(p.update(la, ln)!.onLine, isFalse);
      }
      final (c, d) = at(9000, 5);
      final m = p.update(c, d)!;
      expect(m.onLine, isTrue);
      expect(m.alongM, closeTo(9000, 3));
    });

    test('poor accuracy widens "here" but a jittery stationary rider does not move backwards', () {
      final p = RouteProgress(straight(5000, stepM: 20));
      final (a, b) = at(2000, 3);
      p.update(a, b, accuracyM: 60);
      for (var i = 0; i < 10; i++) {
        final (la, ln) = at(2000 + (i.isEven ? 8 : -8), i.isEven ? 20 : -20);
        final m = p.update(la, ln, accuracyM: 60)!;
        expect(m.alongM, closeTo(2000, RouteConstants.matchBackM));
      }
      final (c, d) = at(2100, 3);
      expect(p.update(c, d, accuracyM: 60)!.alongM, closeTo(2100, 3));
    });

    test('locateAhead orders places along the line', () {
      final p = RouteProgress(straight(10000));
      expect(p.locateAhead(at(3000, 200).$1, at(3000, 200).$2)!.alongM, closeTo(3000, 3));
      // A place behind the lead is put at the start of the search (not before it).
      final behind = p.locateAhead(at(3000).$1, at(3000).$2, fromAlongM: 5000)!.alongM;
      expect(behind, greaterThanOrEqualTo(5000 - RouteConstants.matchBackM - 1));
      expect(behind, lessThanOrEqualTo(5001));
    });

    test('lines with fewer than two points are ignored', () {
      final p = RouteProgress([at(0)]);
      expect(p.isUsable, isFalse);
      expect(p.update(lat0, lng0), isNull);
      expect(p.remainingLine(), isEmpty);
    });
  });

  group('OffRouteDetector', () {
    test('needs ${RouteConstants.offRouteFixes} moving fixes AND ${RouteConstants.offRouteFor.inSeconds} s', () {
      final d = OffRouteDetector();
      expect(d.onFix(tsMs: 0, offM: 300, speedKmh: 40), OffRouteState.leaving);
      expect(d.onFix(tsMs: 5000, offM: 300, speedKmh: 40), OffRouteState.leaving);
      expect(d.onFix(tsMs: 10000, offM: 300, speedKmh: 40), OffRouteState.leaving, reason: '3 fixes but only 10 s');
      expect(d.onFix(tsMs: 15000, offM: 300, speedKmh: 40), OffRouteState.leaving);
      expect(d.onFix(tsMs: 20000, offM: 300, speedKmh: 40), OffRouteState.offRoute);
    });

    test('one fix back within the limit starts the count again', () {
      final d = OffRouteDetector();
      d.onFix(tsMs: 0, offM: 300, speedKmh: 40);
      d.onFix(tsMs: 10000, offM: 300, speedKmh: 40);
      expect(d.onFix(tsMs: 15000, offM: 100, speedKmh: 40), OffRouteState.onRoute);
      expect(d.onFix(tsMs: 25000, offM: 300, speedKmh: 40), OffRouteState.leaving);
      expect(d.onFix(tsMs: 30000, offM: 300, speedKmh: 40), OffRouteState.leaving);
    });

    test('long fix gaps: the time rule is met but the fix count is not', () {
      final d = OffRouteDetector();
      d.onFix(tsMs: 0, offM: 300, speedKmh: 40);
      expect(d.onFix(tsMs: 60000, offM: 300, speedKmh: 40), OffRouteState.leaving);
      expect(d.onFix(tsMs: 61000, offM: 300, speedKmh: 40), OffRouteState.offRoute);
    });

    test('a stationary rider is never put off route (fixes neither count nor reset)', () {
      final d = OffRouteDetector();
      for (var t = 0; t < 600000; t += 5000) {
        expect(d.onFix(tsMs: t, offM: 400, speedKmh: 1), OffRouteState.onRoute);
      }
      d.onFix(tsMs: 600000, offM: 400, speedKmh: 30);
      d.onFix(tsMs: 605000, offM: 400, speedKmh: 0); // red light
      d.onFix(tsMs: 610000, offM: 400, speedKmh: 30);
      expect(d.onFix(tsMs: 620000, offM: 400, speedKmh: 30), OffRouteState.offRoute);
    });

    test('poor accuracy raises the limit; useless fixes are ignored', () {
      expect(OffRouteDetector.limitFor(10), RouteConstants.offRouteM);
      expect(OffRouteDetector.limitFor(90), 180);
      final d = OffRouteDetector();
      for (var t = 0; t <= 40000; t += 5000) {
        expect(d.onFix(tsMs: t, offM: 170, accuracyM: 90, speedKmh: 40), OffRouteState.onRoute);
      }
      for (var t = 0; t <= 40000; t += 5000) {
        expect(d.onFix(tsMs: t, offM: 900, accuracyM: 150, speedKmh: 40), OffRouteState.onRoute);
      }
    });

    test('rejoin: close to the line for ${RouteConstants.rejoinFixes} moving fixes, going forward', () {
      final d = OffRouteDetector(initial: OffRouteState.offRoute);
      expect(d.onFix(tsMs: 0, offM: 120, alongM: 1000, speedKmh: 40), OffRouteState.offRoute, reason: 'within the off limit but not close');
      expect(d.onFix(tsMs: 5000, offM: 10, alongM: 1000, speedKmh: 40), OffRouteState.offRoute);
      expect(d.onFix(tsMs: 10000, offM: 10, alongM: 1100, speedKmh: 40), OffRouteState.onRoute);
    });

    test('riding the planned road backwards is not a rejoin', () {
      final d = OffRouteDetector(initial: OffRouteState.offRoute);
      for (var i = 0; i < 6; i++) {
        expect(d.onFix(tsMs: i * 5000, offM: 5, alongM: 3000 - i * 100.0, speedKmh: 40), OffRouteState.offRoute);
      }
    });
  });

  group('ReroutePolicy', () {
    test('one request at a time, at most one per minute', () {
      final p = ReroutePolicy();
      expect(p.canRequest(nowMs: 0, online: true, lowData: false), isTrue);
      p.started(0);
      expect(p.canRequest(nowMs: 120000, online: true, lowData: false), isFalse, reason: 'in flight');
      p.finished(ok: true);
      expect(p.canRequest(nowMs: 59999, online: true, lowData: false), isFalse);
      expect(p.canRequest(nowMs: 60000, online: true, lowData: false), isTrue);
    });

    test('data saver: at most one per 3 minutes', () {
      final p = ReroutePolicy()..started(0);
      p.finished(ok: true);
      expect(p.canRequest(nowMs: 179999, online: true, lowData: true), isFalse);
      expect(p.canRequest(nowMs: 180000, online: true, lowData: true), isTrue);
    });

    test('offline: none; failures back off up to the cap; success resets', () {
      final p = ReroutePolicy();
      expect(p.canRequest(nowMs: 0, online: false, lowData: false), isFalse);
      var t = 0;
      final waits = <int>[];
      for (var i = 0; i < 6; i++) {
        p.started(t);
        p.finished(ok: false);
        waits.add(p.waitFor(lowData: false).inSeconds);
        t += p.waitFor(lowData: false).inMilliseconds;
        expect(p.canRequest(nowMs: t - 1, online: true, lowData: false), isFalse);
        expect(p.canRequest(nowMs: t, online: true, lowData: false), isTrue);
      }
      expect(waits, [60, 120, 240, 480, 600, 600]);
      p.started(t);
      p.finished(ok: true);
      expect(p.waitFor(lowData: false), RouteConstants.rerouteMinInterval);
    });
  });

  group('RoutePlan', () {
    StopPointModel stop(String id, double north, {String category = 'REST', bool visited = false, String status = 'PLANNED', Map<String, StopArrival> arrivals = const {}, int order = 0}) {
      final (la, ln) = at(north);
      return StopPointModel(stopId: id, name: id, lat: la, lng: ln, category: category, isVisited: visited, status: status, arrivals: arrivals, orderIndex: order);
    }

    ConvoyModel convoyWith(List<StopPointModel> stops, {RouteModel? route}) {
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
        route: route,
      );
    }

    test('a personal route goes through the stops I still have to ride to, then the destination', () {
      final c = convoyWith([
        stop('visited', 2000, visited: true, order: 1),
        stop('reached', 4000, arrivals: const {'me': StopArrival(arrivedAt: 5)}, order: 2),
        stop('suggested', 5000, status: 'SUGGESTED', order: 3),
        stop('ahead', 8000, arrivals: const {'other': StopArrival(passedAt: 5)}, order: 4),
        stop('skipped', 9000, status: 'SKIPPED', order: 5),
        stop('later', 12000, order: 6),
      ]);
      final wp = RoutePlan.rerouteWaypoints(c, 'me', 1.0, 2.0);
      expect(wp.length, 4);
      expect(wp.first, (1.0, 2.0));
      expect(wp[1], at(8000));
      expect(wp[2], at(12000));
      expect(wp.last, (c.destinationLat, c.destinationLng));
    });

    test('never more than ${RouteConstants.maxWaypoints} points, the destination always last', () {
      final c = convoyWith([for (var i = 0; i < 30; i++) stop('s$i', 100.0 * (i + 1), order: i + 1)]);
      final wp = RoutePlan.rerouteWaypoints(c, 'me', 1.0, 2.0);
      expect(wp.length, RouteConstants.maxWaypoints);
      expect(wp.last, (c.destinationLat, c.destinationLng));
      expect(RoutePlan.rerouteWaypoints(
        ConvoyModel(groupId: 'G', name: 'x', joinCode: '1', createdByUserId: 'a', createdByUserName: 'A', createdAtEpochMs: 0),
        'me', 1.0, 2.0,
      ), isEmpty);
    });

    test('a meeting point goes before the next stop farther along and replaces the open one', () {
      final c = convoyWith([
        stop('fuel', 5000, category: 'FUEL', order: 1),
        stop('meet-old', 8000, category: 'MEETING', order: 2),
        stop('lunch', 12000, category: 'FOOD', order: 3),
      ]);
      final plan = RouteProgress(straight(20000));
      final m = RoutePlan.meetingPlacement(c, lat: at(10000, 50).$1, lng: at(10000, 50).$2, plan: plan);
      expect(m.insertBefore, 'lunch');
      expect(m.replaces?.stopId, 'meet-old');
      final early = RoutePlan.meetingPlacement(c, lat: at(3000).$1, lng: at(3000).$2, plan: plan);
      expect(early.insertBefore, 'fuel');
      final late = RoutePlan.meetingPlacement(c, lat: at(15000).$1, lng: at(15000).$2, plan: plan);
      expect(late.insertBefore, isNull, reason: 'after the last stop: appended');
      final noPlan = RoutePlan.meetingPlacement(convoyWith([stop('fuel', 5000)]), lat: 1, lng: 2);
      expect(noPlan.insertBefore, isNull);
      expect(noPlan.replaces, isNull);
    });
  });

  group('RouteGuide (fixes -> detector -> route service -> personal route)', () {
    final planPts = straight(20000, stepM: 200);
    final plan = routeOf(planPts, durationS: 1200);

    ConvoyModel convoy({RouteModel? route, String status = 'STARTED'}) {
      final (dl, dn) = planPts.last;
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
        tripStatus: status,
        route: route ?? plan,
        riders: {'me': RiderModel(userId: 'me', name: 'Me', lat: 0, lng: 0, lastSeenEpochMs: 0)},
      );
    }

    // The personal route the fake service returns: 300 m east, then back to the destination.
    final detour = routeOf([at(1400, 300), at(19000, 300), at(20000)], durationS: 1100);

    late List<List<(double, double)>> calls;
    late List<Completer<RouteModel?>> pending;
    late RouteGuide g;
    late int notified;
    var t = 0;

    setUp(() {
      calls = [];
      pending = [];
      notified = 0;
      t = 0;
      g = RouteGuide(fetchRoute: (wp) {
        calls.add(wp);
        final c = Completer<RouteModel?>();
        pending.add(c);
        return c.future;
      });
      g.addListener(() => notified++);
      g.setConvoy(convoy(), 'me');
    });
    tearDown(() => g.dispose());

    void fix(double north, [double east = 0, double speed = 40, bool online = true, bool lowData = false, double acc = 10]) {
      final (la, ln) = at(north, east);
      g.onFix(lat: la, lng: ln, speedKmh: speed, accuracyM: acc, nowMs: t, online: online, lowData: lowData);
      t += 5000;
    }

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    /// On the route to 1 km, then 300 m east until the guide asks for a route.
    void leave() {
      for (var n = 0.0; n <= 1000; n += 100) {
        fix(n);
      }
      for (var n = 1100.0; calls.isEmpty && n < 3000; n += 100) {
        fix(n, 300);
      }
    }

    test('on the route: remaining and ETA follow the part still to ride, quietly', () {
      for (var n = 0.0; n <= 5000; n += 100) {
        fix(n, 5);
      }
      expect(g.started, isTrue);
      expect(g.remainingM, closeTo(15000, 10));
      expect(g.eta!.inSeconds, closeTo(900, 2), reason: '15 of 20 km at 20 km per 1200 s');
      expect(g.statusLine, isNull);
      expect(calls, isEmpty);
      expect(g.active!.matched!.alongM, closeTo(5000, 5));
    });

    test('leaving the route fetches a personal route from here through what is left; no popups, one status line', () async {
      leave();
      expect(calls.length, 1);
      expect(calls.single.first, at(1500, 300), reason: 'from where I am');
      expect(calls.single.last, planPts.last);
      expect(calls.single.length, 2, reason: 'no stops: me and the destination');
      expect(g.statusLine, 'Off the planned route, finding a new route');
      pending.single.complete(detour);
      await settle();
      expect(g.hasPersonalRoute, isTrue);
      expect(g.statusLine, 'New route, 19 km');
      expect(g.activeRoute, same(detour));
      expect(g.remainingM, lessThan(detour.distanceM));
      // The group plan itself is untouched.
      expect(g.plan!.points.length, planPts.length);
    });

    test('back on the planned route drops the personal route', () async {
      leave();
      pending.single.complete(detour);
      await settle();
      for (var n = 2000.0; n <= 4000; n += 100) {
        fix(n, 300);
      }
      expect(g.hasPersonalRoute, isTrue);
      fix(4200, 3);
      fix(4300, 3);
      expect(g.hasPersonalRoute, isFalse);
      expect(g.statusLine, 'Back on the planned route');
      expect(g.active, same(g.plan));
      expect(g.remainingM, closeTo(15700, 10));
      // The notice goes away by itself on a later fix (no timer).
      t += RouteConstants.backOnRouteNoticeFor.inMilliseconds;
      fix(4400, 3);
      expect(g.statusLine, isNull);
    });

    test('throttled: one request at a time, one a minute, back-off after failures', () async {
      leave();
      final first = t - 5000;
      for (var n = 1600.0; n <= 2400; n += 100) {
        fix(n, 300);
      }
      expect(calls.length, 1, reason: 'in flight');
      pending.single.complete(null); // failed
      await settle();
      expect(g.statusLine, 'Off the planned route');
      while (t - first < 60000) {
        fix(2500, 300 + t / 1000);
      }
      expect(calls.length, 1, reason: 'not within a minute of the first');
      fix(2500, 300 + t / 1000);
      expect(calls.length, 2);
      final second = t - 5000;
      pending.last.complete(null); // failed again: the wait doubles
      await settle();
      while (t - second < 120000) {
        fix(2500, 300 + t / 1000);
      }
      expect(calls.length, 2, reason: '2 minutes after a second failure');
      fix(2500, 300 + t / 1000);
      expect(calls.length, 3);
    });

    test('offline: no request, the status says it; data saver: one per 3 minutes', () async {
      for (var n = 0.0; n <= 1000; n += 100) {
        fix(n);
      }
      for (var n = 1100.0; n <= 2000; n += 100) {
        fix(n, 300, 40, false);
      }
      expect(calls, isEmpty);
      expect(g.statusLine, 'Off the planned route');
      fix(2100, 300, 40, true, true);
      expect(calls.length, 1);
      pending.single.complete(null);
      await settle();
      final start = t - 5000;
      while (t - start < 170000) {
        fix(2200, 300 + t / 1000, 40, true, true);
      }
      expect(calls.length, 1);
      while (t - start < 185000) {
        fix(2200, 300 + t / 1000, 40, true, true);
      }
      expect(calls.length, 2);
    });

    test('before reaching the planned route (riding to the start) nothing is purged or fetched', () {
      for (var n = 0.0; n < 3000; n += 100) {
        fix(n, 2000);
      }
      expect(g.started, isFalse);
      expect(g.remainingM, isNull);
      expect(calls, isEmpty);
    });

    test('a paused ride or an approximate plan never reroutes', () {
      g.setConvoy(convoy(status: 'PAUSED'), 'me');
      leave();
      expect(calls, isEmpty);
      g.setConvoy(convoy(route: RouteModel(distanceM: plan.distanceM, durationS: 1200, polyline: plan.polyline, approximate: true)), 'me');
      for (var n = 3000.0; n < 4000; n += 100) {
        fix(n, 300);
      }
      expect(calls, isEmpty);
      expect(g.handlesOffRoute, isFalse);
    });

    test('a new group plan drops the personal route; the same plan again (reconnect) keeps it', () async {
      leave();
      pending.single.complete(detour);
      await settle();
      g.setConvoy(convoy(route: routeOf(planPts, durationS: 1200)), 'me'); // same content, new object
      expect(g.hasPersonalRoute, isTrue);
      g.setConvoy(convoy(route: routeOf(straight(21000, stepM: 200))), 'me');
      expect(g.hasPersonalRoute, isFalse);
    });

    test('a result that arrives after the rider came back, or after dispose, is ignored', () async {
      leave();
      fix(1700, 3);
      fix(1800, 3);
      fix(1900, 3);
      expect(g.statusLine, 'Back on the planned route');
      pending.single.complete(detour);
      await settle();
      expect(g.hasPersonalRoute, isFalse);

      final other = RouteGuide(fetchRoute: (wp) {
        final c = Completer<RouteModel?>();
        pending.add(c);
        return c.future;
      });
      other.setConvoy(convoy(), 'me');
      var n = 0.0;
      while (pending.length < 2 && n < 3000) {
        final (la, ln) = n <= 1000 ? at(n) : at(n, 300);
        other.onFix(lat: la, lng: ln, speedKmh: 40, accuracyM: 10, nowMs: t, online: true, lowData: false);
        t += 5000;
        n += 100;
      }
      expect(pending.length, 2);
      other.dispose();
      pending.last.complete(detour);
      await settle();
      expect(other.hasPersonalRoute, isFalse);
    });

    test('no work without a new fix: the same position twice is skipped', () {
      fix(500);
      final before = notified;
      final (la, ln) = at(500);
      for (var i = 0; i < 5; i++) {
        g.onFix(lat: la, lng: ln, speedKmh: 40, nowMs: t + i, online: true, lowData: false);
      }
      expect(notified, before);
    });
  });

  group('Meeting point alert', () {
    const t0 = 1800000000000;
    TimelineEventModel added(String id, {String category = 'MEETING', String user = 'lead', int atMs = 0, String name = 'Toll gate'}) => TimelineEventModel(
          eventId: id,
          groupId: 'G',
          userId: user,
          userName: 'Lead',
          type: 'STOP_ADDED',
          startedAt: t0 + atMs,
          lat: 17.03,
          lng: 78.0,
          placeName: name,
          data: {'name': name, 'category': category},
        );

    test('"Meeting point changed" with the distance, important, for everyone but the lead who set it', () {
      final policy = AlertPolicy();
      const rider = AlertViewer(userId: 'r1', lat: 17.0, lng: 78.0);
      final a = policy.oneShot(added('e1'), rider)!;
      expect(a.title, 'Meeting point changed');
      expect(a.body, 'Toll gate, 3.3 km from you.');
      expect(a.key, AlertPolicy.meetingKey);
      expect(tierFor(a), AlertTier.important);
      expect(policy.oneShot(added('e1'), const AlertViewer(userId: 'lead', isLead: true)), isNull);
      expect(policy.oneShot(added('e1'), const AlertViewer(userId: 'r1'))!.body, 'Toll gate.', reason: 'my position unknown');
      expect(AlertPolicy.showWhileOpen(a), isFalse, reason: 'the ride screen shows it already');
      final other = policy.oneShot(added('e2', category: 'FUEL'), rider)!;
      expect(other.channel, AlertChannel.activity);
      expect(tierFor(other), AlertTier.normal);
    });

    test('a newer meeting point replaces the older alert (one row, the newest)', () {
      const rider = AlertViewer(userId: 'r1', lat: 17.0, lng: 78.0);
      final list = inAppAlerts([added('e1', name: 'Old place'), added('e2', atMs: 60000, name: 'New place')], rider, nowMs: t0 + 120000);
      final meet = list.where((a) => a.key == AlertPolicy.meetingKey).toList();
      expect(meet.length, 1);
      expect(meet.single.spec.body, startsWith('New place'));
    });
  });

  group('Share my ETA', () {
    test('plain text, no link, no coordinates', () {
      expect(RideFacts.shareEtaText(destinationName: 'Goa', remainingM: 42000, arrival: '4:35 PM'),
          'On the way to Goa with CoRoute. 42 km left, arriving about 4:35 PM.');
      expect(RideFacts.shareEtaText(destinationName: '', remainingM: 800), 'On the way with CoRoute. 800 m left.');
      expect(RideFacts.shareEtaText(destinationName: 'Goa', arrival: '16:35'), 'On the way to Goa with CoRoute. Arriving about 16:35.');
      expect(RideFacts.shareEtaText(destinationName: 'Goa'), 'On the way to Goa with CoRoute.');
    });
  });

  group('Show on map hand-off', () {
    test('a request notifies once and is taken once', () {
      final f = MapFocus();
      var n = 0;
      f.addListener(() => n++);
      f.showRider('u1');
      f.showRider('u1');
      expect(n, 2, reason: 'asking twice for the same rider still notifies');
      expect(f.take()?.userId, 'u1');
      expect(f.take(), isNull);
      f.dispose();
    });
  });

  group('Meet here sheet', () {
    Future<MeetHereResult?> open(WidgetTester tester, Future<String?> Function() name, {double scale = 1.0}) async {
      AppTheme.use(AppPalette.dark);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      MeetHereResult? result;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(AppPalette.dark),
        // Above the navigator, so the sheet gets the large text too.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showMeetHereSheet(context, placeName: name, distanceFromMeM: 3400, replacesName: 'Toll gate');
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('3.4 km from you'), findsOneWidget);
      expect(find.textContaining('Replaces the meeting point at Toll gate'), findsOneWidget);
      await tester.ensureVisible(find.text('Meet here'));
      await tester.tap(find.text('Meet here'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('shows the place name and distance; "Meet here" returns the name', (tester) async {
      final r = await open(tester, () async => 'HP fuel station');
      expect(r?.action, MeetHereAction.meet);
      expect(r?.name, 'HP fuel station');
    });

    testWidgets('works without a place name, at 320 dp and 1.3x text', (tester) async {
      final r = await open(tester, () async => null, scale: 1.3);
      expect(r?.action, MeetHereAction.meet);
      expect(r?.name, '');
    });
  });
}
