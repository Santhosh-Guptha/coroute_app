import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/crash_detector.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

/// A synthetic ride: fixes and one-second accelerometer buckets, fed in time order.
class Trace {
  final List<(int, Object)> _events = [];
  static const int t0 = 1700000000000;
  static const double lat0 = 12.9716, lng0 = 77.5946;

  /// Fix at [s] seconds; [northM] metres north of the start.
  void fix(int s, double kmh, {double northM = 0}) =>
      _events.add((t0 + s * 1000, TrackPoint(ts: t0 + s * 1000, lat: lat0 + northM / 111320.0, lng: lng0, speedKmh: kmh, accuracyM: 5)));

  void bucket(
    int s, {
    double peak = 1.3,
    double mean = 1.0,
    double std = 0.3,
    double peakDyn = 0.0,
    double gyro = 0.0,
    double tilt = 0.0,
    double durMs = 0.0,
  }) =>
      _events.add((
        t0 + s * 1000,
        AccelBucket(
          tMs: t0 + s * 1000,
          peakG: peak,
          meanG: mean,
          stdG: std,
          peakDynG: peakDyn,
          peakGyroRadS: gyro,
          tiltDeg: tilt,
          impactDurationMs: durMs,
        ),
      ));

  /// Riding at [kmh] from second [from] to [to] (inclusive): a fix and a bumpy bucket each second.
  void ride(int from, int to, double kmh, {double startNorthM = 0}) {
    for (var s = from; s <= to; s++) {
      fix(s, kmh, northM: startNorthM + (s - from) * kmh / 3.6);
      bucket(s, peak: 1.5, std: 0.3);
    }
  }

  /// Runs the trace; returns every event the detector produced (with the time it fired).
  List<(int, CrashEvent)> run(CrashDetector d) {
    final ordered = List.of(_events)..sort((a, b) => a.$1.compareTo(b.$1));
    final out = <(int, CrashEvent)>[];
    for (final (t, e) in ordered) {
      final ev = e is TrackPoint ? d.onFix(e) : d.onAccel(e as AccelBucket);
      if (ev != null) out.add((t, ev));
    }
    return out;
  }
}

int sec(int s) => Trace.t0 + s * 1000;

/// Riding at 55 km/h, a 6 g impact at 30 s, 0 km/h at 34 s, lying still afterwards.
Trace realFall({double stillStd = 0.02, double stillKmh = 0, int until = 70}) {
  final t = Trace()..ride(0, 30, 55);
  t.bucket(30, peak: 6.0, mean: 2.0, std: 1.5); // the impact (same second as the last fast fix)
  t.fix(31, 40, northM: 470);
  t.bucket(31, peak: 3.2, std: 0.9);
  t.fix(32, 20, northM: 480);
  t.bucket(32, peak: 2.5, std: 0.8);
  t.fix(33, 8, northM: 485);
  t.bucket(33, peak: 2.0, std: 0.6);
  for (var s = 34; s <= until; s++) {
    if (s.isEven) t.fix(s, stillKmh, northM: 487 + (s % 4 == 0 ? 1 : 0));
    t.bucket(s, peak: 1.0 + stillStd * 3, mean: 1.0, std: stillStd);
  }
  return t;
}

void main() {
  group('synthetic traces', () {
    test('hard brake (1.3 g), full stop, ride on: no crash', () {
      final t = Trace()..ride(0, 30, 50);
      for (var s = 31; s <= 36; s++) {
        t.fix(s, 50 - (s - 30) * 9.0, northM: 420 + (s - 30) * 5.0);
        t.bucket(s, peak: 1.3, std: 0.2);
      }
      for (var s = 37; s <= 70; s++) {
        t.fix(s, 0, northM: 450);
        t.bucket(s, peak: 1.02, std: 0.02);
      }
      t.ride(71, 100, 40, startNorthM: 450);
      final d = CrashDetector();
      expect(t.run(d), isEmpty);
      expect(d.evaluating, isFalse);
    });

    test('pothole (6 g) while the speed stays at 50 km/h: no crash', () {
      final t = Trace()..ride(0, 30, 50);
      t.bucket(30, peak: 6.0, mean: 1.4, std: 1.2);
      t.ride(31, 70, 50, startNorthM: 430);
      final d = CrashDetector();
      expect(t.run(d), isEmpty);
      expect(d.evaluating, isFalse, reason: 'the candidate is dropped when no stop follows within 10 s');
    });

    test('phone dropped while parked (8 g, never at riding pace): no crash, sensor not wanted', () {
      final t = Trace();
      for (var s = 0; s <= 60; s++) {
        if (s % 5 == 0) t.fix(s, 0);
        t.bucket(s, peak: s == 20 ? 8.0 : 1.02, std: s == 20 ? 2.0 : 0.02);
      }
      final d = CrashDetector();
      expect(t.run(d), isEmpty);
      expect(d.wantsSensor, isFalse);
    });

    test('phone falls off the mount at speed (5 g), the ride goes on: no crash', () {
      final t = Trace()..ride(0, 30, 50);
      t.bucket(30, peak: 5.0, mean: 1.3, std: 1.0);
      t.ride(31, 70, 48, startNorthM: 430);
      expect(t.run(CrashDetector()), isEmpty);
    });

    test('real fall at 55 km/h: 6 g, 0 km/h within 4 s, still for 20 s: crash with the speed before', () {
      final events = realFall().run(CrashDetector());
      expect(events, hasLength(1));
      final (firedAt, e) = events.single;
      expect(e.impactAtMs, sec(30));
      expect(e.impactG, 6.0);
      expect(e.speedBeforeKmh, 55);
      expect(firedAt, greaterThanOrEqualTo(sec(34) + SafetyConstants.crashStillFor.inMilliseconds));
      expect(firedAt, lessThanOrEqualTo(sec(56)));
      expect(e.lat, closeTo(Trace.lat0 + 487 / 111320.0, 0.0001), reason: 'the position where it stopped');
    });

    // Product decision r314: a rider who gets up and walks after a real impact-then-stop at
    // speed still gets the alarm (they answer "I'm OK"). Only riding on cancels it.
    test('walking about after a fall (std 0.4, 3 km/h): crash alarm all the same', () {
      final events = realFall(stillStd: 0.4, stillKmh: 3).run(CrashDetector());
      expect(events, hasLength(1));
      expect(events.single.$1, sec(54));
      expect(events.single.$2.speedBeforeKmh, 55);
    });

    test('gets up at +3 s, walks 20 m at 5 km/h with brief still gaps: crash alarm', () {
      final t = Trace()..ride(0, 30, 60);
      t.bucket(30, peak: 9.0, std: 2.5);
      t.fix(32, 2, northM: 515);
      for (var s = 31; s <= 70; s++) {
        final walking = s >= 35 && s % 7 != 0; // every 7th second a pause
        t.bucket(s, peak: walking ? 1.7 : 1.03, std: walking ? 0.45 : 0.03);
      }
      for (var s = 38; s <= 52; s += 3) {
        t.fix(s, 5, northM: 515 + (s - 35) * 1.4);
      }
      final events = t.run(CrashDetector());
      expect(events, hasLength(1));
      expect(events.single.$1, sec(52));
    });

    test('pushing the bike at 12 km/h is still on foot: crash alarm', () {
      final t = Trace()..ride(0, 30, 60);
      t.bucket(30, peak: 9.0, std: 2.5);
      t.fix(32, 0, northM: 515);
      for (var s = 33; s <= 60; s++) {
        t.bucket(s, peak: 1.6, std: 0.4);
        if (s % 4 == 0) t.fix(s, 12, northM: 515 + (s - 32) * 3.3);
      }
      expect(t.run(CrashDetector()), hasLength(1));
    });

    test('riding on (16 km/h) within the 20 s after the stop cancels it', () {
      final t = Trace()..ride(0, 30, 60);
      t.bucket(30, peak: 9.0, std: 2.5);
      t.fix(32, 0, northM: 515);
      for (var s = 33; s <= 60; s++) {
        t.bucket(s, peak: 1.6, std: 0.4);
      }
      t.fix(45, 16, northM: 540);
      final d = CrashDetector();
      expect(t.run(d), isEmpty);
      expect(d.evaluating, isFalse);
    });

    test('phone dropped 20 s after arriving at a stop (still armed, walking fixes): no crash', () {
      final t = Trace()..ride(0, 30, 40);
      for (var s = 31; s <= 50; s++) {
        t.fix(s, s < 36 ? 40.0 - (s - 30) * 8 : 3, northM: 330 + (s - 30) * 2.0);
        t.bucket(s, peak: 1.3, std: 0.3);
      }
      t.bucket(51, peak: 6.0, std: 1.5); // dropped while walking to the counter
      t.fix(53, 2, northM: 372);
      for (var s = 52; s <= 90; s++) {
        t.bucket(s, peak: 1.03, std: 0.03);
      }
      final d = CrashDetector();
      expect(t.run(d), isEmpty);
    });

    test('rider gets up and rides off within the 20 s: no crash', () {
      final t = Trace()..ride(0, 30, 55);
      t.bucket(30, peak: 6.0, std: 1.5);
      t.fix(32, 0, northM: 480);
      for (var s = 32; s <= 40; s++) {
        t.bucket(s, peak: 1.02, std: 0.02);
      }
      t.ride(41, 70, 30, startNorthM: 480);
      expect(t.run(CrashDetector()), isEmpty);
    });

    test('GPS lost at the impact (tunnel) and the bike rides on (bumpy): no crash', () {
      final t = Trace()..ride(0, 30, 55);
      t.bucket(30, peak: 6.0, std: 1.5);
      for (var s = 31; s <= 80; s++) {
        t.bucket(s, peak: 1.6, std: 0.3); // no fixes at all, riding vibration
      }
      final d = CrashDetector();
      expect(t.run(d), isEmpty);
      expect(d.evaluating, isFalse);
    });

    test('GPS silent after the impact and the phone lies still: crash (no fixes is how a still phone looks)', () {
      final t = Trace()..ride(0, 30, 55);
      t.bucket(30, peak: 6.5, std: 1.5);
      for (var s = 31; s <= 39; s++) {
        t.bucket(s, peak: 2.0, std: 0.7); // tumbling: not judged
      }
      for (var s = 40; s <= 70; s++) {
        t.bucket(s, peak: 1.03, std: 0.02);
      }
      final events = t.run(CrashDetector());
      expect(events, hasLength(1));
      final (firedAt, e) = events.single;
      expect(firedAt, sec(60));
      expect(e.speedBeforeKmh, 55);
      expect(e.lat, closeTo(Trace.lat0 + 30 * 55 / 3.6 / 111320.0, 0.0001), reason: 'last known position');
    });

    // Regression (r314 behaviour test): the second after the GPS reads a stop often still holds
    // the end of the slide, and the GPS speed lags. That alone must not lose a real crash.
    test('real fall where the body settles 1 s after the GPS stop (std 0.3, a 6 km/h fix): crash', () {
      final t = Trace()..ride(0, 30, 60);
      t.bucket(30, peak: 9.0, std: 2.5);
      t.fix(31, 25, northM: 510);
      t.bucket(31, peak: 3.5, std: 1.2);
      t.fix(32, 3, northM: 515);
      t.bucket(32, peak: 1.4, std: 0.3);
      t.bucket(33, peak: 1.3, std: 0.25);
      t.fix(33, 6, northM: 516);
      for (var s = 34; s <= 70; s++) {
        t.bucket(s, peak: 1.05, std: 0.03);
      }
      final events = t.run(CrashDetector());
      expect(events, hasLength(1));
      expect(events.single.$1, sec(52));
      expect(events.single.$2.speedBeforeKmh, 60);
    });

    test('no GPS fix after the impact: the phone must lie still (a bump in the 2 s settle is fine)', () {
      final t = Trace()..ride(0, 30, 60);
      t.bucket(30, peak: 9.0, std: 2.5);
      for (var s = 31; s <= 70; s++) {
        t.bucket(s, peak: s == 41 ? 1.4 : 1.03, std: s == 41 ? 0.3 : 0.03); // 41 = stop + 1 s
      }
      expect(t.run(CrashDetector()), hasLength(1));
      final moving = Trace()..ride(0, 30, 60);
      moving.bucket(30, peak: 9.0, std: 2.5);
      for (var s = 31; s <= 70; s++) {
        moving.bucket(s, peak: s < 45 ? 1.03 : 1.6, std: s < 45 ? 0.03 : 0.4);
      }
      expect(moving.run(CrashDetector()), isEmpty, reason: 'no GPS proof of a stop and the phone moves');
    });

    test('moved more than 80 m after the stop (more than anyone walks in 20 s): no crash', () {
      final t = Trace()..ride(0, 30, 55);
      t.bucket(30, peak: 6.0, std: 1.5);
      t.fix(33, 0, northM: 480);
      for (var s = 33; s <= 60; s++) {
        t.bucket(s, peak: 1.02, std: 0.02);
      }
      t.fix(44, 4, northM: 580); // 100 m away: carried in a vehicle, or the GPS jumped
      expect(t.run(CrashDetector()), isEmpty);
    });
  });

  group('arming and battery', () {
    // 3.54 (safety review): the old rule ("a fix above 25 km/h in the last 30 s") left the sensor off
    // in slow traffic, so a low-speed tip-over was never seen. The rule is now: 12 km/h or more for
    // 10 s (or one fix above 25 km/h), kept through stop-and-go, off after 3 min parked. Battery stays
    // bounded: one fix never arms it below 25 km/h, walking pace never keeps it on, parking ends it.
    TrackPoint at(int s, double kmh) => TrackPoint(ts: sec(s), lat: 12.97, lng: 77.59, speedKmh: kmh);
    AccelBucket calm(int s) => AccelBucket(tMs: sec(s), peakG: 1.1, meanG: 1, stdG: 0.1);

    test('arms after 10 s at 12 km/h or more; a dip to 11 km/h keeps the run; exactly 25 is not instant', () {
      final d = CrashDetector();
      d.onFix(at(0, 25));
      expect(d.wantsSensor, isFalse, reason: 'one fix at 25 km/h: not above the instant line, not sustained');
      for (var s = 1; s <= 9; s++) {
        d.onFix(at(s, s.isOdd ? 11 : 14));
      }
      expect(d.wantsSensor, isFalse, reason: '9 s of riding pace');
      d.onFix(at(10, 13));
      expect(d.wantsSensor, isTrue, reason: '10 s at 12 km/h or more (the 11 km/h dips are inside the hysteresis band)');
    });

    test('stays armed through 2.5 min of stop-and-go; disarmed 3 min after the last fix at riding pace', () {
      final d = CrashDetector();
      for (var s = 0; s <= 10; s++) {
        d.onFix(at(s, 15));
      }
      expect(d.wantsSensor, isTrue);
      d.onFix(at(20, 0)); // red light
      d.onAccel(calm(160));
      expect(d.wantsSensor, isTrue, reason: '150 s stopped: still armed (hysteresis)');
      d.onFix(at(170, 4)); // walking pace does not keep it armed
      d.onAccel(calm(190));
      expect(d.wantsSensor, isTrue, reason: 'exactly 3 min after the last 15 km/h fix');
      d.onAccel(calm(191));
      expect(d.wantsSensor, isFalse, reason: 'parked for more than 3 min: sensor off (battery)');
      d.onFix(at(200, 18));
      expect(d.wantsSensor, isFalse, reason: 'after a disarm the next ride must arm again (10 s sustained)');
      for (var s = 201; s <= 210; s++) {
        d.onFix(at(s, 18));
      }
      expect(d.wantsSensor, isTrue);
    });

    test('a fix below 10 km/h restarts the run; one fix above 25 km/h arms at once', () {
      final d = CrashDetector();
      for (var s = 0; s <= 5; s++) {
        d.onFix(at(s, 15));
      }
      d.onFix(at(6, 5));
      for (var s = 7; s <= 15; s++) {
        d.onFix(at(s, 15));
      }
      expect(d.wantsSensor, isFalse, reason: 'only 8 s since the run restarted at 7 s');
      d.onFix(at(17, 15));
      expect(d.wantsSensor, isTrue);

      final fast = CrashDetector();
      fast.onFix(at(0, 26));
      expect(fast.wantsSensor, isTrue);
    });

    test('low-speed tip-over in slow traffic (15 km/h): the sensor is on and the fall is caught', () {
      final t = Trace();
      for (var s = 0; s <= 20; s++) {
        t.fix(s, 15, northM: s * 4.2);
        t.bucket(s, peak: 1.3, std: 0.2);
      }
      t.bucket(21, peak: 2.1, peakDyn: 1.9, gyro: 1.9, tilt: 52.0, durMs: 40.0, std: 0.9);
      t.fix(22, 0, northM: 90);
      for (var s = 23; s <= 50; s++) {
        t.fix(s, 0, northM: 90);
        t.bucket(s, peak: 1.02, std: 0.02, tilt: 60.0);
      }
      final d = CrashDetector();
      final events = t.run(d);
      expect(events, hasLength(1));
      expect(events.single.$2.isSlideFall, isTrue);
    });

    test('an impact while not armed is ignored', () {
      final d = CrashDetector();
      d.onFix(TrackPoint(ts: sec(0), lat: 12.97, lng: 77.59, speedKmh: 60));
      d.onAccel(AccelBucket(tMs: sec(200), peakG: 9, meanG: 2, stdG: 2));
      expect(d.evaluating, isFalse, reason: 'more than 3 min after the last fix at riding pace');

      final slow = CrashDetector();
      slow.onFix(TrackPoint(ts: sec(0), lat: 12.97, lng: 77.59, speedKmh: 18));
      slow.onAccel(AccelBucket(tMs: sec(1), peakG: 9, meanG: 2, stdG: 2));
      expect(slow.evaluating, isFalse, reason: 'one fix at 18 km/h does not arm the impact check');
    });

    test('while an impact is checked the sensor stays wanted even after the arming window', () {
      final t = realFall(until: 50);
      final d = CrashDetector();
      t.run(d);
      expect(d.evaluating, isTrue, reason: 'still time not complete at 50 s');
      expect(d.wantsSensor, isTrue);
    });
  });

  test('cooldown: no new alarm for 2 min after one, then again', () {
    final d = CrashDetector();
    final first = realFall().run(d);
    expect(first, hasLength(1));
    d.cooldown(sec(70));

    // The same fall 60 s later: blocked.
    Trace shifted(int offsetS) {
      final t = Trace();
      final base = realFall();
      for (final (time, e) in base._events) {
        final s = (time - Trace.t0) ~/ 1000 + offsetS;
        if (e is TrackPoint) {
          t._events.add((Trace.t0 + s * 1000, TrackPoint(ts: Trace.t0 + s * 1000, lat: e.lat, lng: e.lng, speedKmh: e.speedKmh)));
        } else if (e is AccelBucket) {
          t._events.add((Trace.t0 + s * 1000, AccelBucket(tMs: Trace.t0 + s * 1000, peakG: e.peakG, meanG: e.meanG, stdG: e.stdG)));
        }
      }
      return t;
    }

    expect(shifted(80).run(d), isEmpty, reason: 'impact at 110 s, cooldown until 190 s');
    expect(shifted(200).run(d), hasLength(1), reason: 'impact at 230 s, after the cooldown');
  });

  test('reset forgets the arming and a candidate', () {
    final d = CrashDetector();
    d.onFix(TrackPoint(ts: sec(0), lat: 12.97, lng: 77.59, speedKmh: 60));
    d.onAccel(AccelBucket(tMs: sec(1), peakG: 7, meanG: 2, stdG: 2));
    expect(d.evaluating, isTrue);
    d.reset();
    expect(d.evaluating, isFalse);
    expect(d.wantsSensor, isFalse);
  });

  test('bucket decoding from the native flat list', () {
    final flat = Float64List.fromList([1000, 1.5, 1.0, 0.2, 2000, 6.0, 2.0, 1.5, 3000, 1.0]);
    final b = AccelBucket.decode(flat);
    expect(b, hasLength(2), reason: 'the trailing partial group is skipped');
    expect(b[1].tMs, 2000);
    expect(b[1].peakG, 6.0);
    expect(b[0].stdG, 0.2);
    expect(AccelBucket.decode(Float64List.fromList([double.nan, 1, 1, 1])), isEmpty);

    // Extended 8-double format decoding test
    final extendedFlat = Float64List.fromList([
      1000, 1.5, 1.0, 0.2, 0.8, 0.4, 12.0, 40.0,
      2000, 5.0, 1.8, 0.9, 4.2, 2.8, 55.0, 120.0,
    ]);
    final extDecoded = AccelBucket.decode(extendedFlat);
    expect(extDecoded, hasLength(2));
    expect(extDecoded[1].peakDynG, 4.2);
    expect(extDecoded[1].peakGyroRadS, 2.8);
    expect(extDecoded[1].tiltDeg, 55.0);
    expect(extDecoded[1].impactDurationMs, 120.0);
    expect(extDecoded[1].effectiveDynG, 4.2);
  });

  group('enhanced motorcycle fall and slide scenarios', () {
    test('lowside fall without 4g spike (peak 2.4g, gyro 2.5 rad/s, tilt 55°): triggers crash', () {
      final t = Trace()..ride(0, 30, 45);
      // Lowside fall: moderate dynamic shock 2.4g, high angular velocity 2.5 rad/s, tilt 55°
      t.bucket(30, peak: 2.5, peakDyn: 2.4, gyro: 2.5, tilt: 55.0, durMs: 80.0, std: 1.2);
      t.fix(31, 20, northM: 460);
      t.bucket(31, peak: 1.8, peakDyn: 1.5, gyro: 1.0, tilt: 60.0, std: 0.6);
      t.fix(32, 0, northM: 465);
      for (var s = 33; s <= 60; s++) {
        if (s.isEven) t.fix(s, 0, northM: 465);
        t.bucket(s, peak: 1.02, std: 0.02, tilt: 65.0);
      }
      final events = t.run(CrashDetector());
      expect(events, hasLength(1));
      expect(events.single.$2.isSlideFall, isTrue);
      expect(events.single.$2.hasRotationOrTilt, isTrue);
      expect(events.single.$2.speedBeforeKmh, 45);
    });

    test('low-speed intersection fall (18 km/h, tilt 60°, stop): triggers crash', () {
      final t = Trace();
      for (var s = 0; s <= 20; s++) {
        t.fix(s, 18, northM: s * 5.0);
        t.bucket(s, peak: 1.3, std: 0.2);
      }
      // Tip over at junction: 1.9g shock, 2.2 rad/s gyro, 60° tilt
      t.bucket(21, peak: 2.0, peakDyn: 1.9, gyro: 2.2, tilt: 60.0, durMs: 60.0, std: 1.1);
      t.fix(22, 0, northM: 105);
      for (var s = 23; s <= 50; s++) {
        t.fix(s, 0, northM: 105);
        t.bucket(s, peak: 1.02, std: 0.02, tilt: 65.0);
      }
      final events = t.run(CrashDetector());
      expect(events, hasLength(1));
      expect(events.single.$2.isSlideFall, isTrue);
    });

    test('highside incident (angular snap 3.6 rad/s, 3.5g dynamic shock, rapid stop): triggers crash', () {
      final t = Trace()..ride(0, 30, 65);
      // Highside violent snap
      t.bucket(30, peak: 3.8, peakDyn: 3.6, gyro: 3.6, tilt: 70.0, durMs: 140.0, std: 2.0);
      t.fix(31, 25, northM: 520);
      t.fix(33, 0, northM: 530);
      for (var s = 34; s <= 60; s++) {
        t.fix(s, 0, northM: 530);
        t.bucket(s, peak: 1.02, std: 0.02, tilt: 75.0);
      }
      final events = t.run(CrashDetector());
      expect(events, hasLength(1));
      expect(events.single.$2.hasRotationOrTilt, isTrue);
    });

    test('speed breaker / rumble strip (peak 2.8g, duration 20ms, tilt 2°, speed drops 40->25 km/h, ride on): no crash', () {
      final t = Trace()..ride(0, 30, 40);
      // Speed breaker bump: brief impulse 20ms, no tilt, no rotation
      t.bucket(31, peak: 2.9, peakDyn: 2.8, gyro: 0.2, tilt: 2.0, durMs: 20.0, std: 0.8);
      t.ride(32, 60, 25, startNorthM: 350);
      final d = CrashDetector();
      expect(t.run(d), isEmpty);
    });

    test('pebble hit / sensor glitch (4.2g spike, duration 10ms, no rotation, ride on): no crash', () {
      final t = Trace()..ride(0, 30, 50);
      // Sub-sample glitch / stone flick on sensor housing
      t.bucket(31, peak: 4.2, peakDyn: 4.1, gyro: 0.1, tilt: 1.0, durMs: 10.0, std: 0.5);
      t.ride(32, 60, 50, startNorthM: 430);
      final d = CrashDetector();
      expect(t.run(d), isEmpty);
    });

    test('stale GPS fixes (> 10s old) and inaccurate fixes (> 65m) do not corrupt detection', () {
      final t = Trace()..ride(0, 30, 55);
      t.bucket(30, peak: 6.0, std: 1.5);
      // Inaccurate fix (accuracy 150m) reporting 0 km/h is ignored for stop confirmation
      t._events.add((Trace.t0 + 31000, TrackPoint(ts: Trace.t0 + 31000, lat: Trace.lat0, lng: Trace.lng0, speedKmh: 0, accuracyM: 150)));
      // Legitimate accurate stop fix at 34s
      t.fix(34, 0, northM: 485);
      for (var s = 35; s <= 70; s++) {
        t.fix(s, 0, northM: 485);
        t.bucket(s, peak: 1.02, std: 0.02);
      }
      final events = t.run(CrashDetector());
      expect(events, hasLength(1));
    });

    test('high road vibration at 70 km/h (peak 2.0g, std 0.35g, no rotation): sensor stays armed, no crash', () {
      final t = Trace();
      for (var s = 0; s <= 60; s++) {
        t.fix(s, 70, northM: s * 70 / 3.6);
        t.bucket(s, peak: 2.0, peakDyn: 1.4, gyro: 0.3, tilt: 4.0, std: 0.35);
      }
      final d = CrashDetector();
      expect(t.run(d), isEmpty);
      expect(d.wantsSensor, isTrue);
    });
  });
}
