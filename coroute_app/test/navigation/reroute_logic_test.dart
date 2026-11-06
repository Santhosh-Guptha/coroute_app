// Pure logic of leaving the route and asking for a new one
// (lib/domain/navigation): the off-route monitor (limits, hold times,
// hysteresis, GPS jitter, stopped and bad fixes), the request scheduler
// (single flight, 15 s spacing, back-off, give up after 3 failures, offline)
// and the prompt gate (one line per departure, 60 s quiet after a new route,
// one off-route line per 2 minutes).
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/navigation/heading_tracker.dart';
import 'package:coroute_app/domain/navigation/nav_prompts.dart';
import 'package:coroute_app/domain/navigation/off_route_monitor.dart';
import 'package:coroute_app/domain/navigation/reroute_controller.dart';
import 'package:coroute_app/domain/navigation/reroute_rules.dart';
import 'package:coroute_app/domain/navigation/reroute_scheduler.dart';

NavFix f(int sec, {double kmh = 40, double? acc = 8, double? heading}) =>
    NavFix(tsMs: sec * 1000, speedKmh: kmh, accuracyM: acc, headingDeg: heading);

void main() {
  group('OffRouteMonitor', () {
    test('limits: 40 m or 2.5 x accuracy; 120 m at once; back within 25 m (up to 40 m with poor GPS)', () {
      expect(RerouteRules.offLimitFor(8), 40);
      expect(RerouteRules.offLimitFor(30), 75);
      expect(RerouteRules.offNowLimitFor(8), 120);
      expect(RerouteRules.offNowLimitFor(50), 125);
      expect(RerouteRules.rejoinLimitFor(8), 25);
      expect(RerouteRules.rejoinLimitFor(35), 35);
      expect(RerouteRules.rejoinLimitFor(90), 40);
    });

    test('beyond 40 m and heading away: off after 8 s of moving time, not before', () {
      final m = OffRouteMonitor();
      for (var s = 0; s < 8; s++) {
        expect(m.onFix(f(s, heading: 90), offM: 50 + s * 4.0, routeBearingDeg: 0), FollowEvent.none, reason: '$s s');
        expect(m.state, FollowState.leaving);
      }
      expect(m.onFix(f(8, heading: 90), offM: 85, routeBearingDeg: 0), FollowEvent.wentOff);
      expect(m.isOff, isTrue);
    });

    test('farther than 120 m on one good moving fix: off at once', () {
      final m = OffRouteMonitor();
      expect(m.onFix(f(0), offM: 130), FollowEvent.wentOff);
    });

    test('parallel at 50-60 m in the same direction (service road, GPS offset on a divided highway): stays on', () {
      final m = OffRouteMonitor();
      for (var s = 0; s < 120; s++) {
        expect(m.onFix(f(s, heading: 2), offM: s.isEven ? 50 : 58, routeBearingDeg: 0), FollowEvent.none);
      }
      expect(m.isOff, isFalse);
    });

    test('direction unknown: a distance that keeps growing counts as heading away', () {
      final m = OffRouteMonitor();
      FollowEvent? last;
      for (var s = 0; s <= 8; s++) {
        last = m.onFix(f(s, heading: null), offM: 45 + s * 3.0);
      }
      expect(last, FollowEvent.wentOff);
    });

    test('GPS jitter around the limit never goes off (one fix back inside starts over)', () {
      final m = OffRouteMonitor();
      for (var s = 0; s < 300; s++) {
        final off = s % 3 == 2 ? 30.0 : 70.0; // every third fix is back within 40 m
        expect(m.onFix(f(s, heading: 90), offM: off, routeBearingDeg: 0), FollowEvent.none);
      }
      expect(m.isOff, isFalse);
    });

    test('hysteresis: off stays off between 25 and 40 m; back after 5 s within 25 m', () {
      final m = OffRouteMonitor(off: true);
      for (var s = 0; s < 60; s++) {
        expect(m.onFix(f(s), offM: 30), FollowEvent.none);
      }
      expect(m.isOff, isTrue);
      for (var s = 60; s < 65; s++) {
        expect(m.onFix(f(s), offM: 10), FollowEvent.none, reason: '$s s');
      }
      expect(m.onFix(f(65), offM: 10), FollowEvent.cameBack);
      expect(m.isOff, isFalse);
    });

    test('coming back: one fix outside 25 m starts the 5 s over', () {
      final m = OffRouteMonitor(off: true);
      m.onFix(f(0), offM: 10);
      m.onFix(f(4), offM: 10);
      m.onFix(f(5), offM: 30);
      expect(m.onFix(f(6), offM: 10), FollowEvent.none);
      expect(m.onFix(f(10), offM: 10), FollowEvent.none);
      expect(m.onFix(f(11), offM: 10), FollowEvent.cameBack);
    });

    test('stopped (under 5 km/h): fixes neither count nor reset, time stopped is not counted', () {
      final m = OffRouteMonitor();
      for (var s = 0; s < 5; s++) {
        m.onFix(f(s, heading: 90), offM: 60, routeBearingDeg: 0);
      }
      // A long red light 80 m from the route.
      for (var s = 5; s < 300; s++) {
        expect(m.onFix(f(s, kmh: 1, heading: 90), offM: 80, routeBearingDeg: 0), FollowEvent.none);
      }
      expect(m.state, FollowState.leaving, reason: 'not reset');
      // Moving again: 4 s held before + 4 s now is 8 s.
      for (var s = 300; s < 304; s++) {
        expect(m.onFix(f(s, heading: 90), offM: 60, routeBearingDeg: 0), FollowEvent.none);
      }
      expect(m.onFix(f(304, heading: 90), offM: 60, routeBearingDeg: 0), FollowEvent.wentOff);
    });

    test('parked 250 m off the road: never off', () {
      final m = OffRouteMonitor();
      for (var s = 0; s < 600; s++) {
        expect(m.onFix(f(s, kmh: (s % 4).toDouble()), offM: 250), FollowEvent.none);
      }
      expect(m.isOff, isFalse);
    });

    test('bad fixes (accuracy worse than 50 m, not finite) are ignored', () {
      final m = OffRouteMonitor();
      for (var s = 0; s < 60; s++) {
        expect(m.onFix(f(s, acc: 80), offM: 400), FollowEvent.none);
        expect(m.onFix(f(s), offM: double.nan), FollowEvent.none);
      }
      expect(m.isOff, isFalse);
    });

    test('tunnel: a departure in progress is dropped and nothing is decided', () {
      final m = OffRouteMonitor();
      for (var s = 0; s < 5; s++) {
        m.onFix(f(s, heading: 90), offM: 60, routeBearingDeg: 0);
      }
      expect(m.onFix(f(5), offM: 500, suppress: true), FollowEvent.none);
      expect(m.state, FollowState.onRoute);
    });

    test('approaching the route at an angle is not heading away', () {
      final m = OffRouteMonitor();
      for (var s = 0; s < 20; s++) {
        // Riding back towards the line, 90 degrees to it, distance shrinking.
        expect(m.onFix(f(s, heading: 270), offM: 100 - s * 4.0, routeBearingDeg: 0), FollowEvent.none);
      }
      expect(m.isOff, isFalse);
    });
  });

  group('RerouteScheduler', () {
    test('single flight; at least 15 s between requests', () {
      final s = RerouteScheduler();
      expect(s.check(nowMs: 0, online: true), RerouteGate.go);
      final t = s.start(0);
      expect(s.check(nowMs: 5000, online: true), RerouteGate.inFlight);
      expect(s.finish(t, ok: true, nowMs: 6000), isTrue);
      expect(s.check(nowMs: 14999, online: true), RerouteGate.tooSoon);
      expect(s.check(nowMs: 15000, online: true), RerouteGate.go);
    });

    test('back-off after failures (15 s, 15 s, 30 s), gives up after 3 in a row', () {
      final s = RerouteScheduler();
      var t = s.start(0);
      s.finish(t, ok: false, nowMs: 1000);
      expect(s.failures, 1);
      expect(s.check(nowMs: 14999, online: true), RerouteGate.tooSoon);
      expect(s.check(nowMs: 15000, online: true), RerouteGate.go);
      t = s.start(15000);
      s.finish(t, ok: false, nowMs: 16000);
      expect(s.wait, const Duration(seconds: 30));
      expect(s.check(nowMs: 44999, online: true), RerouteGate.tooSoon);
      expect(s.check(nowMs: 45000, online: true), RerouteGate.go);
      t = s.start(45000);
      s.finish(t, ok: false, nowMs: 46000);
      expect(s.gaveUp, isTrue);
      expect(s.check(nowMs: 100000, online: true), RerouteGate.gaveUp);
      // One quiet try after 5 minutes.
      expect(s.check(nowMs: 46000 + RerouteRules.retryAfterGiveUp.inMilliseconds, online: true), RerouteGate.go);
    });

    test('no answer within 20 s counts as a failure; the late answer is ignored', () {
      final s = RerouteScheduler();
      final t = s.start(0);
      expect(s.check(nowMs: 19999, online: true), RerouteGate.inFlight);
      expect(s.check(nowMs: 20000, online: true), RerouteGate.go, reason: 'timed out (20 s) and 15 s passed');
      expect(s.failures, 1);
      expect(s.finish(t, ok: true, nowMs: 21000), isFalse);
      expect(s.failures, 1);
    });

    test('offline: nothing starts, and a request that ended offline is not a failure', () {
      final s = RerouteScheduler();
      expect(s.check(nowMs: 0, online: false), RerouteGate.offline);
      final t = s.start(0);
      s.finish(t, ok: false, online: false, nowMs: 1000);
      expect(s.failures, 0);
    });

    test('success, a new departure or a reset start over; cancel is not a failure', () {
      final s = RerouteScheduler();
      for (var i = 0; i < 3; i++) {
        final t = s.start(i * 60000);
        s.finish(t, ok: false, nowMs: i * 60000 + 1000);
      }
      expect(s.gaveUp, isTrue);
      s.newEpisode();
      expect(s.gaveUp, isFalse);
      expect(s.failures, 0);
      final t = s.start(200000);
      s.cancel();
      expect(s.inFlight, isFalse);
      expect(s.failures, 0);
      expect(s.finish(t, ok: true, nowMs: 201000), isFalse);
      s.reset();
      expect(s.check(nowMs: 200001, online: true), RerouteGate.go);
    });
  });

  group('NavPromptGate', () {
    test('one off-route line per departure; none while a request is on its way', () {
      final g = NavPromptGate();
      expect(g.take(NavPrompt.offRouteFinding, nowMs: 0, reroutePending: true), isNull);
      g.newEpisode();
      expect(g.take(NavPrompt.offRouteFinding, nowMs: 0), NavPrompt.offRouteFinding);
      expect(g.take(NavPrompt.offRoute, nowMs: 1000), isNull);
    });

    test('never more than one off-route line per 2 minutes, even across departures', () {
      final g = NavPromptGate();
      expect(g.take(NavPrompt.offRouteFinding, nowMs: 0), isNotNull);
      g.newEpisode();
      expect(g.take(NavPrompt.offRouteFinding, nowMs: 119999), isNull);
      g.newEpisode();
      expect(g.take(NavPrompt.offRouteFinding, nowMs: 120000), isNotNull);
    });

    test('quiet for 60 s after a new route', () {
      final g = NavPromptGate()..rerouted(0);
      expect(g.take(NavPrompt.offRoute, nowMs: 59999), isNull);
      g.newEpisode();
      expect(g.take(NavPrompt.offRoute, nowMs: 60000), NavPrompt.offRoute);
    });

    test('"No signal" and "Couldn\'t find" once per departure; "New route ready" once per 2 minutes', () {
      final g = NavPromptGate();
      expect(g.take(NavPrompt.offRouteNoSignal, nowMs: 0), isNotNull);
      expect(g.take(NavPrompt.offRouteNoSignal, nowMs: 300000), isNull);
      expect(g.take(NavPrompt.rerouteFailed, nowMs: 0), isNotNull);
      expect(g.take(NavPrompt.rerouteFailed, nowMs: 1000), isNull);
      expect(g.take(NavPrompt.rerouteReady, nowMs: 0), isNotNull);
      expect(g.take(NavPrompt.rerouteReady, nowMs: 60000), isNull);
      expect(g.take(NavPrompt.rerouteReady, nowMs: 120000), isNotNull);
    });

    test('every line has its English text and a string key', () {
      for (final p in NavPrompt.values) {
        expect(p.english, isNotEmpty);
        expect(p.l10nKey, startsWith('nav.'));
      }
      expect(NavPrompt.offRouteFinding.english, 'Off route. Finding a new route.');
      expect(NavPrompt.rerouteFailed.english, "Couldn't find a new route. Follow the group.");
    });
  });

  group('RerouteController', () {
    // Leaves the route: 8 s heading east from a north-going route.
    RerouteStep leave(RerouteController c, int from, {bool online = true, bool auto = true}) {
      RerouteStep? step;
      for (var s = from; s <= from + 8; s++) {
        step = c.onFix(f(s, heading: 90), offM: 50 + (s - from) * 5.0, routeBearingDeg: 0, online: online, autoReroute: auto);
      }
      return step!;
    }

    test('leaving: one line and one request; nothing more while it is on its way', () {
      final c = RerouteController();
      final step = leave(c, 0);
      expect(step.event, FollowEvent.wentOff);
      expect(step.request, isTrue);
      expect(step.prompts, [NavPrompt.offRouteFinding]);
      c.begin(8000);
      for (var s = 9; s < 19; s++) {
        final st = c.onFix(f(s, heading: 90), offM: 100.0 + s, routeBearingDeg: 0, online: true);
        expect(st.request, isFalse);
        expect(st.prompts, isEmpty);
      }
      expect(c.status, RerouteStatus.finding);
    });

    test('new route: "New route ready." once, the monitor starts over, quiet for 60 s', () {
      final c = RerouteController();
      leave(c, 0);
      final t = c.begin(8000);
      final out = c.finish(t, ok: true, nowMs: 10000);
      expect(out.current, isTrue);
      expect(out.prompts, [NavPrompt.rerouteReady]);
      expect(c.isOff, isFalse);
      // Off the new route at once (a wrong turn right away): silent request after 15 s.
      final again = leave(c, 20);
      expect(again.event, FollowEvent.wentOff);
      expect(again.prompts, isEmpty, reason: 'within 60 s of the new route');
      expect(again.request, isTrue);
    });

    test('three failures: "Couldn\'t find a new route. Follow the group." once, then no requests', () {
      final c = RerouteController();
      leave(c, 0);
      var now = 0;
      final said = <NavPrompt>[];
      var requests = 0;
      for (var s = 9; s < 300; s++) {
        now = s * 1000;
        final st = c.onFix(f(s, heading: 90), offM: 300, routeBearingDeg: 0, online: true);
        said.addAll(st.prompts);
        if (st.request) {
          final t = c.begin(now);
          requests++;
          said.addAll(c.finish(t, ok: false, nowMs: now + 500).prompts);
        }
      }
      expect(requests, 3);
      expect(said, [NavPrompt.rerouteFailed]);
      expect(c.status, RerouteStatus.gaveUp);
    });

    test('offline: "Off route. No signal for a new route." once, then quiet; asks when online again', () {
      final c = RerouteController();
      final step = leave(c, 0, online: false);
      expect(step.request, isFalse);
      expect(step.prompts, [NavPrompt.offRouteNoSignal]);
      for (var s = 9; s < 200; s++) {
        final st = c.onFix(f(s, heading: 90), offM: 300, routeBearingDeg: 0, online: false);
        expect(st.prompts, isEmpty);
        expect(st.request, isFalse);
      }
      expect(c.status, RerouteStatus.noSignal);
      final online = c.onFix(f(200, heading: 90), offM: 300, routeBearingDeg: 0, online: true);
      expect(online.request, isTrue);
      expect(online.prompts, isEmpty, reason: 'already told');
    });

    test('auto re-route off: "Off route." once, never a request', () {
      final c = RerouteController();
      final step = leave(c, 0, auto: false);
      expect(step.prompts, [NavPrompt.offRoute]);
      expect(step.request, isFalse);
      for (var s = 9; s < 300; s++) {
        final st = c.onFix(f(s, heading: 90), offM: 300, routeBearingDeg: 0, online: true, autoReroute: false);
        expect(st.request, isFalse);
        expect(st.prompts, isEmpty);
      }
    });

    test('back on the route while a request is on its way: it is dropped, not a failure', () {
      final c = RerouteController();
      leave(c, 0);
      final t = c.begin(8000);
      RerouteStep? back;
      for (var s = 9; s <= 14; s++) {
        back = c.onFix(f(s), offM: 5, online: true);
      }
      expect(back!.event, FollowEvent.cameBack);
      expect(c.finish(t, ok: true, nowMs: 15000).current, isFalse);
      expect(c.scheduler.failures, 0);
    });

    test('weaving on and off the route: at most one off-route line per 2 minutes', () {
      final c = RerouteController();
      final said = <NavPrompt>[];
      var s = 0;
      while (s < 600) {
        final st = leave(c, s);
        said.addAll(st.prompts);
        s += 9;
        // Back on for 6 s.
        for (var i = 0; i < 6; i++, s++) {
          said.addAll(c.onFix(f(s), offM: 5, online: true).prompts);
        }
      }
      final offLines = said.where((p) => p.isOffRoute).length;
      expect(offLines, lessThanOrEqualTo(600 ~/ 120 + 1));
      expect(offLines, greaterThan(1));
    });

    test('cannot reroute (paused, no destination): tracks the state, never asks or speaks', () {
      final c = RerouteController();
      for (var s = 0; s <= 8; s++) {
        final st = c.onFix(f(s, heading: 90), offM: 200, routeBearingDeg: 0, online: true, canReroute: false);
        expect(st.request, isFalse);
        expect(st.prompts, isEmpty);
      }
      expect(c.isOff, isTrue);
    });
  });

  group('HeadingTracker', () {
    test('direction from movement once 15 m apart; GPS heading when fast enough', () {
      final h = HeadingTracker();
      expect(h.update(17.0, 78.0), isNull);
      expect(h.update(17.00005, 78.0), isNull, reason: 'about 5 m: jitter');
      final north = h.update(17.0002, 78.0)!;
      expect(north < 1 || north > 359, isTrue);
      expect(h.update(17.0002, 78.00001, gpsHeadingDeg: 93, speedKmh: 40), 93);
      expect(h.update(17.0002, 78.00002, gpsHeadingDeg: 93, speedKmh: 3), closeTo(0, 1), reason: 'slow: from movement');
    });
  });
}
