import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/tracking/speed_estimator.dart';

/// Metres per degree of latitude (for synthetic tracks heading north).
const double _mPerDegLat = 111195.0;

/// Deterministic Gaussian noise.
class _Noise {
  _Noise(int seed) : _r = math.Random(seed);
  final math.Random _r;
  double next() {
    final u = 1 - _r.nextDouble(), v = _r.nextDouble();
    return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
  }
}

void main() {
  group('SpeedEstimator', () {
    test('steady 86 km/h with noisy Doppler reads 85-87 (no clamp, no truncation)', () {
      final e = SpeedEstimator();
      final n = _Noise(3);
      var lat = 12.0;
      final shown = <int>[];
      var rawMin = 999.0, rawMax = 0.0;
      for (var i = 0; i < 180; i++) {
        const v = 86 / 3.6;
        lat += v / _mPerDegLat;
        final doppler = v + n.next() * 0.3; // ~1.1 km/h noise, raw readings spread ~82-90
        rawMin = math.min(rawMin, doppler * 3.6);
        rawMax = math.max(rawMax, doppler * 3.6);
        final r = e.update(SpeedFix(tMs: i * 1000, lat: lat, lng: 77, dopplerMps: doppler, speedAccuracyMps: 0.8, accuracyM: 5));
        if (i >= 10) shown.add(r.kmh.round());
      }
      expect(rawMax - rawMin, greaterThan(5.0)); // the input really is noisy
      for (final s in shown) {
        expect(s, inInclusiveRange(85, 87));
      }
      // The readout must be able to go above a limit of 80 (the owner's report).
      expect(shown.where((s) => s > 80).length, shown.length);
    });

    test('accelerating 60 -> 90 km/h in 5 s: tracks within 2 s, settles at 90', () {
      final e = SpeedEstimator();
      final n = _Noise(5);
      double truth(num t) => t < 10 ? 60.0 : (t < 15 ? 60 + (t - 10) * 6.0 : 90.0);
      var lat = 12.0;
      for (var i = 0; i < 30; i++) {
        final v = truth(i) / 3.6;
        lat += v / _mPerDegLat;
        final r = e.update(SpeedFix(tMs: i * 1000, lat: lat, lng: 77, dopplerMps: v + n.next() * 0.2, speedAccuracyMps: 0.5, accuracyM: 5));
        if (i >= 11 && i <= 17) {
          // Never further behind than where the bike was 2 s ago.
          expect(r.kmh, greaterThanOrEqualTo(truth(i - 2) - 1.0), reason: 't=$i shown ${r.kmh}');
          expect(r.kmh, lessThanOrEqualTo(93.5), reason: 't=$i overshoot ${r.kmh}');
        }
        if (i >= 20) expect(r.kmh, closeTo(90, 2.0), reason: 't=$i');
      }
    });

    test('braking 80 -> 0 reads 0 when stopped, no jitter while parked', () {
      final e = SpeedEstimator();
      final n = _Noise(9);
      for (var i = 0; i < 40; i++) {
        final kmh = i < 10 ? 80.0 : math.max(0.0, 80 - (i - 10) * 15.0);
        // Parked phones report small non-zero Doppler speeds (0-0.6 m/s).
        final doppler = kmh > 0 ? kmh / 3.6 : (n.next().abs() * 0.3);
        final r = e.update(SpeedFix(tMs: i * 1000, lat: 12, lng: 77, dopplerMps: doppler, speedAccuracyMps: 0.5, accuracyM: 6));
        if (i >= 18) expect(r.kmh, 0.0, reason: 't=$i shown ${r.kmh}');
      }
      expect(e.kmh, 0.0);
    });

    test('no Doppler: falls back to distance / time over the window', () {
      final e = SpeedEstimator();
      var lat = 12.0;
      SpeedEstimate? r;
      for (var i = 0; i < 20; i++) {
        lat += (72 / 3.6) / _mPerDegLat;
        r = e.update(SpeedFix(tMs: i * 1000, lat: lat, lng: 77, accuracyM: 4));
      }
      expect(r!.source, SpeedSource.derived);
      expect(r.kmh, closeTo(72, 2.0));
    });

    test('a placeholder 0 (no speed accuracy) while the positions move is not taken as a stop', () {
      final e = SpeedEstimator();
      var lat = 12.0;
      for (var i = 0; i < 15; i++) {
        lat += (50 / 3.6) / _mPerDegLat;
        e.update(SpeedFix(tMs: i * 1000, lat: lat, lng: 77, dopplerMps: 0, accuracyM: 4));
      }
      expect(e.kmh, closeTo(50, 2.0));
      // A real stop (positions still) with the same placeholder reads 0.
      for (var i = 15; i < 25; i++) {
        e.update(SpeedFix(tMs: i * 1000, lat: lat, lng: 77, dopplerMps: 0, accuracyM: 4));
      }
      expect(e.kmh, 0.0);
    });

    test('no Doppler with poor positions: holds the speed instead of guessing', () {
      final e = SpeedEstimator();
      var lat = 12.0;
      for (var i = 0; i < 10; i++) {
        lat += (60 / 3.6) / _mPerDegLat;
        e.update(SpeedFix(tMs: i * 1000, lat: lat, lng: 77, dopplerMps: 60 / 3.6, speedAccuracyMps: 0.5, accuracyM: 5));
      }
      // Then fixes without Doppler that jump around by tens of metres (accuracy 60 m).
      final n = _Noise(1);
      for (var i = 10; i < 14; i++) {
        lat += (60 / 3.6) / _mPerDegLat;
        final r = e.update(SpeedFix(tMs: i * 1000, lat: lat + n.next() * 40 / _mPerDegLat, lng: 77, accuracyM: 60));
        expect(r.measuredKmh, isNull);
        expect(r.kmh, closeTo(60, 1.5));
      }
    });

    test('rejects outliers: Doppler spikes and impossible jumps, keeps genuine 250 km/h', () {
      final e = SpeedEstimator();
      var lat = 12.0;
      for (var i = 0; i < 30; i++) {
        const v = 86 / 3.6;
        lat += v / _mPerDegLat;
        // A 400 km/h glitch, and a single 0 / 150 km/h reading (1 s apart: > 1.2 g).
        final doppler = switch (i) { 12 => 400 / 3.6, 18 => 0.0, 24 => 150 / 3.6, _ => v };
        final r = e.update(SpeedFix(tMs: i * 1000, lat: lat, lng: 77, dopplerMps: doppler, speedAccuracyMps: 0.5, accuracyM: 5));
        if (i == 12 || i == 18 || i == 24) expect(r.rejected, isTrue, reason: 't=$i');
        if (i >= 5) expect(r.kmh, closeTo(86, 1.0), reason: 't=$i shown ${r.kmh}');
      }

      // A superbike at a genuine 250 km/h (reached smoothly) is not rejected.
      final fast = SpeedEstimator();
      for (var i = 0; i < 60; i++) {
        final kmh = math.min(250.0, 100 + i * 5.0); // 1.4 m/s^2
        final r = fast.update(SpeedFix(tMs: i * 1000, lat: 12, lng: 77, dopplerMps: kmh / 3.6, speedAccuracyMps: 0.5));
        expect(r.rejected, isFalse, reason: 't=$i');
      }
      expect(fast.kmh, closeTo(250, 1.0));
    });

    test('a sudden stop (a fall: faster than any brake) reads 0 within 2 s', () {
      final e = SpeedEstimator();
      for (var i = 0; i < 10; i++) {
        e.update(SpeedFix(tMs: i * 1000, lat: 12, lng: 77, dopplerMps: 80 / 3.6, speedAccuracyMps: 0.5));
      }
      e.update(SpeedFix(tMs: 10000, lat: 12, lng: 77, dopplerMps: 0.2, speedAccuracyMps: 0.5));
      final r = e.update(SpeedFix(tMs: 11000, lat: 12, lng: 77, dopplerMps: 0.1, speedAccuracyMps: 0.5));
      expect(r.kmh, 0.0);
    });

    test('a consistent new speed after a GPS outage is accepted (re-seed)', () {
      final e = SpeedEstimator();
      for (var i = 0; i < 10; i++) {
        e.update(SpeedFix(tMs: i * 1000, lat: 12, lng: 77, dopplerMps: 20 / 3.6, speedAccuracyMps: 0.5));
      }
      // Wrongly locked low (e.g. a bad seed): the following agreeing readings win after ~2 s.
      for (var i = 10; i < 16; i++) {
        e.update(SpeedFix(tMs: i * 1000, lat: 12, lng: 77, dopplerMps: 110 / 3.6, speedAccuracyMps: 0.5));
      }
      expect(e.kmh, closeTo(110, 2.0));
    });

    test('on a curve: Doppler is used, the shorter chord distance is not', () {
      final e = SpeedEstimator();
      // A 60 m radius bend at 80 km/h: 22.2 m/s, ~21 deg per second; the chord between fixes 2-4 s
      // apart is noticeably shorter than the arc ridden.
      const radius = 60.0, v = 80 / 3.6;
      SpeedEstimate? r;
      for (var i = 0; i < 12; i++) {
        final ang = v * i / radius;
        final north = radius * math.sin(ang), east = radius * (1 - math.cos(ang));
        final lat = 12 + north / _mPerDegLat;
        final lng = 77 + east / (_mPerDegLat * math.cos(12 * math.pi / 180));
        r = e.update(SpeedFix(tMs: i * 1000, lat: lat, lng: lng, dopplerMps: v, speedAccuracyMps: 0.4, accuracyM: 4));
      }
      expect(r!.source, SpeedSource.doppler);
      expect(r.kmh, closeTo(80, 0.5));
    });

    test('ignores repeated or out-of-order fixes and restarts after a long gap', () {
      final e = SpeedEstimator();
      for (var i = 0; i < 10; i++) {
        e.update(SpeedFix(tMs: i * 1000, lat: 12, lng: 77, dopplerMps: 50 / 3.6, speedAccuracyMps: 0.5));
      }
      final r = e.update(SpeedFix(tMs: 5000, lat: 12, lng: 77, dopplerMps: 0, speedAccuracyMps: 0.5)); // cached old fix
      expect(r.kmh, closeTo(50, 0.5));
      // 30 s later (tunnel) at a different speed: taken as is.
      final after = e.update(SpeedFix(tMs: 40000, lat: 12, lng: 77, dopplerMps: 70 / 3.6, speedAccuracyMps: 0.5));
      expect(after.kmh, closeTo(70, 0.5));
    });
  });
}
