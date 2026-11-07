// 3.55 phone-only sensor safety: fatigue score, rider-down check, crash learning, phone-mount
// check, SOS battery reserve policy and the ride safety summary. Pure Dart logic with synthetic
// bucket and fix streams (no platform code).
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/crash_detector.dart';
import 'package:coroute_app/domain/safety/crash_incident.dart';
import 'package:coroute_app/domain/safety/crash_learning.dart';
import 'package:coroute_app/domain/safety/fatigue_score.dart';
import 'package:coroute_app/domain/safety/mount_classifier.dart';
import 'package:coroute_app/domain/safety/ride_safety_summary.dart';
import 'package:coroute_app/domain/safety/rider_down_detector.dart';
import 'package:coroute_app/domain/safety/sos_battery_reserve_policy.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

const int t0 = 1700000000000;
int at(num s) => t0 + (s * 1000).round();

TrackPoint fix(num s, double kmh, {double lat = 12.97, double lng = 77.59}) => TrackPoint(ts: at(s), lat: lat, lng: lng, speedKmh: kmh);

AccelBucket b(num s,
        {double peak = 1.0, double std = 0.02, double dyn = 0.0, double gyro = 0.02, double tilt = 5, double dur = 0, double jerk = 0}) =>
    AccelBucket(tMs: at(s), peakG: peak, meanG: 1.0, stdG: std, peakDynG: dyn, peakGyroRadS: gyro, tiltDeg: tilt, impactDurationMs: dur, peakJerkGPerS: jerk);

/// Feeds a rider-down detector: fixes every 5 s at [kmh], buckets from [buckets].
RiderDownEvent? runDown(RiderDownDetector d, List<AccelBucket> buckets, {double kmh = 2, bool fixes = true}) {
  RiderDownEvent? out;
  var nextFix = buckets.isEmpty ? 0 : buckets.first.tMs - 3000;
  for (final x in buckets) {
    while (fixes && nextFix <= x.tMs) {
      d.onFix(TrackPoint(ts: nextFix, lat: 12.97, lng: 77.59, speedKmh: kmh));
      nextFix += 5000;
    }
    out ??= d.onAccel(x);
  }
  return out;
}

/// Upright at a stop for [pre] s, then the fall at second [pre], then lying still.
List<AccelBucket> tipOver({int pre = 5, int after = 70, double fallTilt = 80, double thud = 2.2, double lyingStd = 0.01}) => [
      for (var s = 0; s < pre; s++) b(s, tilt: 4, std: 0.03),
      b(pre, tilt: 35, gyro: 2.0, peak: 1.3, std: 0.3),
      b(pre + 1, tilt: fallTilt, gyro: 1.5, peak: thud, dyn: 1.2, std: 0.4),
      for (var s = pre + 2; s < pre + 2 + after; s++) b(s, tilt: fallTilt - 2, std: lyingStd, gyro: 0.02),
    ];

void main() {
  // ------------------------------------------------------------------ fatigue score
  group('fatigue score', () {
    final noon = DateTime(2026, 11, 7, 11, 0);
    test('monotonic in ride time', () {
      var prev = -1;
      for (var m = 0; m <= 180; m += 5) {
        final a = FatigueScore.assess(stretch: Duration(minutes: m), localTime: noon);
        expect(a.level >= prev, isTrue);
        prev = a.level;
      }
      expect(FatigueScore.assess(stretch: const Duration(hours: 2), localTime: noon).level, 60);
    });

    test('circadian dips weigh more (night > afternoon > morning)', () {
      const s = Duration(minutes: 90);
      final morning = FatigueScore.assess(stretch: s, localTime: DateTime(2026, 11, 7, 10)).level;
      final afternoon = FatigueScore.assess(stretch: s, localTime: DateTime(2026, 11, 7, 15)).level;
      final night = FatigueScore.assess(stretch: s, localTime: DateTime(2026, 11, 7, 3)).level;
      expect(afternoon > morning, isTrue);
      expect(night > afternoon, isTrue);
      expect(FatigueScore.circadianFactor(DateTime(2026, 1, 1, 13, 59)), 1.0);
      expect(FatigueScore.circadianFactor(DateTime(2026, 1, 1, 14, 0)), 1.25);
      expect(FatigueScore.circadianFactor(DateTime(2026, 1, 1, 16, 0)), 1.0);
      expect(FatigueScore.circadianFactor(DateTime(2026, 1, 1, 5, 59)), 1.4);
      expect(FatigueScore.circadianFactor(DateTime(2026, 1, 1, 6, 0)), 1.0);
    });

    test('micro-stops and wobble add bounded points; level stays 0..100', () {
      expect(FatigueScore.microStopPoints(1), 4);
      expect(FatigueScore.microStopPoints(10), 12);
      expect(FatigueScore.wobblePoints(baselineVar: 0.01, currentVar: 0.012), 0);
      expect(FatigueScore.wobblePoints(baselineVar: 0.01, currentVar: 0.02) > 0, isTrue);
      expect(FatigueScore.wobblePoints(baselineVar: 0.01, currentVar: 1.0), 20);
      expect(FatigueScore.wobblePoints(baselineVar: null, currentVar: 1.0), 0);
      final max = FatigueScore.assess(
          stretch: const Duration(hours: 5), localTime: DateTime(2026, 1, 1, 2), microStops: 9, baselineVar: 0.01, currentVar: 1.0);
      expect(max.level, 100);
      expect(max.suggestedBreakInMin, 0);
    });

    test('suggested break is never later than the 2 h rule', () {
      for (var m = 0; m <= 130; m += 10) {
        final a = FatigueScore.assess(stretch: Duration(minutes: m), localTime: noon);
        expect(a.suggestedBreakInMin <= math.max(0, 120 - m), isTrue);
      }
      // A tired night rider: the break comes much earlier than the rule.
      final night = FatigueScore.assess(stretch: const Duration(minutes: 60), localTime: DateTime(2026, 1, 1, 2), microStops: 2);
      expect(night.suggestedBreakInMin < 60, isTrue);
    });

    test('tracker counts micro-stops of 1-10 min in the stretch only', () {
      final t = FatigueScoreTracker();
      final start = at(0);
      t.onFix(fix(0, 40), stretchStart: start);
      t.onFix(fix(10, 0), stretchStart: start); // stop 10 s .. 130 s
      t.onFix(fix(130, 30), stretchStart: start);
      expect(t.microStops, 1);
      t.onFix(fix(140, 0), stretchStart: start);
      t.onFix(fix(170, 30), stretchStart: start); // 30 s: too short
      expect(t.microStops, 1);
      t.onFix(fix(200, 30), stretchStart: null); // a break ended the stretch
      expect(t.microStops, 0);
    });

    test('steering wobble against the rider\'s own baseline', () {
      final t = FatigueScoreTracker(baselineFor: const Duration(minutes: 5), baselineMinSamples: 60, recentMinSamples: 30);
      final rnd = math.Random(7);
      var s = 0;
      // 10 min steady at 60 km/h: calm steering (baseline is the first 5 min).
      for (; s < 600; s++) {
        if (s % 2 == 0) t.onFix(fix(s, 60 + rnd.nextDouble()), stretchStart: at(0));
        t.onAccel(b(s, gyro: 0.20 + rnd.nextDouble() * 0.05));
      }
      final calm = t.assess(nowMs: at(s), localTime: noon);
      expect(calm.wobblePoints, 0);
      // Then wobbly steering for 5 min.
      for (; s < 900; s++) {
        if (s % 2 == 0) t.onFix(fix(s, 60 + rnd.nextDouble()), stretchStart: at(0));
        t.onAccel(b(s, gyro: 0.1 + rnd.nextDouble() * 0.6));
      }
      final wobbly = t.assess(nowMs: at(s), localTime: noon);
      expect(wobbly.wobblePoints > 0, isTrue);
      expect(wobbly.level > calm.level, isTrue);
    });

    test('wobble ignores unsteady speed and crash-like seconds', () {
      final t = FatigueScoreTracker();
      t.onFix(fix(0, 20), stretchStart: at(0));
      t.onFix(fix(1, 21), stretchStart: at(0));
      t.onAccel(b(1, gyro: 0.3)); // too slow
      t.onFix(fix(2, 60), stretchStart: at(0));
      t.onAccel(b(2, gyro: 0.3)); // speed jumped
      expect(t.baselineSamples, 0);
      t.onFix(fix(3, 61), stretchStart: at(0));
      t.onAccel(b(3, gyro: 0.3, peak: 4.0));
      expect(t.baselineSamples, 0);
      t.onAccel(b(3.5, gyro: 0.3));
      expect(t.baselineSamples, 1);
    });

    test('early prompt gate: 45 min minimum, 30 min spacing, never just before the rule', () {
      final g = FatigueEarlyPromptGate();
      final start = at(0);
      int m(num min) => start + (min * 60000).round();
      expect(g.allowed(nowMs: m(30), stretchStart: start, level: 90), isFalse); // under 45 min
      expect(g.allowed(nowMs: m(50), stretchStart: start, level: 60), isFalse); // not tired enough
      expect(g.allowed(nowMs: m(50), stretchStart: start, level: 75), isTrue);
      g.noteEarlyPrompt(m(50));
      expect(g.allowed(nowMs: m(70), stretchStart: start, level: 90), isFalse); // 30 min spacing
      expect(g.allowed(nowMs: m(95), stretchStart: start, level: 90), isFalse); // rule due at 120 within 30 min
      g.noteRulePrompt(m(120));
      expect(g.allowed(nowMs: m(140), stretchStart: start, level: 90), isFalse); // 30 min after the rule
      // After the 2 h rule it reminds hourly: an early prompt fits only exactly midway.
      expect(g.allowed(nowMs: m(155), stretchStart: start, level: 90), isFalse); // next rule at 180
      expect(g.allowed(nowMs: m(150), stretchStart: start, level: 90), isTrue);
      expect(g.allowed(nowMs: m(150), stretchStart: null, level: 90), isFalse); // on a break
    });
  });

  // ------------------------------------------------------------------ rider-down
  group('rider-down check', () {
    test('tip-over at a stop, then a still minute: one "Bike down?" event', () {
      final d = RiderDownDetector();
      final ev = runDown(d, tipOver());
      expect(ev, isNotNull);
      expect(ev!.tiltDeg >= 60, isTrue);
      expect(ev.atMs - ev.tipAtMs >= 60000, isTrue);
      // Cooldown: the same pattern right after does not fire again.
      final again = runDown(d, [for (final x in tipOver()) AccelBucket(tMs: x.tMs + 80000, peakG: x.peakG, meanG: 1, stdG: x.stdG, peakDynG: x.peakDynG, peakGyroRadS: x.peakGyroRadS, tiltDeg: x.tiltDeg)]);
      expect(again, isNull);
    });

    test('not before the minute of stillness', () {
      final d = RiderDownDetector();
      expect(runDown(d, tipOver(after: 50)), isNull);
      expect(d.evaluating, isTrue);
    });

    test('parking on the side stand (12 deg) never fires', () {
      final d = RiderDownDetector();
      final buckets = [
        for (var s = 0; s < 5; s++) b(s, tilt: 2, std: 0.05),
        b(5, tilt: 12, gyro: 0.8, peak: 1.6, std: 0.2),
        for (var s = 6; s < 90; s++) b(s, tilt: 13, std: 0.01),
      ];
      expect(runDown(d, buckets), isNull);
      expect(d.evaluating, isFalse);
    });

    test('phone lifted from the mount into a pocket (no thud, then walking) never fires', () {
      final d = RiderDownDetector();
      final buckets = [
        for (var s = 0; s < 5; s++) b(s, tilt: 3, std: 0.03),
        b(5, tilt: 40, gyro: 2.2, peak: 1.2, std: 0.2),
        b(6, tilt: 85, gyro: 1.8, peak: 1.25, std: 0.25),
        for (var s = 7; s < 90; s++) b(s, tilt: 80, std: 0.25, gyro: 0.9, peak: 1.4), // steps
      ];
      expect(runDown(d, buckets), isNull);
    });

    test('a thud while handling the phone, then walking: cancelled', () {
      final d = RiderDownDetector();
      final buckets = [
        for (var s = 0; s < 5; s++) b(s, tilt: 3, std: 0.03),
        b(5, tilt: 40, gyro: 2.2, peak: 1.3, std: 0.3),
        b(6, tilt: 85, gyro: 1.8, peak: 1.8, std: 0.3), // bumped the mount
        for (var s = 7; s < 90; s++) b(s, tilt: 80, std: 0.3, gyro: 0.8),
      ];
      expect(runDown(d, buckets), isNull);
      expect(d.lastCancel, 'moving');
    });

    test('phone in a pocket of a rider standing still (body sway): cancelled as carried', () {
      final d = RiderDownDetector();
      final buckets = [
        for (var s = 0; s < 5; s++) b(s, tilt: 3, std: 0.03),
        b(5, tilt: 40, gyro: 2.2, peak: 1.3, std: 0.3),
        b(6, tilt: 85, gyro: 1.8, peak: 1.7, std: 0.3),
        for (var s = 7; s < 90; s++) b(s, tilt: 80, std: 0.04, gyro: 0.45),
      ];
      expect(runDown(d, buckets), isNull);
      expect(d.lastCancel, 'carried');
    });

    test('walking with the phone before the tilt: never starts', () {
      final d = RiderDownDetector();
      final buckets = [
        for (var s = 0; s < 5; s++) b(s, tilt: 10, std: 0.3, gyro: 0.6),
        b(5, tilt: 40, gyro: 2.0, peak: 1.6, std: 0.3),
        b(6, tilt: 85, gyro: 1.5, peak: 2.0, std: 0.3),
        for (var s = 7; s < 90; s++) b(s, tilt: 83, std: 0.01),
      ];
      expect(runDown(d, buckets), isNull);
    });

    test('at riding speed, or with no fix at all: never (the crash detector owns those)', () {
      expect(runDown(RiderDownDetector(), tipOver(), kmh: 25), isNull);
      expect(runDown(RiderDownDetector(), tipOver(), fixes: false), isNull);
    });

    test('bike lifted back up, or riding on: cancelled', () {
      final d = RiderDownDetector();
      final lifted = [
        ...tipOver(after: 20),
        for (var s = 27; s < 90; s++) b(s, tilt: 5, std: 0.02),
      ];
      expect(runDown(d, lifted), isNull);
      expect(d.lastCancel, 'lifted');
      final d2 = RiderDownDetector();
      final list = tipOver(after: 70);
      RiderDownEvent? out;
      for (final x in list) {
        if (x.tMs == at(30)) d2.onFix(fix(30, 20));
        if (x.tMs < at(30)) d2.onFix(TrackPoint(ts: x.tMs, lat: 12.97, lng: 77.59, speedKmh: 1));
        out ??= d2.onAccel(x);
      }
      expect(out, isNull);
      expect(d2.lastCancel, 'riding');
    });
  });

  // ------------------------------------------------------------------ crash learning
  group('crash detection that learns', () {
    test('+5% per false alarm, capped at +25%, only on the stage that fired', () {
      var s = CrashLearningState.none;
      s = CrashLearning.onFalseAlarm(s, CrashScenario.lowsideSlide);
      expect(s.slidePct, 5);
      expect(s.lowFallPct, 0);
      expect(s.falseAlarms, 1);
      for (var i = 0; i < 10; i++) {
        s = CrashLearning.onFalseAlarm(s, CrashScenario.lowsideSlide);
      }
      expect(s.slidePct, 25);
      expect(s.slideScale, 1.25);
      s = CrashLearning.onFalseAlarm(s, CrashScenario.stationaryDrop);
      expect(s.lowFallPct, 5);
      expect(CrashLearning.settingsLine(s), 'Learned from 12 false alarms on this bike');
      expect(CrashLearning.settingsLine(CrashLearningState.none), isNull);
    });

    test('severe paths (high impact, high-side) never learn', () {
      final s = CrashLearning.onFalseAlarm(CrashLearningState.none, CrashScenario.highImpactCollision);
      expect(s, CrashLearningState.none);
      expect(CrashLearning.onFalseAlarm(s, CrashScenario.highsideFall), CrashLearningState.none);
      expect(CrashLearning.learns(CrashScenario.unknown), isFalse);
    });

    test('decays 2 points per alarm-free riding hour, never below zero', () {
      var s = const CrashLearningState(slidePct: 10, lowFallPct: 3, falseAlarms: 2);
      s = CrashLearning.onRideTime(s, 30 * 60000);
      expect(s.slidePct, 10);
      s = CrashLearning.onRideTime(s, 30 * 60000);
      expect(s.slidePct, 8);
      expect(s.lowFallPct, 1);
      s = CrashLearning.onRideTime(s, 3 * 3600000);
      expect(s.slidePct, 2);
      expect(s.lowFallPct, 0);
      // A false alarm starts the alarm-free hour again.
      s = CrashLearning.onRideTime(s, 50 * 60000);
      s = CrashLearning.onFalseAlarm(s, CrashScenario.lowsideSlide);
      expect(s.rideMsSinceDecay, 0);
    });

    test('a real alarm forgets the stage that fired', () {
      const s = CrashLearningState(slidePct: 20, lowFallPct: 10, falseAlarms: 6);
      final r = CrashLearning.onRealAlarm(s, CrashScenario.lowsideSlide);
      expect(r.slidePct, 0);
      expect(r.lowFallPct, 10);
    });

    test('JSON is bounded and survives junk', () {
      final s = CrashLearningState.fromJson({'s': 999, 'l': -5, 'n': 3, 'r': 1e12});
      expect(s.slidePct, 25);
      expect(s.lowFallPct, 0);
      expect(s.rideMsSinceDecay < 3600000, isTrue);
      expect(CrashLearningState.fromJson('x'), CrashLearningState.none);
      final all = {for (var i = 0; i < 30; i++) 'bike$i': {'s': 5, 'n': 1}};
      expect(CrashLearning.decodeAll(all).length, CrashLearning.maxBikes);
      expect(CrashLearning.bikeKey(null), 'default');
      expect(CrashLearning.bikeKey('  '), 'default');
    });

    /// Arms the detector (60 km/h), then one impact bucket, a stop and 25 s of stillness.
    CrashEvent? ride(CrashDetector d, AccelBucket impact) {
      for (var s = 0; s <= 20; s++) {
        d.onFix(fix(s, 60));
      }
      CrashEvent? ev = d.onAccel(impact);
      for (var s = 22; s <= 50; s++) {
        ev ??= d.onFix(fix(s, s < 24 ? 3 : 0));
        ev ??= d.onAccel(b(s, std: 0.01));
      }
      return ev;
    }

    AccelBucket slide(double g) => b(20.5, peak: g, dyn: g, gyro: 2.0, tilt: 30, dur: 60, jerk: 20);
    AccelBucket severe() => b(20.5, peak: 5.0, dyn: 4.5, gyro: 0.3, tilt: 5, dur: 80, jerk: 40);

    test('default scales leave the crash rule exactly as before', () {
      final d = CrashDetector();
      expect(d.slideScale, 1.0);
      expect(ride(d, slide(1.7)), isNotNull);
    });

    test('learned thresholds filter a mild fall pattern, but a severe impact always alarms', () {
      final d = CrashDetector()..setLearnedScales(slide: 1.25, lowFall: 1.25);
      // 1.7 g with rotation: the low-speed fall stage (1.5 g) fires at the plain rule; learned
      // to 1.875 g it does not, and the slide stage (2.0 g -> 2.5 g) never did.
      expect(ride(d, slide(1.7)), isNull);
      final d2 = CrashDetector()..setLearnedScales(slide: 1.25, lowFall: 1.25);
      final ev = ride(d2, severe());
      expect(ev, isNotNull);
      expect(ev!.scenario, CrashScenario.highImpactCollision);
      // A high-side tumble also still alarms at the maximum learning.
      final d3 = CrashDetector()..setLearnedScales(slide: 1.25, lowFall: 1.25);
      expect(ride(d3, b(20.5, peak: 3.2, dyn: 2.6, gyro: 3.0, tilt: 70, dur: 70, jerk: 30)), isNotNull);
    });

    test('scales are clamped to 1.0..1.25', () {
      final d = CrashDetector()..setLearnedScales(slide: 9, lowFall: 0.2);
      expect(d.slideScale, CrashDetector.maxLearnedScale);
      expect(d.lowFallScale, 1.0);
      d.setLearnedScales(slide: double.nan);
      expect(d.slideScale, 1.0);
      d.reset();
      d.setLearnedScales(slide: 1.1);
      d.reset();
      expect(d.slideScale, closeTo(1.1, 1e-9)); // a new ride keeps the bike's learning
    });
  });

  // ------------------------------------------------------------------ mount classifier
  group('phone-mount check', () {
    MountKind? classify(AccelBucket Function(int s, math.Random r) gen, {double kmh = 50, int n = 320}) {
      final c = MountClassifier();
      final r = math.Random(3);
      for (var s = 0; s < n; s++) {
        final k = c.onBucket(gen(s, r), speedKmh: kmh);
        if (k != null) return k;
      }
      return c.result;
    }

    test('mounted: steady engine vibration, smooth lean', () {
      expect(
          classify((s, r) => b(s, std: 0.06 + r.nextDouble() * 0.02, gyro: 0.15 + r.nextDouble() * 0.1, tilt: 12 * math.sin(s / 15))),
          MountKind.mounted);
    });

    test('pocket: damped vibration and body motion', () {
      expect(
          classify((s, r) => b(s, std: 0.015 + r.nextDouble() * 0.01, gyro: 0.4 + r.nextDouble() * 0.3, tilt: 20 + 12 * math.sin(s / 9))),
          MountKind.pocket);
    });

    test('loose / bag: large random orientation changes', () {
      expect(classify((s, r) => b(s, std: 0.05, gyro: 1.0, tilt: r.nextDouble() * 90)), MountKind.loose);
    });

    test('slow riding is not counted; unclear data gives unknown (no card)', () {
      expect(classify((s, r) => b(s, std: 0.06, tilt: 5), kmh: 10), isNull);
      // Damped vibration but no body motion: neither pattern.
      final k = classify((s, r) => b(s, std: 0.02, gyro: 0.1, tilt: 3 + r.nextDouble()));
      expect(k, MountKind.unknown);
      expect(k!.weak, isFalse);
      expect(MountKind.pocket.weak, isTrue);
    });
  });

  // ------------------------------------------------------------------ SOS battery reserve
  group('SOS battery reserve policy', () {
    test('on below 10% in a ride, with hysteresis up to 15%', () {
      final p = SosBatteryReservePolicy();
      expect(p.update(percent: 10, charging: false, rideActive: true), SosReserveChange.none);
      expect(p.update(percent: 9, charging: false, rideActive: true), SosReserveChange.entered);
      expect(p.active, isTrue);
      expect(p.update(percent: 12, charging: false, rideActive: true), SosReserveChange.none);
      expect(p.update(percent: 14, charging: false, rideActive: true), SosReserveChange.none);
      expect(p.active, isTrue);
      expect(p.update(percent: 15, charging: false, rideActive: true), SosReserveChange.exited);
      expect(p.active, isFalse);
    });

    test('off on charging or at the end of the ride; never outside a ride', () {
      final p = SosBatteryReservePolicy();
      expect(p.update(percent: 5, charging: false, rideActive: false), SosReserveChange.none);
      expect(p.update(percent: 5, charging: true, rideActive: true), SosReserveChange.none);
      expect(p.update(percent: 5, charging: false, rideActive: true), SosReserveChange.entered);
      expect(p.update(percent: 5, charging: true, rideActive: true), SosReserveChange.exited);
      expect(p.update(percent: 5, charging: false, rideActive: true), SosReserveChange.entered);
      expect(p.update(percent: 5, charging: false, rideActive: false), SosReserveChange.exited);
      expect(p.update(percent: -1, charging: false, rideActive: true), SosReserveChange.none);
    });

    test('the last location goes out once per ride', () {
      final p = SosBatteryReservePolicy();
      expect(p.claimBeacon('g1'), isFalse); // not active
      p.update(percent: 8, charging: false, rideActive: true);
      expect(p.claimBeacon('g1'), isTrue);
      expect(p.claimBeacon('g1'), isFalse);
      p.update(percent: 30, charging: false, rideActive: true);
      p.update(percent: 8, charging: false, rideActive: true);
      expect(p.claimBeacon('g1'), isFalse); // same ride
      expect(p.claimBeacon('g2'), isTrue); // next ride
      p.releaseBeacon('g2');
      expect(p.claimBeacon('g2'), isTrue); // not sent: may try again
    });
  });

  // ------------------------------------------------------------------ ride safety summary
  group('ride safety summary', () {
    test('counts over-limit minutes and km after dark from fixes', () {
      final a = RideSafetyAccumulator();
      // 3 min at 75 km/h with a 60 limit, fixes every 2 s, after dark, moving ~41.7 m per 2 s.
      for (var s = 0; s <= 180; s += 2) {
        a.onFix(fix(s, 75, lat: 12.97 + s * 0.0001875), limitKmh: 60, toleranceKmh: 1.5, dark: true);
      }
      expect(a.overLimitMin, 3);
      expect(a.nightKm > 3.5 && a.nightKm < 4.0, isTrue);
      // A long GPS gap is not counted.
      a.onFix(fix(400, 75, lat: 13.5), limitKmh: 60, dark: true);
      expect(a.overLimitMin, 3);
      expect(a.nightKm < 4.0, isTrue);
    });

    test('JSON round trip is compact and backward compatible', () {
      final a = RideSafetyAccumulator()
        ..fatiguePeak = 72
        ..bikeDownChecks = 1
        ..roadHazards = 4
        ..mount = 'pocket';
      a.onReserve(true, at(0));
      final s = a.build(hardBrakes: 2, breaks: 1, nowMs: at(600));
      expect(s.sosReserveMin, 10);
      final j = s.toJson();
      final back = RideSafetySummary.fromJson(j)!;
      expect(back.hardBrakes, 2);
      expect(back.fatiguePeak, 72);
      expect(back.mount, 'pocket');
      expect(back.sosReserveMin, 10);
      expect(RideSafetySummary.fromJson(null), isNull);
      expect(RideSafetySummary.fromJson({'fp': 500, 'hb': -3}), isNotNull);
      expect(RideSafetySummary.fromJson({'fp': 500})!.fatiguePeak, 100);
      expect(const RideSafetySummary().toJson().isEmpty, isTrue);
      final lines = back.lines();
      expect(lines.first.$1, 'Hard brakes');
      expect(lines.any((l) => l.$1 == '"Bike down?" checks'), isTrue);
    });
  });
}
