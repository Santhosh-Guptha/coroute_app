import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/crash_detector.dart';
import 'package:coroute_app/domain/safety/crash_incident.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TrackPoint fix(int ts, double speedKmh, {double lat = 12.9716, double lng = 77.5946, double acc = 10.0}) {
    return TrackPoint(
      ts: ts,
      lat: lat,
      lng: lng,
      speedKmh: speedKmh,
      accuracyM: acc,
    );
  }

  group('Phase 2 Advanced Crash Detection - Telemetry Decoding & Backward Compatibility', () {
    test('decodes 10-element native telemetry buffer with jerk and sensor confidence', () {
      final buffer = Float64List.fromList([
        1700000000000.0, // tMs
        4.5,             // peakRawG
        1.2,             // meanRawG
        0.3,             // stdRawG
        4.1,             // peakDynG
        2.2,             // peakGyroRadS
        55.0,            // maxTiltDeg
        80.0,            // maxDurationMs
        45.0,            // peakJerkGPerS
        0.95,            // sensorConfidence
      ]);

      final buckets = AccelBucket.decode(buffer);
      expect(buckets.length, 1);
      final b = buckets.first;
      expect(b.tMs, 1700000000000);
      expect(b.peakG, 4.5);
      expect(b.effectiveDynG, 4.1);
      expect(b.peakGyroRadS, 2.2);
      expect(b.tiltDeg, 55.0);
      expect(b.impactDurationMs, 80.0);
      expect(b.peakJerkGPerS, 45.0);
      expect(b.sensorConfidence, 0.95);
    });

    test('decodes legacy 8-element telemetry buffer with defaults for jerk and confidence', () {
      final buffer = Float64List.fromList([
        1700000000000.0, 3.8, 1.0, 0.2, 3.5, 1.9, 48.0, 60.0,
      ]);

      final buckets = AccelBucket.decode(buffer);
      expect(buckets.length, 1);
      final b = buckets.first;
      expect(b.peakG, 3.8);
      expect(b.peakDynG, 3.5);
      expect(b.peakJerkGPerS, 0.0);
      expect(b.sensorConfidence, 1.0);
    });

    test('decodes legacy 4-element telemetry buffer gracefully', () {
      final buffer = Float64List.fromList([
        1700000000000.0, 2.5, 1.0, 0.15,
      ]);

      final buckets = AccelBucket.decode(buffer);
      expect(buckets.length, 1);
      final b = buckets.first;
      expect(b.peakG, 2.5);
      expect(b.effectiveDynG, 2.5);
      expect(b.peakJerkGPerS, 0.0);
      expect(b.sensorConfidence, 1.0);
    });
  });

  group('Phase 2 Motorcycle Crash Pattern Scenarios', () {
    test('Scenario 1: High-Impact Collision at Speed', () {
      final detector = CrashDetector();
      const t0 = 1700000000000;

      // 1. Armed speed (55 km/h)
      detector.onFix(fix(t0, 55.0));

      // 2. High-impact collision: 5.8g dynamic impact with violent jerk 52 g/s
      detector.onAccel(AccelBucket(
        tMs: t0 + 1000,
        peakG: 6.2,
        meanG: 2.1,
        stdG: 1.5,
        peakDynG: 5.8,
        peakGyroRadS: 1.2,
        tiltDeg: 25.0,
        impactDurationMs: 90.0,
        peakJerkGPerS: 52.0,
      ));

      expect(detector.evaluating, isTrue);

      // 3. Stop: speed drops to 0 km/h within 4 seconds
      detector.onFix(fix(t0 + 4000, 0.0));

      // 4. Stationary stillness for 20s
      CrashEvent? crash;
      for (var s = 5; s <= 28; s++) {
        final ev = detector.onFix(fix(t0 + s * 1000, 0.0));
        if (ev != null) {
          crash = ev;
          break;
        }
      }

      expect(crash, isNotNull);
      expect(crash!.scenario, CrashScenario.highImpactCollision);
      expect(crash.confidence, greaterThanOrEqualTo(0.90));
      expect(crash.movementState, MovementState.stopped);
    });

    test('Scenario 2: Low-Side Slide with Lean and Traction Loss', () {
      final detector = CrashDetector();
      const t0 = 1700000000000;

      // 1. Armed speed (40 km/h)
      detector.onFix(fix(t0, 40.0));

      // 2. Low-side slide: moderate dynamic shock 2.4g, high angular rotation 2.2 rad/s, bike leans onto side (62° tilt)
      detector.onAccel(AccelBucket(
        tMs: t0 + 1000,
        peakG: 2.8,
        meanG: 1.3,
        stdG: 0.9,
        peakDynG: 2.4,
        peakGyroRadS: 2.2,
        tiltDeg: 62.0,
        impactDurationMs: 60.0,
      ));

      expect(detector.evaluating, isTrue);

      // 3. Slide ends and stops (0 km/h)
      detector.onFix(fix(t0 + 5000, 0.0));

      // 4. Stillness on road shoulder
      CrashEvent? crash;
      for (var s = 6; s <= 28; s++) {
        final ev = detector.onFix(fix(t0 + s * 1000, 0.0));
        if (ev != null) {
          crash = ev;
          break;
        }
      }

      expect(crash, isNotNull);
      expect(crash!.scenario, CrashScenario.lowsideSlide);
      expect(crash.isSlideFall, isTrue);
      expect(crash.hasRotationOrTilt, isTrue);
    });

    test('Scenario 3: High-Side Fall with Angular Snap and Orientation Inversion', () {
      final detector = CrashDetector();
      const t0 = 1700000000000;

      // 1. Armed speed (48 km/h)
      detector.onFix(fix(t0, 48.0));

      // 2. High-side snap: violent angular rebound (3.4 rad/s) and severe tilt inversion (75°)
      detector.onAccel(AccelBucket(
        tMs: t0 + 1000,
        peakG: 4.5,
        meanG: 1.8,
        stdG: 1.4,
        peakDynG: 3.6,
        peakGyroRadS: 3.4,
        tiltDeg: 75.0,
        impactDurationMs: 80.0,
        peakJerkGPerS: 48.0,
      ));

      expect(detector.evaluating, isTrue);

      // 3. Stop
      detector.onFix(fix(t0 + 4000, 0.0));

      CrashEvent? crash;
      for (var s = 5; s <= 28; s++) {
        final ev = detector.onFix(fix(t0 + s * 1000, 0.0));
        if (ev != null) {
          crash = ev;
          break;
        }
      }

      expect(crash, isNotNull);
      expect(crash!.scenario, CrashScenario.highsideFall);
      expect(crash.confidence, greaterThanOrEqualTo(0.90));
    });

    test('Scenario 4: Stationary / Low-Speed Tip-Over Drop', () {
      final detector = CrashDetector();
      const t0 = 1700000000000;

      // 1. Slow crawling speed at junction (one 12 km/h fix: not sustained, but armed for low-speed falls)
      detector.onFix(fix(t0, 12.0));

      // 2. Bike drops: tilt 52°, dynamic thump 1.9g, rotation 1.9 rad/s
      detector.onAccel(AccelBucket(
        tMs: t0 + 1000,
        peakG: 2.1,
        meanG: 1.1,
        stdG: 0.5,
        peakDynG: 1.9,
        peakGyroRadS: 1.9,
        tiltDeg: 52.0,
        impactDurationMs: 40.0,
      ));

      expect(detector.evaluating, isTrue);

      // 3. Stopped immediately
      detector.onFix(fix(t0 + 2000, 0.0));

      CrashEvent? crash;
      for (var s = 3; s <= 25; s++) {
        final ev = detector.onFix(fix(t0 + s * 1000, 0.0));
        if (ev != null) {
          crash = ev;
          break;
        }
      }

      expect(crash, isNotNull);
      expect(crash!.scenario, CrashScenario.stationaryDrop);
    });

    test('Scenario 5: Impact Followed by Stillness with Lost GPS (Classified as UNKNOWN, Not STOPPED)', () {
      final detector = CrashDetector();
      const t0 = 1700000000000;

      // 1. Armed riding speed (50 km/h)
      detector.onFix(fix(t0, 50.0));

      // 2. Impact in a tunnel or remote valley
      detector.onAccel(AccelBucket(
        tMs: t0 + 1000,
        peakG: 5.0,
        meanG: 2.0,
        stdG: 1.2,
        peakDynG: 4.8,
        peakGyroRadS: 2.2,
        tiltDeg: 60.0,
        impactDurationMs: 70.0,
      ));

      expect(detector.evaluating, isTrue);

      // 3. ZERO GPS fixes arrive post-impact (tunnel signal loss).
      // Motion sensors confirm complete stillness (stdG = 0.02) after 2s settle for 20s.
      CrashEvent? crash;
      for (var s = 2; s <= 40; s++) {
        final ev = detector.onAccel(AccelBucket(
          tMs: t0 + s * 1000,
          peakG: 1.0,
          meanG: 1.0,
          stdG: 0.02,
          peakDynG: 0.01,
          peakGyroRadS: 0.01,
          tiltDeg: 60.0,
        ));
        if (ev != null) {
          crash = ev;
          break;
        }
      }

      expect(crash, isNotNull, reason: 'Crash must still be detected when GPS is unavailable');
      expect(crash!.movementState, MovementState.unknown, reason: 'GPS absence must be classified as UNKNOWN, NEVER STOPPED');
    });
  });

  group('Phase 2 False-Positive Discrimination Matrix', () {
    test('FP 1: Pothole & Speed Breaker - Transient shock rejected, ride continues', () {
      final detector = CrashDetector();
      const t0 = 1700000000000;

      detector.onFix(fix(t0, 45.0));

      // Pothole: dynamic shock 3.6g, but sub-35ms duration, no rotation (0.1 rad/s), upright bike (2° tilt)
      detector.onAccel(AccelBucket(
        tMs: t0 + 1000,
        peakG: 3.8,
        meanG: 1.2,
        stdG: 0.6,
        peakDynG: 3.6,
        peakGyroRadS: 0.1,
        tiltDeg: 2.0,
        impactDurationMs: 20.0,
      ));

      // Should not even evaluate or immediately reject
      expect(detector.evaluating, isFalse);

      // Rider continues riding at 44 km/h
      for (var s = 2; s <= 15; s++) {
        final ev = detector.onFix(fix(t0 + s * 1000, 44.0));
        expect(ev, isNull);
      }
    });

    test('FP 2: Railway Crossing & Continuous Road Vibrations - Suppressed', () {
      final detector = CrashDetector();
      const t0 = 1700000000000;

      detector.onFix(fix(t0, 35.0));

      // Railway crossing: high vibrations stdG = 0.35, but bike upright and no rollover
      for (var s = 1; s <= 5; s++) {
        final ev = detector.onAccel(AccelBucket(
          tMs: t0 + s * 1000,
          peakG: 2.4,
          meanG: 1.1,
          stdG: 0.35,
          peakDynG: 2.1,
          peakGyroRadS: 0.3,
          tiltDeg: 4.0,
          impactDurationMs: 15.0,
        ));
        expect(ev, isNull);
      }
      expect(detector.evaluating, isFalse);
    });

    test('FP 3: Emergency Hard Braking - Linear deceleration without rollover is suppressed', () {
      final detector = CrashDetector();
      const t0 = 1700000000000;

      detector.onFix(fix(t0, 80.0));

      // Hard braking: linear decel (1.2g), no rotation (0.1 rad/s), tilt 2°
      detector.onAccel(AccelBucket(
        tMs: t0 + 1000,
        peakG: 1.4,
        meanG: 1.0,
        stdG: 0.15,
        peakDynG: 1.2,
        peakGyroRadS: 0.1,
        tiltDeg: 2.0,
      ));

      // Speed decreases linearly to stop at traffic signal
      detector.onFix(fix(t0 + 2000, 45.0));
      detector.onFix(fix(t0 + 4000, 0.0));

      for (var s = 5; s <= 30; s++) {
        final ev = detector.onFix(fix(t0 + s * 1000, 0.0));
        expect(ev, isNull);
      }
      expect(detector.evaluating, isFalse);
    });

    test('FP 4: Aggressive Cornering Lean - Leaning bike at speed does not trigger crash', () {
      final detector = CrashDetector();
      const t0 = 1700000000000;

      detector.onFix(fix(t0, 65.0));

      // Deep lean in bend: tilt 40°, but dynamic shock is low (0.4g) and smooth
      detector.onAccel(AccelBucket(
        tMs: t0 + 1000,
        peakG: 1.3,
        meanG: 1.0,
        stdG: 0.18,
        peakDynG: 0.4,
        peakGyroRadS: 0.5,
        tiltDeg: 40.0,
        peakJerkGPerS: 5.0,
      ));

      expect(detector.evaluating, isFalse);

      // Bike straightens out and continues at 68 km/h
      detector.onFix(fix(t0 + 2000, 68.0));
      expect(detector.evaluating, isFalse);
    });

    test('FP 5: Phone Dropped From Mount While Standing Still - Not armed, suppressed', () {
      final detector = CrashDetector();
      const t0 = 1700000000000;

      // Bike standing still (0 km/h)
      detector.onFix(fix(t0, 0.0));

      // Rider drops phone on pavement: 4.5g impact, 80° tilt
      detector.onAccel(AccelBucket(
        tMs: t0 + 1000,
        peakG: 4.8,
        meanG: 1.5,
        stdG: 1.2,
        peakDynG: 4.5,
        peakGyroRadS: 2.5,
        tiltDeg: 80.0,
        impactDurationMs: 50.0,
      ));

      expect(detector.evaluating, isFalse, reason: 'Unarmed standing drop must not trigger motorcycle crash');
    });

    test('FP 6: Motorcycle Parking and Side-Stand Deployment - Suppressed', () {
      final detector = CrashDetector();
      const t0 = 1700000000000;

      // Rider arrives, stops (0 km/h)
      detector.onFix(fix(t0, 0.0));

      // Puts down side-stand: tilt 22°, gentle lean (0.3g shock)
      detector.onAccel(AccelBucket(
        tMs: t0 + 1000,
        peakG: 1.1,
        meanG: 1.0,
        stdG: 0.05,
        peakDynG: 0.3,
        peakGyroRadS: 0.2,
        tiltDeg: 22.0,
      ));

      expect(detector.evaluating, isFalse);
    });
  });
}

