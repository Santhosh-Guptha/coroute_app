import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/domain/intel/intel_event.dart';
import 'package:coroute_app/domain/intel/ride_signal_detector.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/crash_detector.dart';
import 'package:coroute_app/domain/safety/mount_classifier.dart';
import 'package:coroute_app/domain/safety/road_surface_detector.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

/// Round 4: which road surface events become shared road quality signals (feature 7, mount aware), the swerve /
/// skid detector thresholds (feature 6), and the crash brain scale bounds on the detector (feature 14).
void main() {
  RoadSurfaceEvent ev(RoadSurfaceKind k, {double speed = 40, double conf = 0.9}) =>
      RoadSurfaceEvent(kind: k, severity: 'HIGH', lat: 12.97, lng: 77.59, speedKmh: speed, peakDynG: 1.4, peakGyroDegS: 20, confidence: conf, tMs: 1000);

  group('pothole / rough road gate', () {
    test('only above 20 km/h; speed breakers are not road defects', () {
      expect(PotholeIntelGate.eventOf(ev(RoadSurfaceKind.pothole, speed: 20), mount: MountKind.mounted), isNull);
      expect(PotholeIntelGate.eventOf(ev(RoadSurfaceKind.pothole, speed: 21), mount: MountKind.mounted)?.type, IntelEventType.pothole);
      expect(PotholeIntelGate.eventOf(ev(RoadSurfaceKind.roughRoad), mount: MountKind.mounted)?.type, IntelEventType.rough);
      expect(PotholeIntelGate.eventOf(ev(RoadSurfaceKind.speedBreaker), mount: MountKind.mounted), isNull);
    });

    test('mount aware: pocket / loose skipped, unknown mount low confidence, handlebar mount as detected', () {
      expect(PotholeIntelGate.eventOf(ev(RoadSurfaceKind.pothole), mount: MountKind.pocket), isNull);
      expect(PotholeIntelGate.eventOf(ev(RoadSurfaceKind.pothole), mount: MountKind.loose), isNull);
      expect(PotholeIntelGate.eventOf(ev(RoadSurfaceKind.pothole), mount: MountKind.unknown)!.conf, closeTo(0.45, 0.001));
      expect(PotholeIntelGate.eventOf(ev(RoadSurfaceKind.pothole), mount: MountKind.mounted)!.conf, closeTo(0.9, 0.001));
    });

    test('the event carries a 150 m cell, heading and speed buckets, never the exact position on the wire', () {
      final e = PotholeIntelGate.eventOf(ev(RoadSurfaceKind.pothole, speed: 47), mount: MountKind.mounted, headingDeg: 92)!;
      expect(e.gh, hasLength(7));
      expect(e.hb, 2);
      expect(e.sb, 2);
      final w = e.toWire();
      expect(w.keys, isNot(contains('la')));
      expect(w.keys, containsAll(['type', 'gh', 'hb', 'sb', 'how', 'ts', 'conf']));
    });
  });

  group('swerve / skid detector', () {
    AccelBucket b(int t, {double gyro = 0, double tilt = 5, double peak = 1.2, double conf = 1}) =>
        AccelBucket(tMs: t, peakG: peak, meanG: 1, stdG: 0.2, peakGyroRadS: gyro, tiltDeg: tilt, sensorConfidence: conf);

    test('a sharp rotation at speed without lean is a swerve; deduped for 20 s', () {
      final d = RideSignalDetector()..onFix(const TrackPoint(ts: 1000, lat: 1, lng: 1, speedKmh: 50));
      expect(d.onBucket(b(1000, gyro: 2.7), busy: false), IntelEventType.swerve);
      d.onFix(const TrackPoint(ts: 5000, lat: 1, lng: 1, speedKmh: 50));
      expect(d.onBucket(b(5000, gyro: 3.0), busy: false), isNull, reason: 'dedupe');
      d.onFix(const TrackPoint(ts: 26000, lat: 1, lng: 1, speedKmh: 50));
      expect(d.onBucket(b(26000, gyro: 3.0), busy: false), IntelEventType.swerve);
    });

    test('conservative: below 30 km/h, below 2.6 rad/s, leaning into a corner, pocket, busy crash detector or crash-level impact: nothing', () {
      RideSignalDetector at(double v) => RideSignalDetector()..onFix(TrackPoint(ts: 1000, lat: 1, lng: 1, speedKmh: v));
      expect(at(25).onBucket(b(1000, gyro: 3), busy: false), isNull);
      expect(at(50).onBucket(b(1000, gyro: 2.4), busy: false), isNull);
      expect(at(50).onBucket(b(1000, gyro: 3, tilt: 28), busy: false), isNull);
      expect(at(50).onBucket(b(1000, gyro: 3), busy: false, mount: MountKind.pocket), isNull);
      expect(at(50).onBucket(b(1000, gyro: 3), busy: true), isNull);
      expect(at(50).onBucket(b(1000, gyro: 3, peak: SafetyConstants.crashImpactG), busy: false), isNull);
      expect(at(50).onBucket(b(1000, gyro: 3, conf: 0.3), busy: false), isNull);
    });

    test('a rotation snap with a tilt spike and a speed drop of 12 km/h within 4 s is a skid', () {
      final d = RideSignalDetector()..onFix(const TrackPoint(ts: 1000, lat: 1, lng: 1, speedKmh: 45));
      expect(d.onBucket(b(1000, gyro: 2.2, tilt: 35), busy: false), isNull, reason: 'candidate');
      d.onFix(const TrackPoint(ts: 3000, lat: 1, lng: 1, speedKmh: 30));
      expect(d.onBucket(b(3000), busy: false), IntelEventType.skid);
      final e = RideSignalDetector()..onFix(const TrackPoint(ts: 1000, lat: 1, lng: 1, speedKmh: 45));
      e.onBucket(b(1000, gyro: 2.2, tilt: 35), busy: false);
      e.onFix(const TrackPoint(ts: 7000, lat: 1, lng: 1, speedKmh: 30));
      expect(e.onBucket(b(7000), busy: false), isNull, reason: 'too late: not a skid');
    });
  });

  group('crash brain scale on the detector', () {
    test('clamped to 0.9-1.15; 1.0 by default; bad values mean 1.0', () {
      final d = CrashDetector();
      expect(d.brainImpactScale, 1.0);
      d.setBrainImpactScale(1.5);
      expect(d.brainImpactScale, 1.15);
      d.setBrainImpactScale(0.5);
      expect(d.brainImpactScale, 0.9);
      d.setBrainImpactScale(double.nan);
      expect(d.brainImpactScale, 1.0);
    });

    test('severe impacts stay above the highest scaled threshold (the fast path is never touched)', () {
      expect(SafetyConstants.crashSevereImpactG, greaterThan(SafetyConstants.crashImpactG * CrashDetector.maxBrainScale));
      expect(SafetyConstants.crashSevereDynG, greaterThan(SafetyConstants.crashDynamicImpactG * CrashDetector.maxBrainScale));
    });
  });
}
