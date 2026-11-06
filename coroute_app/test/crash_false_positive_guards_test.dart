import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/crash_detector.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

/// False-positive guards of the crash rule (pure logic, no platform code).
void main() {
  const t0 = 1700000000000;

  TrackPoint fix(int ts, double speedKmh) =>
      TrackPoint(ts: ts, lat: 12.9716, lng: 77.5946, speedKmh: speedKmh, accuracyM: 8);

  AccelBucket hit(int tMs, {double dyn = 4.5, double gyro = 2.0, double tilt = 20, double durMs = 80}) => AccelBucket(
        tMs: tMs,
        peakG: dyn + 0.4,
        meanG: 1.2,
        stdG: 0.6,
        peakDynG: dyn,
        peakGyroRadS: gyro,
        tiltDeg: tilt,
        impactDurationMs: durMs,
        peakJerkGPerS: 40,
      );

  test('phone dropped while walking (6 km/h) does not start a crash check', () {
    final d = CrashDetector();
    for (var s = 0; s <= 10; s++) {
      d.onFix(fix(t0 + s * 1000, 6));
    }
    // Tumbling phone: rotation, tilt and a thump on the ground.
    d.onAccel(hit(t0 + 11000, dyn: 1.9, gyro: 2.4, tilt: 70, durMs: 40));
    expect(d.evaluating, isFalse);
  });

  test('a low-speed tip-over after riding at 12 km/h is still checked', () {
    final d = CrashDetector();
    d.onFix(fix(t0, 12));
    d.onAccel(hit(t0 + 1000, dyn: 1.9, gyro: 1.9, tilt: 52, durMs: 40));
    expect(d.evaluating, isTrue);
  });

  test('phone dropped at a red light after the ride stopped is ignored', () {
    final d = CrashDetector();
    for (var s = 0; s <= 5; s++) {
      d.onFix(fix(t0 + s * 1000, 40));
    }
    for (var s = 6; s <= 18; s++) {
      d.onFix(fix(t0 + s * 1000, 0));
    }
    d.onAccel(hit(t0 + 18000, dyn: 4.5, gyro: 3.0, tilt: 60, durMs: 60));
    expect(d.evaluating, isFalse);
  });

  test('a pothole at speed (short spike, no rotation) is ignored', () {
    final d = CrashDetector();
    for (var s = 0; s <= 10; s++) {
      d.onFix(fix(t0 + s * 1000, 50));
    }
    d.onAccel(hit(t0 + 10000, dyn: 4.2, gyro: 0.4, tilt: 5, durMs: 20));
    expect(d.evaluating, isFalse);
  });

  test('a hard hit followed by riding on never raises the alarm', () {
    final d = CrashDetector();
    for (var s = 0; s <= 10; s++) {
      d.onFix(fix(t0 + s * 1000, 50));
    }
    d.onAccel(hit(t0 + 10000));
    expect(d.evaluating, isTrue);
    CrashEvent? ev;
    for (var s = 11; s <= 40; s++) {
      ev ??= d.onFix(fix(t0 + s * 1000, 45));
    }
    expect(ev, isNull);
    expect(d.evaluating, isFalse);
  });

  test('a hard hit, a stop and 20 s without riding on raises the alarm once', () {
    final d = CrashDetector();
    for (var s = 0; s <= 10; s++) {
      d.onFix(fix(t0 + s * 1000, 50));
    }
    d.onAccel(hit(t0 + 10000));
    final events = <CrashEvent>[];
    d.onFix(fix(t0 + 12000, 3));
    for (var s = 13; s <= 45; s++) {
      final ev = d.onFix(fix(t0 + s * 1000, 0));
      if (ev != null) events.add(ev);
    }
    expect(events, hasLength(1));
    expect(events.single.speedBeforeKmh, 50);
    // Cooldown: a second hit right after the alarm is not checked.
    d.onAccel(hit(t0 + 46000));
    expect(d.evaluating, isFalse);
  });
}
