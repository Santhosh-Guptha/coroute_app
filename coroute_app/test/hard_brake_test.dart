import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/hard_brake_counter.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

const int t0 = 1700000000000;

TrackPoint fix(double s, double kmh) => TrackPoint(ts: t0 + (s * 1000).round(), lat: 12.97, lng: 77.59, speedKmh: kmh);
AccelBucket bucket(double s, double peak) => AccelBucket(tMs: t0 + (s * 1000).round(), peakG: peak, meanG: 1.0, stdG: 0.3);

void main() {
  test('thresholds', () {
    expect(SafetyConstants.hardBrakePeakG, 1.6);
    expect(SafetyConstants.hardBrakeDropKmh, 20);
    expect(SafetyConstants.hardBrakeWindow, const Duration(seconds: 6));
    expect(SafetyConstants.hardBrakeDedupe, const Duration(seconds: 10));
  });

  test('a brake from 60 to 30 in 3 s with a 1.8 g bucket counts (bucket before the slow fixes)', () {
    final c = HardBrakeCounter();
    c.onFix(fix(0, 60));
    c.onAccel(bucket(1, 1.8));
    c.onFix(fix(1, 55));
    expect(c.count, 0, reason: 'no drop of 20 yet');
    c.onFix(fix(2, 45));
    c.onFix(fix(3, 30));
    expect(c.count, 1);
    expect(c.atMs, [t0 + 1000]);
  });

  test('counts when the fixes arrive before the bucket too', () {
    final c = HardBrakeCounter();
    c.onFix(fix(0, 60));
    c.onFix(fix(1, 55));
    c.onFix(fix(2, 45));
    c.onFix(fix(3, 30));
    c.onAccel(bucket(1.5, 2.2));
    expect(c.count, 1);
  });

  test('a pothole at 2 g without a speed drop does not count', () {
    final c = HardBrakeCounter();
    for (var s = 0; s < 8; s++) {
      c.onFix(fix(s.toDouble(), 50));
      if (s == 3) c.onAccel(bucket(3, 2.0));
    }
    expect(c.count, 0);
  });

  test('a crash-level peak (5 g) is the detector\'s, not a hard stop', () {
    final c = HardBrakeCounter();
    c.onFix(fix(0, 60));
    c.onAccel(bucket(1, 5.0));
    c.onFix(fix(2, 20));
    c.onFix(fix(3, 0));
    expect(c.count, 0);
  });

  test('a drop that ends before the bucket does not count; one that ends long after it does not either', () {
    final c = HardBrakeCounter();
    c.onFix(fix(0, 60));
    c.onFix(fix(2, 30));
    c.onAccel(bucket(4, 1.9)); // the drop ended at 2 s, before the bucket
    c.onFix(fix(5, 30));
    expect(c.count, 0);
    c.onFix(fix(20, 60));
    c.onAccel(bucket(21, 1.9));
    c.onFix(fix(30, 30)); // 9 s later: outside the 6 s window
    expect(c.count, 0);
  });

  test('one count per 10 s, then again', () {
    final c = HardBrakeCounter();
    c.onFix(fix(0, 60));
    c.onAccel(bucket(1, 1.8));
    c.onFix(fix(2, 30));
    expect(c.count, 1);
    c.onFix(fix(4, 60));
    c.onAccel(bucket(5, 1.8));
    c.onFix(fix(6, 30));
    expect(c.count, 1, reason: 'within 10 s of the last one');
    c.onFix(fix(14, 60));
    c.onAccel(bucket(15, 1.8));
    c.onFix(fix(16, 30));
    expect(c.count, 2);
    c.reset();
    expect(c.count, 0);
    expect(c.atMs, isEmpty);
  });
}
