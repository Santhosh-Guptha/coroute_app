import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/intel/intel_event.dart';
import 'package:coroute_app/domain/intel/intel_policies.dart';
import 'package:coroute_app/domain/intel/sha256.dart';
import 'package:coroute_app/domain/safety/ride_safety_summary.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

/// Round 4 privacy base on the phone: the consent prompt timing, ride trimming and the offline queue, the
/// pre-ride tip gate, no-fuel gaps, the crash brain parameter check (same checksum as the gateway), and twisty km.
(double, double) _north(double lat, double lng, double m) => (lat + m / 111320, lng);

void main() {
  group('consent prompt', () {
    test('once, after the first completed ride, never while riding or during an alarm', () {
      bool ask({int rides = 1, bool answered = false, bool on = false, bool riding = false, bool emergency = false}) =>
          ConsentPromptPolicy.shouldPrompt(completedRides: rides, answered: answered, consentOn: on, riding: riding, emergency: emergency);
      expect(ask(rides: 0), isFalse, reason: 'not before a ride');
      expect(ask(), isTrue);
      expect(ask(rides: 5), isTrue, reason: 'still unanswered');
      expect(ask(answered: true), isFalse, reason: '"Not now" is remembered');
      expect(ask(on: true), isFalse, reason: 'already sharing');
      expect(ask(riding: true), isFalse);
      expect(ask(emergency: true), isFalse);
      expect(ConsentPromptPolicy.body, contains('300 m'));
    });
  });

  group('event queue and trimming', () {
    IntelEvent at(double lat, double lng, {int ts = 1}) => IntelEvent.at(type: IntelEventType.hardBrake, lat: lat, lng: lng, headingDeg: 0, speedKmh: 40, ts: ts)!;

    test('first 300 m and last 300 m of the ride are dropped, privacy zones too', () {
      final q = IntelEventQueue(zones: [_north(12.9, 77.5, 2000)]);
      q.startRide();
      q.onFix(12.9, 77.5);
      expect(q.add(at(_north(12.9, 77.5, 200).$1, 77.5)), isFalse, reason: 'within 300 m of the start');
      expect(q.add(at(_north(12.9, 77.5, 1000).$1, 77.5)), isTrue);
      expect(q.add(at(_north(12.9, 77.5, 2100).$1, 77.5)), isFalse, reason: 'near a saved home / work place');
      expect(q.add(at(_north(12.9, 77.5, 2900).$1, 77.5)), isTrue);
      final end = _north(12.9, 77.5, 3000);
      expect(q.endRide(end.$1, end.$2), 1, reason: 'the event 100 m before the end is dropped');
      expect(q.ready.single.gh, at(_north(12.9, 77.5, 1000).$1, 77.5).gh);
    });

    test('offline: events wait (capped), go in batches, clear on consent off', () {
      final q = IntelEventQueue(maxQueue: 5);
      for (var r = 0; r < 3; r++) {
        q.startRide();
        q.onFix(12.9, 77.5);
        for (var i = 1; i <= 3; i++) {
          q.add(at(_north(12.9, 77.5, 500.0 * i).$1, 77.5, ts: r * 10 + i));
        }
        q.endRide(null, null);
      }
      expect(q.ready, hasLength(5), reason: 'oldest dropped beyond the cap');
      expect(q.batch(2), hasLength(2));
      q.confirm(2);
      expect(q.ready, hasLength(3));
      q.clear();
      expect(q.ready, isEmpty);
      final back = IntelEvent.fromStore(at(13, 77.6).toStore());
      expect(back!.lat, 13);
      expect(back.type, IntelEventType.hardBrake);
    });

    test('buckets: heading 8 x 45 deg, speed 20 km/h bands, hour of week in India time', () {
      expect(IntelEvent.headingBucket(350), 0);
      expect(IntelEvent.headingBucket(91), 2);
      expect(IntelEvent.headingBucket(null), -1);
      expect(IntelEvent.speedBucket(85), 4);
      expect(IntelEvent.hourOfWeek(DateTime.utc(2026, 11, 9, 0, 30).millisecondsSinceEpoch), 6, reason: 'Monday 06:00 IST');
    });
  });

  test('pre-ride tip at most once per day', () {
    final d = DateTime(2026, 11, 12, 18);
    expect(RideTipGate.allowed(lastShownDay: null, local: d), isTrue);
    expect(RideTipGate.allowed(lastShownDay: RideTipGate.dayKey(d), local: d.add(const Duration(hours: 3))), isFalse);
    expect(RideTipGate.allowed(lastShownDay: RideTipGate.dayKey(d), local: d.add(const Duration(hours: 7))), isTrue);
  });

  test('no-fuel gaps over 80 km between known fuel on the route', () {
    final route = [for (var km = 0; km <= 300; km++) _north(15, 75, km * 1000.0)];
    final fuel = [
      (lat: _north(15, 75, 10000).$1, lng: 75.0, name: 'Pump A'),
      (lat: _north(15, 75, 150000).$1, lng: 75.0, name: 'Pump B'),
      (lat: _north(15, 75, 160000).$1, lng: 75.5, name: 'Off route'),
    ];
    final g = FuelGapFinder.gaps(route, fuel);
    expect(g.map((x) => x.lengthKm.round()), [140, 150]);
    expect(g.first.text, 'No known fuel for 140 km after Pump A');
    expect(g.last.toEnd, isTrue);
    expect(FuelGapFinder.gaps(route, fuel, gapKm: 200), isEmpty);
    expect(FuelGapFinder.gaps(route, const []).single.text, 'No known fuel for 300 km after the start');
  });

  group('crash brain params', () {
    test('sha256 matches the standard vector and the gateway checksum', () {
      expect(Sha256.hexOf('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      // gateway: CB.checksum(3, 'samsung', { impactScale: 1.1 }) and CB.checksum(0, 'google', null)
      expect(CrashBrainParams.checksumOf(3, 'samsung', 1.1), 'ad7e7d005d5e367cfadeafe4c2124e60c2193a77d7f839b31d72b4f8c6fc3ab1');
      expect(CrashBrainParams.checksumOf(0, 'google', null), '9bec564dfcd88b42a22098aec67723c89c0694a5016ab411d050c141b24af04d');
    });

    test('approved and verified: the scale; anything else: the defaults (1.0)', () {
      Map<String, Object?> j({String mode = 'approved', int v = 3, double s = 1.1, String? sum}) =>
          {'mode': mode, 'version': v, 'group': 'samsung', 'params': {'impactScale': s}, 'checksum': sum ?? CrashBrainParams.checksumOf(v, 'samsung', s)};
      expect(CrashBrainParams.impactScaleOf(j()), 1.1);
      expect(CrashBrainParams.impactScaleOf(j(mode: 'shadow')), 1.0);
      expect(CrashBrainParams.impactScaleOf(j(sum: 'deadbeef')), 1.0, reason: 'tampered or corrupted');
      expect(CrashBrainParams.impactScaleOf(j(s: 1.3)), 1.0, reason: 'above the safety floor x1.15');
      expect(CrashBrainParams.impactScaleOf(j(v: 0)), 1.0);
      expect(CrashBrainParams.impactScaleOf(null), 1.0);
      expect(CrashBrainParams.impactScaleOf('garbage'), 1.0);
    });
  });

  group('twisty km in the ride report', () {
    List<TrackPoint> track({required double wiggle, double km = 5}) {
      final out = <TrackPoint>[];
      var lat = 12.9, lng = 77.5;
      for (var i = 0; i < km * 1000 / 20; i++) {
        final deg = (i.isEven ? wiggle : -wiggle) * math.pi / 180;
        lat += 20 * math.cos(deg) / 111320;
        lng += 20 * math.sin(deg) / (111320 * math.cos(lat * math.pi / 180));
        out.add(TrackPoint(ts: 1000 + i * 1800, lat: lat, lng: lng, speedKmh: 40));
      }
      return out;
    }

    test('a ghat counts its kilometres, a straight road none', () {
      final twisty = TwistyMeter();
      for (final p in track(wiggle: 10)) {
        twisty.onFix(p);
      }
      expect(twisty.twistyKm, greaterThanOrEqualTo(4));
      final straight = TwistyMeter();
      for (final p in track(wiggle: 0)) {
        straight.onFix(p);
      }
      expect(straight.twistyKm, 0);
      expect(GeoMath.haversine(12.9, 77.5, 12.9, 77.5), 0);
    });

    test('the safety summary shows "Twisty roads" only when there were some, and stores it compactly', () {
      final acc = RideSafetyAccumulator();
      for (final p in track(wiggle: 10)) {
        acc.onFix(p);
      }
      final s = acc.build(hardBrakes: 0, breaks: 0);
      expect(s.twistyKm, greaterThanOrEqualTo(4));
      expect(s.lines().last.$1, 'Twisty roads');
      expect(RideSafetySummary.fromJson(s.toJson())!.twistyKm, s.twistyKm);
      expect(const RideSafetySummary().lines().any((l) => l.$1 == 'Twisty roads'), isFalse);
      expect(const RideSafetySummary().toJson().containsKey('tw'), isFalse);
    });
  });
}
