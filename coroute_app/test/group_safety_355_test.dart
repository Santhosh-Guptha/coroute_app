// 3.55 group safety: the pure decisions behind the missing-rider check, the group stretch alert,
// the smart regroup point, the group break planner, buddy pairs and the risky-stretch heads-up
// (docs/features_355/group_safety.md).
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/places/place_poi.dart';
import 'package:coroute_app/domain/places/poi_category.dart';
import 'package:coroute_app/domain/ride/buddy_watch.dart';
import 'package:coroute_app/domain/ride/group_break_planner.dart';
import 'package:coroute_app/domain/ride/group_safety_rider.dart';
import 'package:coroute_app/domain/ride/group_stretch.dart';
import 'package:coroute_app/domain/ride/missing_rider_check.dart';
import 'package:coroute_app/domain/ride/regroup_point.dart';
import 'package:coroute_app/domain/safety/risky_stretch.dart';

// A straight north-bound route from (17.0, 78.0), 30 km long. 1 km of latitude ~ 0.008993 deg.
const double kmLat = 1 / 111.195;
final List<(double, double)> route = [for (var i = 0; i <= 30; i++) (17.0 + i * kmLat, 78.0)];
(double, double) at(double km, {double eastM = 0}) => (17.0 + km * kmLat, 78.0 + eastM / 106000);

GroupSafetyRider rider(String id, double km, {double speed = 40, int? seen, String reason = '', int fatigue = 0, double eastM = 0}) {
  final (lat, lng) = at(km, eastM: eastM);
  return GroupSafetyRider(userId: id, name: '$id Rider', lat: lat, lng: lng, speedKmh: speed, lastSeenMs: seen ?? t0, statusReason: reason, fatigueLevel: fatigue);
}

const int t0 = 1800000000000;
const int sec = 1000, minute = 60000;

void main() {
  group('Missing-rider check', () {
    // I stop at km 5; the group (3 riders) rides on from km 5.2.
    List<GroupSafetyRider> group(int now, double km) => [
          rider('a', km, seen: now),
          rider('b', km + 0.2, seen: now),
          rider('c', km + 0.4, seen: now),
        ];

    test('asks after 3 min stopped while the group rides more than 1 km away, then no reply after 90 s', () {
      final c = MissingRiderCheck();
      var now = t0;
      MissingRiderAction last = MissingRiderAction.none;
      final asked = <int>[];
      for (var s = 0; s <= 300; s += 5) {
        now = t0 + s * sec;
        final groupKm = 5.2 + s * 0.011; // ~40 km/h
        last = c.evaluate(nowMs: now, me: rider('me', 5, speed: 0, seen: now), others: group(now, groupKm));
        if (last == MissingRiderAction.ask) asked.add(s);
      }
      expect(asked.length, 1);
      expect(asked.first >= 180, isTrue);
      expect(c.phase, MissingRiderPhase.noReplySent);
      expect(last, MissingRiderAction.none, reason: 'no reply is sent once only');
    });

    test('no reply is suppressed when the server already alerted the lead in the last 5 min', () {
      final c = MissingRiderCheck();
      final actions = <MissingRiderAction>[];
      for (var s = 0; s <= 300; s += 5) {
        final now = t0 + s * sec;
        actions.add(c.evaluate(nowMs: now, me: rider('me', 5, speed: 0, seen: now), others: group(now, 5.2 + s * 0.011), lastServerAlertMs: now - 2 * minute));
      }
      expect(actions.contains(MissingRiderAction.ask), isTrue);
      expect(actions.contains(MissingRiderAction.sendNoReply), isFalse);
      expect(actions.contains(MissingRiderAction.noReplySuppressed), isTrue);
    });

    test('never asks when the group is parked too, when I gave a reason, or during an emergency', () {
      for (final variant in ['parked', 'reason', 'emergency']) {
        final c = MissingRiderCheck();
        var asked = false;
        for (var s = 0; s <= 400; s += 5) {
          final now = t0 + s * sec;
          final others = variant == 'parked'
              ? [rider('a', 7, speed: 0, seen: now), rider('b', 7.1, speed: 0, seen: now)]
              : group(now, 5.2 + s * 0.011);
          final a = c.evaluate(
            nowMs: now,
            me: rider('me', 5, speed: 0, seen: now, reason: variant == 'reason' ? 'FUELING' : ''),
            others: others,
            emergencyOpen: variant == 'emergency',
          );
          if (a == MissingRiderAction.ask) asked = true;
        }
        expect(asked, isFalse, reason: variant);
      }
    });

    test('needs 60 % of fresh riders moving; stale riders are ignored', () {
      final c = MissingRiderCheck();
      var asked = false;
      for (var s = 0; s <= 400; s += 5) {
        final now = t0 + s * sec;
        // One moving away, two parked: 33 % moving.
        final others = [rider('a', 5.2 + s * 0.011, seen: now), rider('b', 9, speed: 0, seen: now), rider('c', 9.1, speed: 0, seen: now)];
        if (c.evaluate(nowMs: now, me: rider('me', 5, speed: 0, seen: now), others: others) == MissingRiderAction.ask) asked = true;
      }
      expect(asked, isFalse);
    });

    test('a silent phone (no fix for 3 min) counts as stopped; moving again clears the card', () {
      final c = MissingRiderCheck();
      MissingRiderAction a = MissingRiderAction.none;
      var asked = false;
      for (var s = 0; s <= 240; s += 5) {
        final now = t0 + s * sec;
        a = c.evaluate(nowMs: now, me: rider('me', 5, speed: 40, seen: t0), others: group(now, 5.2 + s * 0.011));
        if (a == MissingRiderAction.ask) asked = true;
      }
      expect(asked, isTrue);
      final now = t0 + 245 * sec;
      a = c.evaluate(nowMs: now, me: rider('me', 5.5, speed: 30, seen: now), others: group(now, 8));
      expect(a, MissingRiderAction.clear);
    });

    test('an answer keeps it quiet for the rest of the stop', () {
      final c = MissingRiderCheck();
      var asks = 0;
      for (var s = 0; s <= 900; s += 5) {
        final now = t0 + s * sec;
        final a = c.evaluate(nowMs: now, me: rider('me', 5, speed: 0, seen: now), others: group(now, 5.2 + s * 0.011));
        if (a == MissingRiderAction.ask) {
          asks++;
          c.answered(now);
        }
      }
      expect(asks, 1);
    });
  });

  group('Group stretch alert', () {
    test('spread is the along-route distance between the front and the last fresh rider', () {
      final s = GroupSpread.compute([rider('a', 2), rider('b', 6.5), rider('c', 4), rider('old', 20, seen: t0 - 5 * minute), rider('off', 10, eastM: 2000)], route, t0)!;
      expect(s.frontId, 'b');
      expect(s.lastId, 'a');
      expect(s.spreadM, closeTo(4500, 60));
      expect(GroupSpread.compute([rider('a', 2)], route, t0), isNull);
      expect(GroupSpread.compute([rider('a', 2), rider('b', 3)], const [], t0), isNull);
    });

    test('alerts after 30 s over the threshold, repeats at most every 5 min, clears under 80 %', () {
      final m = StretchMonitor();
      final events = <(int, StretchEvent)>[];
      void feed(int fromS, int toS, double spreadM) {
        for (var s = fromS; s <= toS; s += 5) {
          final e = m.update(nowMs: t0 + s * sec, spreadM: spreadM, thresholdM: 3000);
          if (e != StretchEvent.none) events.add((s, e));
        }
      }

      feed(0, 25, 3500);
      expect(events, isEmpty, reason: 'held 30 s first');
      feed(30, 30, 3500);
      expect(events.single.$2, StretchEvent.alert);
      feed(35, 400, 4000);
      expect(events.where((e) => e.$2 == StretchEvent.repeat).length, 1);
      expect(events.last.$1, 330);
      feed(405, 500, 2600); // between 80 % (2.4 km) and the threshold: stays
      expect(events.last.$2, StretchEvent.repeat);
      feed(505, 505, 2300);
      expect(events.last.$2, StretchEvent.clear);
      // Unknown spread holds the state.
      expect(m.update(nowMs: t0 + 600 * sec, spreadM: null, thresholdM: 3000), StretchEvent.none);
      expect(StretchMonitor.title(4000), 'Group spread 4 km, slow down');
      expect(StretchMonitor.title(4260), 'Group spread 4.3 km, slow down');
    });
  });

  group('Smart regroup point', () {
    PlacePoi poi(String id, PoiCategory c, double km, {double eastM = 50, String? name}) {
      final (lat, lng) = at(km, eastM: eastM);
      return PlacePoi(id: id, lat: lat, lng: lng, category: c, tags: {'name': name ?? id});
    }

    test('fuel before food before rest, within 300 m, 2-10 km ahead of the last rider, nearest the middle', () {
      // Last rider at km 3, lead at km 6: window km 6..13, middle 9.5.
      final places = [
        poi('food9', PoiCategory.food, 9.5),
        poi('fuel12', PoiCategory.fuel, 12.5),
        poi('fuel7', PoiCategory.fuel, 7),
        poi('fuelFar', PoiCategory.fuel, 9.5, eastM: 600), // off the route
        poi('fuel4', PoiCategory.fuel, 4), // behind the lead
        poi('fuel14', PoiCategory.fuel, 14), // beyond 10 km from the last rider
        poi('hospital', PoiCategory.hospital, 9.5),
      ];
      final pick = RegroupPointPicker.pick(route: route, places: places, lastAlongM: 3000, leadAlongM: 6000)!;
      expect(pick.placeId, 'fuel7'); // 2.5 km from the middle, fuel12 is 3 km
      expect(pick.aheadOfLeadM, closeTo(1000, 30));
      expect(pick.text, startsWith('Regroup at fuel7, 1 km ahead'));
      final noFuel = RegroupPointPicker.pick(route: route, places: places.where((p) => p.category != PoiCategory.fuel), lastAlongM: 3000, leadAlongM: 6000)!;
      expect(noFuel.placeId, 'food9');
      final restOnly = RegroupPointPicker.pick(route: route, places: [poi('stay', PoiCategory.stay, 8), poi('view', PoiCategory.viewpoint, 9)], lastAlongM: 3000, leadAlongM: 6000)!;
      expect(restOnly.placeId, 'stay');
    });

    test('nothing when the spread is wider than the window or no place fits', () {
      expect(RegroupPointPicker.pick(route: route, places: [poi('f', PoiCategory.fuel, 14)], lastAlongM: 1000, leadAlongM: 12000), isNull);
      expect(RegroupPointPicker.pick(route: route, places: const [], lastAlongM: 1000, leadAlongM: 2000), isNull);
      // A compact group (lead near the last rider): window starts 2 km ahead of the last rider.
      final p = RegroupPointPicker.pick(route: route, places: [poi('f1', PoiCategory.fuel, 2.5), poi('f2', PoiCategory.fuel, 6)], lastAlongM: 1000, leadAlongM: 1500)!;
      expect(p.placeId, 'f2');
    });
  });

  group('Group break planner', () {
    test('two riders at level 2+ (or 30 %) for 60 s show one card; quiet for 30 min after', () {
      final p = GroupBreakPlanner();
      expect(p.needsBreak([2, 2, 0, 0, 0, 0, 0, 0]), isTrue);
      expect(p.needsBreak([3, 0, 0]), isTrue, reason: '1 of 3 is 33 %');
      expect(p.needsBreak([2, 0, 0, 0, 0]), isFalse, reason: '1 of 5 is 20 %');
      expect(p.needsBreak([1, 1, 1, 1]), isFalse);
      expect(p.needsBreak([]), isFalse);
      final levels = [2, 3, 0, 0, 1, 0, 0];
      expect(p.update(nowMs: t0, levels: levels), isFalse);
      expect(p.update(nowMs: t0 + 30 * sec, levels: levels), isFalse);
      expect(p.update(nowMs: t0 + 60 * sec, levels: levels), isTrue);
      expect(p.tiredCount, 2);
      expect(p.update(nowMs: t0 + 65 * sec, levels: levels), isFalse, reason: 'once');
      p.done(t0 + 70 * sec);
      expect(p.update(nowMs: t0 + 20 * minute, levels: levels), isFalse);
      expect(p.update(nowMs: t0 + 32 * minute, levels: levels), isTrue);
      expect(GroupBreakPlanner.message(2), '2 riders are getting tired.');
    });

    test('fatigue score buckets', () {
      expect([FatigueBuckets.bucketOf(null), FatigueBuckets.bucketOf(10), FatigueBuckets.bucketOf(45), FatigueBuckets.bucketOf(70), FatigueBuckets.bucketOf(84), FatigueBuckets.bucketOf(95)],
          [0, 0, 1, 2, 2, 3]);
    });
  });

  group('Buddy check', () {
    test('behind more than 1 km for 2 min shows "Check on Kiran" once; snooze hides it', () {
      final w = BuddyWatch();
      final me = rider('me', 8, seen: t0);
      var shown = 0;
      for (var s = 0; s <= 180; s += 5) {
        final now = t0 + s * sec;
        final kiran = GroupSafetyRider(userId: 'k', name: 'Kiran Rao', lat: at(6.5).$1, lng: at(6.5).$2, speedKmh: 30, lastSeenMs: now);
        if (w.update(nowMs: now, me: rider('me', 8, seen: now), buddy: kiran, route: route)) shown++;
      }
      expect(shown, 1);
      expect(w.trouble, BuddyTrouble.behind);
      expect(BuddyWatch.title('Kiran'), 'Check on Kiran');
      w.snooze(t0 + 180 * sec);
      final kiran = GroupSafetyRider(userId: 'k', name: 'Kiran', lat: at(6.5).$1, lng: at(6.5).$2, lastSeenMs: t0 + 400 * sec);
      expect(w.update(nowMs: t0 + 400 * sec, me: me, buddy: kiran, route: route), isFalse);
    });

    test('offline buddy; stopped buddy only while I move away; a stop reason or being together is fine', () {
      final w = BuddyWatch();
      final now = t0 + 10 * minute;
      final me = rider('me', 8, seen: now);
      expect(w.troubleOf(nowMs: now, me: me, buddy: rider('k', 8, seen: now - 3 * minute), route: route), BuddyTrouble.offline);
      expect(w.troubleOf(nowMs: now, me: me, buddy: rider('k', 7.6, speed: 0, seen: now), route: route), BuddyTrouble.stopped);
      expect(w.troubleOf(nowMs: now, me: me, buddy: rider('k', 7.6, speed: 0, seen: now, reason: 'FUELING'), route: route), BuddyTrouble.none);
      expect(w.troubleOf(nowMs: now, me: rider('me', 8, speed: 0, seen: now), buddy: rider('k', 7.95, speed: 0, seen: now), route: route), BuddyTrouble.none);
      expect(w.troubleOf(nowMs: now, me: me, buddy: rider('k', 8.5, seen: now), route: route), BuddyTrouble.none, reason: 'ahead is fine');
    });
  });

  group('Risky stretch', () {
    test('grid and heading buckets match the gateway', () {
      final c = RiskGrid.cellOf(17.385, 78.4867);
      expect(c.key, '8693:39243');
      expect(c.lat, 17.386);
      expect(c.lng, 78.486);
      expect([RiskGrid.headingBucket(0), RiskGrid.headingBucket(22), RiskGrid.headingBucket(23), RiskGrid.headingBucket(359), RiskGrid.headingBucket(-90), RiskGrid.headingBucket(180)], [0, 0, 1, 0, 6, 4]);
    });

    test('the queue rounds to the cell centre, caps per cell, is due after 10 min and has no user id', () {
      final q = BrakeReportQueue();
      for (var i = 0; i < 5; i++) {
        q.add(lat: 17.3851, lng: 78.4867, heading: 10, nowMs: t0);
      }
      q.add(lat: 0, lng: 0, heading: 0, nowMs: t0);
      expect(q.length, 3);
      expect(q.due(t0 + 9 * minute), isFalse);
      expect(q.due(t0 + 10 * minute), isTrue);
      final body = q.take();
      expect(body.keys.toList(), ['events']);
      expect((body['events'] as List).first, {'lat': 17.386, 'lng': 78.486, 'h': 0});
      expect(q.isEmpty, isTrue);
      q.restore(body, t0);
      expect(q.length, 3);
    });

    test('announces once per cell when up to 500 m ahead in the same direction', () {
      final a = RiskyStretchAnnouncer();
      final (cLat, cLng) = at(5);
      a.setCells([RiskCell(id: 'x', lat: cLat, lng: cLng, headingBucket: 0)]);
      final (fLat, fLng) = at(4.3);
      expect(a.update(lat: fLat, lng: fLng, headingDeg: 0, speedKmh: 50, route: route), isNull, reason: '700 m ahead');
      final (nLat, nLng) = at(4.6);
      expect(a.update(lat: nLat, lng: nLng, headingDeg: 180, speedKmh: 50, route: route), isNull, reason: 'other direction');
      expect(a.update(lat: nLat, lng: nLng, headingDeg: 5, speedKmh: 50, route: route)?.id, 'x');
      expect(a.update(lat: nLat, lng: nLng, headingDeg: 5, speedKmh: 50, route: route), isNull, reason: 'once per ride');
      a.reset();
      a.setCells([RiskCell(id: 'x', lat: cLat, lng: cLng, headingBucket: 0)]);
      final (pLat, pLng) = at(5.3);
      expect(a.update(lat: pLat, lng: pLng, headingDeg: 0, speedKmh: 50, route: route), isNull, reason: 'already passed');
    });
  });
}
