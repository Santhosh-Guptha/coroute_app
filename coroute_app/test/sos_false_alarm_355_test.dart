// 3.55 false-SOS review: recorded-like synthetic sensor + GPS sequences for the automatic alarm
// paths (crash detector, rider-down check, alarm countdown). Pure Dart.
//
// Each scenario is a second-by-second ride: a GPS fix (speed, position, accuracy) and the native
// one-second accelerometer / gyroscope bucket (AccelStream.kt: peak, mean, std, dynamic peak, gyro,
// tilt from the riding baseline, impact duration, jerk). The harness feeds them exactly as
// SafetyService does (crash detector first; the rider-down check rests while the crash detector
// weighs an impact) and then plays the alarm countdown (riding away cancels it, see
// SafetyService._onFix). An "SOS" below means the countdown ran out: an automatic SOS would go out.
//
// Expected: an SOS only for real crashes and a tip-over at a stop.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/crash_detector.dart';
import 'package:coroute_app/domain/safety/rider_down_detector.dart';
import 'package:coroute_app/domain/safety/riding_motion.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

const int t0 = 1762770000000;
const double lat0 = 12.9716, lng0 = 77.5946;

/// Bucket shapes (values from the native reduction, in g, rad/s and degrees).
class Feel {
  final double peak, std, dyn, gyro, tilt, dur, jerk;
  const Feel({this.peak = 1.3, this.std = 0.2, this.dyn = 0.4, this.gyro = 0.4, this.tilt = 5, this.dur = 0, this.jerk = 8});
}

class Sim {
  Sim(int seed) : _r = math.Random(seed);
  final math.Random _r;
  final List<(int, Object)> events = [];
  int s = 0; // current second
  double northM = 0;
  double kmh = 0;
  double baseTilt = 5; // the phone's riding orientation (from the native baseline)

  double j(double v, double spread) => v + (_r.nextDouble() * 2 - 1) * spread;

  void _fix({double acc = 5}) =>
      events.add((t0 + s * 1000, TrackPoint(ts: t0 + s * 1000, lat: lat0 + northM / 111320.0, lng: lng0, speedKmh: math.max(0, kmh), accuracyM: acc)));

  void _bucket(Feel f) => events.add((
        t0 + s * 1000,
        AccelBucket(
          tMs: t0 + s * 1000,
          peakG: f.peak,
          meanG: 1.0,
          stdG: f.std,
          peakDynG: f.dyn,
          peakGyroRadS: f.gyro,
          tiltDeg: f.tilt,
          impactDurationMs: f.dur,
          peakJerkGPerS: f.jerk,
        )
      ));

  /// One second: the bike moves on at [speed], a fix (unless [gps] is false) and a bucket.
  void tick(double speed, Feel f, {bool gps = true, double acc = 5}) {
    kmh = speed;
    northM += speed / 3.6;
    if (gps) _fix(acc: acc);
    _bucket(f);
    s++;
  }

  // ---------------------------------------------------------------- feels
  Feel riding({double rough = 1}) => Feel(
        peak: j(1.45, 0.15 * rough),
        std: j(0.22, 0.06 * rough),
        dyn: j(0.45, 0.15 * rough),
        gyro: j(0.45, 0.2),
        tilt: j(baseTilt, 3),
        jerk: j(9, 3),
      );
  Feel idle() => Feel(peak: j(1.1, 0.03), std: j(0.07, 0.02), dyn: j(0.15, 0.05), gyro: j(0.1, 0.04), tilt: j(baseTilt, 1.5), jerk: 2);
  Feel lying(double tilt) => Feel(peak: 1.01, std: j(0.01, 0.004), dyn: 0.02, gyro: j(0.012, 0.006), tilt: j(tilt, 1), jerk: 0.3);
  Feel walking() => Feel(peak: j(1.7, 0.2), std: j(0.38, 0.06), dyn: j(0.8, 0.2), gyro: j(1.0, 0.3), tilt: j(12, 6), jerk: 12);

  // ---------------------------------------------------------------- manoeuvres
  void cruise(int seconds, double speed, {double rough = 1}) {
    for (var i = 0; i < seconds; i++) {
      tick(j(speed, 1.5), riding(rough: rough));
    }
  }

  /// Brakes from the current speed to 0 at [decel] m/s2.
  void brakeToStop({double decel = 2.5}) {
    var v = kmh;
    while (v > 0) {
      v = math.max(0, v - decel * 3.6);
      tick(v, Feel(peak: j(1.35, 0.1), std: j(0.16, 0.04), dyn: j(0.25 + decel / 10, 0.05), gyro: j(0.25, 0.1), tilt: j(baseTilt + 3, 2), jerk: 6));
    }
  }

  /// Slows from the current speed to [speed] at [decel] m/s2.
  void slowTo(double speed, {double decel = 2.0}) {
    var v = kmh;
    while (v > speed) {
      v = math.max(speed, v - decel * 3.6);
      tick(v, riding());
    }
  }

  void accelerateTo(double speed, {double accel = 2.0}) {
    var v = kmh;
    while (v < speed) {
      v = math.min(speed, v + accel * 3.6);
      tick(v, riding());
    }
  }

  void waitIdle(int seconds) {
    for (var i = 0; i < seconds; i++) {
      tick(j(0.5, 0.5), idle());
    }
  }
}

/// What the alarm paths did with a ride.
class Outcome {
  final List<String> alarms = []; // 'crash' / 'rider-down' when an alarm opened
  final List<String> cancelled = []; // alarms cancelled by riding away during the countdown
  int sos = 0; // countdowns that ran out
  @override
  String toString() => 'alarms $alarms, cancelled $cancelled, SOS $sos';
}

Outcome play(Sim sim) {
  final crash = CrashDetector();
  final down = RiderDownDetector();
  final out = Outcome();
  final ordered = List.of(sim.events)..sort((a, b) => a.$1.compareTo(b.$1));
  int? alarmAt;
  String? alarmKind;
  RideOnRun? rideOn;
  final countdown = SafetyConstants.crashCountdown.inMilliseconds;

  void open(String kind, int at) {
    if (alarmAt != null) return;
    alarmAt = at;
    alarmKind = kind;
    rideOn = RideOnRun(minKmh: SafetyConstants.crashResumeKmh, minSpan: SafetyConstants.crashRideOnFor);
    out.alarms.add(kind);
    down.suppress(at);
  }

  for (final (t, e) in ordered) {
    final a = alarmAt;
    if (a != null && t - a >= countdown) {
      out.sos++;
      alarmAt = null;
      crash.cooldown(t);
    }
    if (e is TrackPoint) {
      if (alarmAt != null && rideOn!.add(e)) {
        out.cancelled.add(alarmKind!);
        alarmAt = null;
        crash.cooldown(t);
      }
      final ev = crash.onFix(e);
      down.onFix(e);
      if (ev != null) open('crash', t);
    } else if (e is AccelBucket) {
      final ev = crash.onAccel(e);
      if (ev != null) open('crash', t);
      if (alarmAt != null || crash.evaluating) {
        down.suppress(e.tMs, forDuration: const Duration(seconds: 30));
      } else {
        final d = down.onAccel(e);
        if (d != null) open('rider-down', t);
      }
    }
  }
  if (alarmAt != null && ordered.isNotEmpty && ordered.last.$1 - alarmAt! >= countdown) out.sos++;
  return out;
}

// -------------------------------------------------------------------- scenarios
Sim potholesAt60(int seed) {
  final m = Sim(seed);
  m.accelerateTo(60);
  m.cruise(30, 60);
  for (var k = 0; k < 8; k++) {
    // A pothole: a sharp jolt, the phone rattles in its mount, the ride goes on.
    m.tick(60, Feel(peak: m.j(6.0, 0.6), std: 1.1, dyn: m.j(5.0, 0.6), gyro: m.j(1.4, 0.4), tilt: m.j(14, 4), dur: m.j(55, 15), jerk: 70));
    m.cruise(m._r.nextInt(10) + 8, 60);
  }
  // A clipped 8 g spike (very short) and a pothole just before the brakes for a red light.
  m.tick(60, const Feel(peak: 8.0, std: 1.4, dyn: 7.2, gyro: 1.3, tilt: 12, dur: 25, jerk: 90));
  m.cruise(25, 60);
  m.tick(58, Feel(peak: 6.3, std: 1.2, dyn: 5.4, gyro: 1.5, tilt: 16, dur: 60, jerk: 75));
  m.cruise(1, 55);
  m.brakeToStop(decel: 2.8);
  m.waitIdle(90); // a long Indian red light
  m.accelerateTo(50);
  m.cruise(30, 50);
  return m;
}

Sim speedBreakers(int seed) {
  final m = Sim(seed);
  m.accelerateTo(45);
  m.cruise(20, 45);
  for (var k = 0; k < 4; k++) {
    m.slowTo(20);
    m.tick(20, Feel(peak: m.j(4.6, 0.4), std: 0.9, dyn: m.j(4.1, 0.3), gyro: m.j(2.3, 0.4), tilt: m.j(22, 5), dur: m.j(110, 20), jerk: 45));
    m.cruise(3, 20);
    m.accelerateTo(45);
    m.cruise(20, 45);
  }
  // A speed breaker right at a toll booth: hit at 20 km/h, stopped 3 s later, a minute in the queue.
  m.brakeToStop(decel: 2.0);
  m.accelerateTo(20);
  m.tick(20, const Feel(peak: 4.8, std: 1.0, dyn: 4.3, gyro: 2.4, tilt: 24, dur: 120, jerk: 50));
  m.brakeToStop(decel: 2.5);
  m.waitIdle(70);
  m.accelerateTo(40);
  m.cruise(20, 40);
  return m;
}

Sim roughRoad10min(int seed) {
  final m = Sim(seed);
  m.accelerateTo(35);
  for (var minute = 0; minute < 10; minute++) {
    for (var i = 0; i < 55; i++) {
      final big = m._r.nextDouble() < 0.12;
      final f = big
          ? Feel(peak: m.j(3.4, 0.6), std: m.j(0.6, 0.15), dyn: m.j(3.0, 0.7), gyro: m.j(2.0, 0.5), tilt: m.j(20, 10), dur: m.j(60, 25), jerk: 40)
          : m.riding(rough: 2.5);
      m.tick(m.j(32, 6), f);
    }
    if (minute % 3 == 1) {
      // Traffic: a big bump while slowing, then a stop.
      m.tick(25, Feel(peak: 4.3, std: 0.8, dyn: 3.9, gyro: 2.1, tilt: 26, dur: 70, jerk: 45));
      m.brakeToStop(decel: 2.5);
      m.waitIdle(40 + m._r.nextInt(30));
      m.accelerateTo(32);
    }
  }
  return m;
}

Sim phoneDropAtStop(int seed) {
  final m = Sim(seed);
  m.accelerateTo(40);
  m.cruise(30, 40);
  m.brakeToStop();
  m.waitIdle(30);
  // The rider takes the phone out of the mount and drops it on the road.
  m.tick(0, const Feel(peak: 1.4, std: 0.15, dyn: 0.5, gyro: 1.5, tilt: 40, jerk: 10));
  m.tick(0, const Feel(peak: 7.5, std: 2.0, dyn: 6.6, gyro: 6.0, tilt: 88, dur: 30, jerk: 120));
  for (var i = 0; i < 12; i++) {
    m.tick(0, m.lying(87));
  }
  // Picked up, looked at, clipped back into the mount.
  for (var i = 0; i < 6; i++) {
    m.tick(0, const Feel(peak: 1.5, std: 0.3, dyn: 0.6, gyro: 1.4, tilt: 50, jerk: 10));
  }
  m.waitIdle(20);
  m.accelerateTo(40);
  m.cruise(20, 40);
  return m;
}

Sim phonePickUp(int seed) {
  final m = Sim(seed);
  m.accelerateTo(30);
  m.cruise(30, 30);
  // Picks the phone up while rolling (bad habit) and puts it back.
  m.tick(30, const Feel(peak: 1.6, std: 0.3, dyn: 0.7, gyro: 2.6, tilt: 70, jerk: 14));
  for (var i = 0; i < 5; i++) {
    m.tick(28, const Feel(peak: 1.3, std: 0.12, dyn: 0.4, gyro: 0.5, tilt: 60, jerk: 6));
  }
  m.tick(30, const Feel(peak: 1.7, std: 0.3, dyn: 0.8, gyro: 2.2, tilt: 30, jerk: 14));
  m.cruise(20, 30);
  m.brakeToStop();
  m.waitIdle(15);
  // At the light: picks it up and reads for a minute and a half.
  m.tick(0, const Feel(peak: 1.4, std: 0.2, dyn: 0.5, gyro: 2.0, tilt: 45, jerk: 10));
  m.tick(0, const Feel(peak: 1.5, std: 0.2, dyn: 0.6, gyro: 1.6, tilt: 62, jerk: 10));
  for (var i = 0; i < 90; i++) {
    m.tick(0, Feel(peak: 1.03, std: m.j(0.02, 0.01), dyn: 0.05, gyro: m.j(0.1, 0.05), tilt: m.j(60, 3), jerk: 1));
  }
  m.accelerateTo(30);
  m.cruise(20, 30);
  return m;
}

Sim hardBrakeToZero(int seed) {
  final m = Sim(seed);
  m.accelerateTo(60);
  m.cruise(30, 60);
  // Emergency stop with ABS judder: strong but pure deceleration, the fork dives.
  var v = 60.0;
  while (v > 0) {
    v = math.max(0, v - 7.5 * 3.6);
    m.tick(v, Feel(peak: m.j(1.9, 0.2), std: 0.35, dyn: m.j(1.9, 0.3), gyro: m.j(0.35, 0.1), tilt: m.j(10, 1.5), dur: 0, jerk: 20));
  }
  m.waitIdle(60);
  m.accelerateTo(40);
  m.cruise(20, 40);
  return m;
}

Sim realCrashSlide(int seed) {
  final m = Sim(seed);
  m.accelerateTo(50);
  m.cruise(40, 50);
  // Impact (not "severe": 6.5 g raw, 5.5 g dynamic), the bike goes down and slides.
  m.tick(48, const Feel(peak: 6.5, std: 1.8, dyn: 5.5, gyro: 3.5, tilt: 70, dur: 120, jerk: 80));
  m.tick(35, const Feel(peak: 3.0, std: 0.9, dyn: 2.5, gyro: 2.5, tilt: 84, dur: 40, jerk: 30));
  m.tick(18, const Feel(peak: 2.6, std: 0.8, dyn: 2.0, gyro: 2.0, tilt: 88, jerk: 25));
  m.tick(6, const Feel(peak: 2.0, std: 0.5, dyn: 1.2, gyro: 1.0, tilt: 86, jerk: 15));
  for (var i = 0; i < 80; i++) {
    m.tick(0, m.lying(82));
  }
  return m;
}

Sim highSide(int seed) {
  final m = Sim(seed);
  m.accelerateTo(70);
  m.cruise(40, 70);
  m.tick(68, const Feel(peak: 5.5, std: 1.6, dyn: 4.8, gyro: 5.5, tilt: 140, dur: 90, jerk: 70));
  m.tick(50, const Feel(peak: 4.0, std: 1.5, dyn: 3.5, gyro: 4.0, tilt: 165, dur: 60, jerk: 50));
  m.tick(25, const Feel(peak: 3.0, std: 1.2, dyn: 2.4, gyro: 3.0, tilt: 120, jerk: 40));
  m.tick(8, const Feel(peak: 2.2, std: 0.7, dyn: 1.4, gyro: 1.5, tilt: 100, jerk: 20));
  for (var i = 0; i < 80; i++) {
    m.tick(0, m.lying(95));
  }
  return m;
}

Sim crashThenWalksAway(int seed) {
  final m = Sim(seed);
  m.accelerateTo(55);
  m.cruise(40, 55);
  // Phone in the rider's jacket: a severe hit, the rider slides, lies a few seconds, gets up and
  // walks about near the bike (GPS 3-4 km/h, within 60 m).
  m.tick(52, const Feel(peak: 9.0, std: 2.5, dyn: 8.0, gyro: 4.0, tilt: 90, dur: 100, jerk: 110));
  m.tick(30, const Feel(peak: 3.0, std: 1.0, dyn: 2.4, gyro: 2.5, tilt: 95, jerk: 30));
  m.tick(10, const Feel(peak: 2.0, std: 0.6, dyn: 1.3, gyro: 1.2, tilt: 90, jerk: 15));
  for (var i = 0; i < 5; i++) {
    m.tick(0, m.lying(90));
  }
  for (var i = 0; i < 70; i++) {
    m.tick(i % 10 < 6 ? 3.5 : 0, m.walking());
    if (m.northM > 0) m.northM -= 3.5 / 3.6 * 0.9; // pacing around, not going anywhere
  }
  return m;
}

Sim tipOverAtStop(int seed) {
  final m = Sim(seed);
  m.accelerateTo(30);
  m.cruise(30, 30);
  m.brakeToStop();
  m.waitIdle(20);
  // A foot slips: the bike falls onto its side and the engine cuts out.
  m.tick(0, const Feel(peak: 1.3, std: 0.25, dyn: 0.4, gyro: 2.2, tilt: 40, jerk: 10));
  m.tick(0, const Feel(peak: 2.6, std: 0.5, dyn: 1.4, gyro: 1.6, tilt: 78, dur: 30, jerk: 30));
  for (var i = 0; i < 100; i++) {
    m.tick(0, m.lying(77));
  }
  return m;
}

Sim tankBagRattle(int seed) {
  final m = Sim(seed)..baseTilt = 25;
  m.accelerateTo(50);
  for (var block = 0; block < 5; block++) {
    // About 3 min of riding with the phone loose in the tank bag, then a red light.
    for (var i = 0; i < 170; i++) {
      final hit = m._r.nextDouble() < 0.25;
      final f = Feel(
        peak: hit ? m.j(3.9, 0.7) : m.j(2.3, 0.4),
        std: m.j(0.6, 0.2),
        dyn: hit ? m.j(3.6, 0.6) : m.j(1.9, 0.4),
        gyro: m.j(2.4, 0.9),
        tilt: m.j(28, 18),
        dur: m.j(55, 25),
        jerk: m.j(40, 15),
      );
      m.tick(m.j(48, 5), f);
    }
    // Braking for the light, still rattling (a hard knock in the bag on the way).
    m.tick(45, Feel(peak: 4.6, std: 0.8, dyn: 4.2, gyro: 3.2, tilt: m.j(35, 15), dur: 70, jerk: 50));
    m.brakeToStop(decel: 2.6);
    final settle = m.j(30, 15); // where the phone came to rest in the bag
    for (var i = 0; i < 60 + m._r.nextInt(40); i++) {
      m.tick(0, Feel(peak: 1.08, std: m.j(0.05, 0.02), dyn: 0.12, gyro: m.j(0.08, 0.04), tilt: m.j(settle, 2), jerk: 2));
    }
    m.accelerateTo(48);
  }
  return m;
}

Sim phoneIntoMountAfterStart(int seed) {
  // The sensor started with the phone in a pocket (baseline 0); at the first light the rider clips
  // it into the handlebar mount (85 degrees from that baseline from then on).
  final m = Sim(seed)..baseTilt = 3;
  m.accelerateTo(35);
  m.cruise(40, 35);
  m.brakeToStop();
  m.waitIdle(12);
  m.tick(0, const Feel(peak: 1.5, std: 0.3, dyn: 0.6, gyro: 1.8, tilt: 40, jerk: 12));
  m.tick(0, const Feel(peak: 2.2, std: 0.35, dyn: 1.1, gyro: 1.2, tilt: 86, dur: 0, jerk: 25)); // clipped in
  m.baseTilt = 85;
  m.waitIdle(75);
  m.accelerateTo(40);
  m.cruise(30, 40);
  m.tick(40, const Feel(peak: 5.2, std: 1.0, dyn: 4.4, gyro: 1.6, tilt: 92, dur: 50, jerk: 60)); // pothole
  m.cruise(2, 38);
  m.brakeToStop(decel: 2.6);
  m.waitIdle(60);
  m.accelerateTo(40);
  m.cruise(20, 40);
  return m;
}

Sim pillionAndBackpack(int seed) {
  // Phone in a backpack, a pillion on board: soft but frequent body movements, kerbs and a
  // railway crossing (two sharp jolts), long wait at the closed gate.
  final m = Sim(seed)..baseTilt = 15;
  m.accelerateTo(40);
  m.cruise(60, 40, rough: 1.5);
  m.tick(25, const Feel(peak: 4.4, std: 0.9, dyn: 3.9, gyro: 2.0, tilt: 30, dur: 60, jerk: 45)); // kerb
  m.cruise(20, 30);
  m.brakeToStop(decel: 2.0);
  m.waitIdle(240); // the railway gate
  m.accelerateTo(15);
  m.tick(15, const Feel(peak: 4.9, std: 1.0, dyn: 4.2, gyro: 2.3, tilt: 32, dur: 70, jerk: 50)); // first rail
  m.tick(15, const Feel(peak: 4.6, std: 1.0, dyn: 4.0, gyro: 2.1, tilt: 30, dur: 65, jerk: 48)); // second rail
  m.cruise(5, 15);
  m.brakeToStop(decel: 2.0); // queue after the crossing
  m.waitIdle(45);
  m.accelerateTo(40);
  m.cruise(30, 40);
  return m;
}

void main() {
  const seeds = [1, 2, 3, 4, 5];
  final falseAlarmCases = <String, Sim Function(int)>{
    'potholes at 60 km/h (and one just before a red light)': potholesAt60,
    'speed breakers (one right at a toll booth)': speedBreakers,
    'rough road for 10 min with traffic stops': roughRoad10min,
    'phone dropped at a stop, picked up': phoneDropAtStop,
    'phone picked up (rolling and at a light)': phonePickUp,
    'hard brake to 0 with ABS judder': hardBrakeToZero,
    'phone loose in a tank bag, red lights': tankBagRattle,
    'phone clipped into the mount after the start': phoneIntoMountAfterStart,
    'backpack + pillion, kerb, railway crossing': pillionAndBackpack,
  };
  final realCases = <String, (Sim Function(int), String)>{
    'real crash: impact, slide, stop': (realCrashSlide, 'crash'),
    'high-side crash': (highSide, 'crash'),
    'crash, then the rider walks away': (crashThenWalksAway, 'crash'),
    'tip-over at a stop': (tipOverAtStop, 'rider-down'),
  };

  group('no automatic SOS while riding normally', () {
    for (final e in falseAlarmCases.entries) {
      test(e.key, () {
        for (final seed in seeds) {
          final o = play(e.value(seed));
          expect(o.sos, 0, reason: '${e.key} (seed $seed): $o');
          expect(o.alarms, isEmpty, reason: '${e.key} (seed $seed): $o');
        }
      });
    }
  });

  group('real crashes and a tip-over still raise the SOS', () {
    for (final e in realCases.entries) {
      test(e.key, () {
        for (final seed in seeds) {
          final o = play(e.value.$1(seed));
          expect(o.alarms, [e.value.$2], reason: '${e.key} (seed $seed): $o');
          expect(o.sos, 1, reason: '${e.key} (seed $seed): $o');
        }
      });
    }
  });

  group('alarm countdown', () {
    test('riding away (light turns green) cancels a running countdown; sliding to a stop does not', () {
      final run = RideOnRun();
      var t = t0;
      TrackPoint p(double v) => TrackPoint(ts: t += 1000, lat: lat0, lng: lng0, speedKmh: v, accuracyM: 6);
      // A sliding bike: 80, 55, 30, 10 km/h is never "riding on".
      expect(<double>[80, 55, 30, 10].map((v) => run.add(p(v))).any((r) => r), isFalse);
      // Setting off: 12, 20, 26, 30, 32 km/h.
      final starts = <double>[12, 20, 26, 30, 32, 33].map((v) => run.add(p(v))).toList();
      expect(starts.last, isTrue);
      // A single fast fix (GPS jump) is not enough; nor are rough fixes.
      final r2 = RideOnRun();
      expect(r2.add(p(40)), isFalse);
      expect(r2.add(TrackPoint(ts: t += 1000, lat: lat0, lng: lng0, speedKmh: 40, accuracyM: 120)), isFalse);
      expect(r2.add(p(0)), isFalse);
    });

    test('ridingNormally needs a fresh, accurate fix at riding speed', () {
      final f = TrackPoint(ts: t0, lat: lat0, lng: lng0, speedKmh: 40, accuracyM: 8);
      expect(ridingNormally(f, nowMs: t0 + 5000), isTrue);
      expect(ridingNormally(f, nowMs: t0 + 60000), isFalse, reason: 'a crashed phone keeps its last speed');
      expect(ridingNormally(TrackPoint(ts: t0, lat: lat0, lng: lng0, speedKmh: 40, accuracyM: 80), nowMs: t0), isFalse);
      expect(ridingNormally(TrackPoint(ts: t0, lat: lat0, lng: lng0, speedKmh: 8, accuracyM: 5), nowMs: t0), isFalse);
    });

    test('the countdown is 30 s', () {
      expect(SafetyConstants.crashCountdown, const Duration(seconds: 30));
    });
  });
}
