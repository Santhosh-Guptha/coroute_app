// 3.55 alert latency review (docs/features_355/alert_latency.md). Pure Dart.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/safety/overspeed_gate.dart';
import 'package:coroute_app/domain/safety/speed_limit_advisor.dart';
import 'package:coroute_app/domain/tracking/location_cadence.dart';
import 'package:coroute_app/domain/tracking/speed_estimator.dart';

void main() {
  group('overspeed gate', () {
    test('warns on the second fix over limit + 2 (about 1 s), at once at +10', () {
      final g = OverspeedGate();
      expect(g.update(speedKmh: 81, limitKmh: 80, nowMs: 0), OverspeedStep.none, reason: 'within +2');
      expect(g.update(speedKmh: 83, limitKmh: 80, nowMs: 1000), OverspeedStep.none, reason: 'first fix over: hold');
      expect(g.update(speedKmh: 83, limitKmh: 80, nowMs: 2000), OverspeedStep.warn);
      final h = OverspeedGate();
      expect(h.update(speedKmh: 91, limitKmh: 80, nowMs: 0), OverspeedStep.warn);
    });

    test('a single GPS spike never warns', () {
      final g = OverspeedGate();
      expect(g.update(speedKmh: 90, limitKmh: 80, nowMs: 0), OverspeedStep.warn, reason: '+10 is immediate by design');
      final h = OverspeedGate();
      expect(h.update(speedKmh: 85, limitKmh: 80, nowMs: 0), OverspeedStep.none);
      expect(h.update(speedKmh: 78, limitKmh: 80, nowMs: 1000), OverspeedStep.none);
      expect(h.update(speedKmh: 85, limitKmh: 80, nowMs: 2000), OverspeedStep.none);
    });

    test('hovering at the limit speaks once, not every few seconds; reminder every 25 s while over', () {
      final g = OverspeedGate();
      var warns = 0;
      final r = math.Random(3);
      for (var s = 0; s < 120; s++) {
        final v = 80 + (r.nextDouble() * 6 - 2.5); // 77.5 .. 83.5
        if (g.update(speedKmh: v, limitKmh: 80, nowMs: s * 1000) == OverspeedStep.warn) warns++;
      }
      expect(warns, lessThanOrEqualTo(120 ~/ 25 + 1));
      // Steadily over: first warning, then reminders 25 s apart.
      final h = OverspeedGate();
      final at = <int>[];
      for (var s = 0; s <= 60; s++) {
        if (h.update(speedKmh: 90, limitKmh: 80, nowMs: s * 1000) == OverspeedStep.warn) at.add(s);
      }
      expect(at, [0, 25, 50]);
    });

    test('re-arms only after 5 s under limit - 3; the card hides at the limit', () {
      final g = OverspeedGate();
      g.update(speedKmh: 90, limitKmh: 80, nowMs: 0);
      expect(g.update(speedKmh: 79, limitKmh: 80, nowMs: 1000), OverspeedStep.hide);
      expect(g.active, isTrue);
      expect(g.update(speedKmh: 84, limitKmh: 80, nowMs: 3000), OverspeedStep.show, reason: 'no new voice within the episode');
      for (var s = 4; s < 9; s++) {
        g.update(speedKmh: 75, limitKmh: 80, nowMs: s * 1000);
      }
      expect(g.update(speedKmh: 75, limitKmh: 80, nowMs: 9000), OverspeedStep.clear);
      expect(g.active, isFalse);
      g.update(speedKmh: 84, limitKmh: 80, nowMs: 10000);
      expect(g.update(speedKmh: 84, limitKmh: 80, nowMs: 11000), OverspeedStep.warn, reason: 'a new episode speaks again');
    });

    test('a new limit is judged at once; no limit clears', () {
      final g = OverspeedGate();
      g.update(speedKmh: 70, limitKmh: 80, nowMs: 0);
      expect(g.update(speedKmh: 70, limitKmh: 50, nowMs: 1000), OverspeedStep.warn, reason: '+20 over the new limit');
      expect(g.update(speedKmh: 70, limitKmh: 0, nowMs: 2000), OverspeedStep.clear);
    });
  });

  test('road / school zone limit warns after 2 s (was 8 s)', () {
    const ctx = LimitContext(limitKmh: 25, reason: LimitReason.school, roadLimitKmh: null);
    final a = SpeedLimitAdvisor();
    expect(a.onSpeed(context: ctx, speedKmh: 45, nowMs: 0), isNull);
    expect(a.onSpeed(context: ctx, speedKmh: 45, nowMs: 1000), isNull);
    expect(a.onSpeed(context: ctx, speedKmh: 45, nowMs: 2000), isNotNull);
  });

  test('riding keeps 1 Hz GPS fixes with no distance filter, also on the battery saver', () {
    for (final low in [false, true]) {
      for (final b in [SpeedBand.city, SpeedBand.road, SpeedBand.highway]) {
        final p = LocationCadence.plan(b, idle: false, lowBattery: low);
        expect(p.intervalMs, lessThanOrEqualTo(1000), reason: '$b low=$low');
        expect(p.distanceFilterM, 0);
      }
    }
  });

  test('speed estimator: a gradual speed-up crosses limit + 2 within 2 s of the truth (noisy Doppler, p90)', () {
    for (final noise in [0.5, 1.0]) {
      final lags = <int>[];
      for (var seed = 0; seed < 30; seed++) {
        final r = math.Random(seed);
        double g() => math.sqrt(-2 * math.log(r.nextDouble() + 1e-12)) * math.cos(2 * math.pi * r.nextDouble());
        final e = SpeedEstimator();
        int? truth, est;
        for (var i = 0; i < 240; i++) {
          final v = i <= 120 ? 70 / 3.6 : math.min(95 / 3.6, 70 / 3.6 + 0.3 * (i - 120));
          final k = e.update(SpeedFix(tMs: i * 1000, lat: 12.97, lng: 77.59, dopplerMps: math.max(0, v + noise * g()), speedAccuracyMps: noise + 0.2, accuracyM: 5)).kmh;
          if (truth == null && v * 3.6 >= 82) truth = i;
          if (est == null && i > 120 && k >= 82) est = i;
        }
        lags.add((est ?? 999) - (truth ?? 0));
      }
      lags.sort();
      expect(lags[(lags.length * 0.9).floor() - 1], lessThanOrEqualTo(2), reason: 'noise $noise m/s: $lags');
    }
  });
}
