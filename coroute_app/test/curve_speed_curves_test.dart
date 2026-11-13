// Round 7: curve prediction (lib/domain/road/curve_predictor.dart). Pure Dart:
//   DART=/opt/dartpkg/bin/dart tool/pure_dart_test/run.sh test/curve_speed_curves_test.dart
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/road/curve_predictor.dart';

const double lat0 = 12.0, lng0 = 77.0;
(double, double) ll(double x, double y) => (lat0 + y / 110540.0, lng0 + x / (111320.0 * math.cos(lat0 * math.pi / 180)));

/// A path builder in metres: straight runs and arcs (positive turn = right).
class Path {
  double x = 0, y = 0, h = 0; // heading in degrees, 0 = north
  final List<(double, double)> pts = [ll(0, 0)];
  double length = 0;

  void straight(double m, {double step = 25}) {
    for (var d = step; d <= m + 1e-6; d += step) {
      x += step * math.sin(h * math.pi / 180);
      y += step * math.cos(h * math.pi / 180);
      pts.add(ll(x, y));
    }
    length += m;
  }

  void arc(double radius, double turnDeg, {double stepDeg = 10}) {
    final n = (turnDeg.abs() / stepDeg).round();
    final dTheta = turnDeg / n;
    final chord = 2 * radius * math.sin(dTheta.abs() * math.pi / 360);
    for (var i = 0; i < n; i++) {
      h += dTheta / 2;
      x += chord * math.sin(h * math.pi / 180);
      y += chord * math.cos(h * math.pi / 180);
      h += dTheta / 2;
      pts.add(ll(x, y));
    }
    length += radius * turnDeg.abs() * math.pi / 180;
  }
}

void main() {
  group('curvature and classes', () {
    test('a straight road has no bends', () {
      final p = Path()..straight(2000);
      expect(CurveAnalyzer.analyze(p.pts), isEmpty);
    });

    test('radius and direction of plain arcs (within 25%)', () {
      for (final (r, turn, cls) in [
        (150.0, 60.0, CurveClass.gentle),
        (80.0, -70.0, CurveClass.medium),
        (35.0, 90.0, CurveClass.sharp),
        (55.0, -100.0, CurveClass.sharp),
      ]) {
        final p = Path()
          ..straight(300)
          ..arc(r, turn)
          ..straight(300);
        final c = CurveAnalyzer.analyze(p.pts);
        expect(c.length, 1, reason: 'r $r');
        expect(c.first.cls, cls, reason: 'r $r got ${c.first}');
        expect(c.first.radiusM, inInclusiveRange(r * 0.75, r * 1.25), reason: 'r $r got ${c.first}');
        expect(c.first.right, turn > 0);
        expect(c.first.turnDeg.abs(), inInclusiveRange(turn.abs() * 0.85, turn.abs() * 1.15));
        expect(c.first.startM, inInclusiveRange(260, 320));
        expect(c.first.junction, isFalse);
      }
    });

    test('a hairpin (radius 12 m, 180 degrees) is a hairpin, left or right', () {
      for (final turn in [180.0, -180.0]) {
        final p = Path()
          ..straight(200)
          ..arc(12, turn, stepDeg: 30)
          ..straight(200);
        final c = CurveAnalyzer.analyze(p.pts);
        expect(c.length, 1);
        expect(c.first.cls, CurveClass.hairpin, reason: '${c.first}');
        expect(c.first.radiusM, lessThan(30));
        expect(c.first.right, turn > 0);
      }
    });

    test('ghat: five stacked hairpins are five bends, alternating sides, one series', () {
      final p = Path()..straight(150);
      for (var i = 0; i < 5; i++) {
        p
          ..arc(14, i.isEven ? 175 : -175, stepDeg: 25)
          ..straight(90);
      }
      final c = CurveAnalyzer.analyze(p.pts);
      expect(c.length, 5);
      expect(c.every((x) => x.cls == CurveClass.hairpin), isTrue, reason: '$c');
      expect([for (final x in c) x.right], [true, false, true, false, true]);
      final s = CurveAnalyzer.seriesFrom(c, 0)!;
      expect(s.lastIndex, 4);
      expect(s.lengthM, inInclusiveRange(550, 750));
      expect(CurveAnalyzer.seriesFrom(c, 3), isNull, reason: 'two bends are not a series');
    });

    test('noisy GPS on a straight road makes no sharp bend; a real bend in noise is still found', () {
      final rnd = math.Random(7);
      List<(double, double)> noisy(List<(double, double)> pts, double sigma) => [
            for (final q in pts)
              (q.$1 + (rnd.nextDouble() - 0.5) * 2 * sigma / 110540.0, q.$2 + (rnd.nextDouble() - 0.5) * 2 * sigma / 108900.0)
          ];
      final straight = Path()..straight(3000, step: 10);
      final c = CurveAnalyzer.analyze(noisy(straight.pts, 2.0));
      expect(c.where((x) => x.cls.index >= CurveClass.medium.index), isEmpty, reason: '$c');
      final bend = Path()
        ..straight(400, step: 10)
        ..arc(45, 90, stepDeg: 12)
        ..straight(400, step: 10);
      final d = CurveAnalyzer.analyze(noisy(bend.pts, 2.0)).where((x) => x.cls.index >= CurveClass.medium.index).toList();
      expect(d.length, 1, reason: '$d');
      expect(d.first.right, isTrue);
      expect(d.first.radiusM, inInclusiveRange(28, 75));
      expect(d.first.startM, inInclusiveRange(340, 430));
    });

    test('a single 90 degree corner between long straight legs is a junction corner', () {
      final p = Path()..straight(300, step: 100);
      p.h = 90;
      p.straight(300, step: 100);
      final c = CurveAnalyzer.analyze(p.pts);
      expect(c.length, 1);
      expect(c.first.junction, isTrue);
    });

    test('sparse and dense versions of the same bend agree (resampling)', () {
      final a = Path()
        ..straight(200, step: 100)
        ..arc(60, 80, stepDeg: 20)
        ..straight(200, step: 100);
      final b = Path()
        ..straight(200, step: 5)
        ..arc(60, 80, stepDeg: 4)
        ..straight(200, step: 5);
      final ca = CurveAnalyzer.analyze(a.pts).single, cb = CurveAnalyzer.analyze(b.pts).single;
      expect(ca.cls, cb.cls);
      expect((ca.radiusM - cb.radiusM).abs(), lessThan(15));
    });

    test('learned bend: riders brake hard there, the class goes up one step and the advisory down', () {
      final p = Path()
        ..straight(300)
        ..arc(80, 70)
        ..straight(300);
      final plain = CurveAnalyzer.analyze(p.pts).single;
      final learned = CurveAnalyzer.analyze(p.pts, hardBrakeSpots: [(plain.apexLat + 0.0003, plain.apexLng)]).single;
      expect(plain.cls, CurveClass.medium);
      expect(learned.cls, CurveClass.sharp);
      expect(learned.learned, isTrue);
      expect(CurveAnalyzer.advisoryKmh(learned), lessThan(CurveAnalyzer.advisoryKmh(plain)));
      final far = CurveAnalyzer.analyze(p.pts, hardBrakeSpots: [(plain.apexLat + 0.01, plain.apexLng)]).single;
      expect(far.learned, isFalse);
    });
  });

  group('advisory speed', () {
    RoadCurve c(double r) => RoadCurve(startM: 0, apexM: 10, endM: 20, radiusM: r, turnDeg: 90, cls: CurveClass.sharp, apexLat: 12, apexLng: 77);

    test('sqrt(a r) with 0.28 g, rounded down to 5, at least 15', () {
      expect(CurveAnalyzer.lateralG(CurveConditions.normal), 0.28);
      expect(CurveAnalyzer.advisoryKmh(c(30)), 30); // 32.7
      expect(CurveAnalyzer.advisoryKmh(c(60)), 45); // 46.2
      expect(CurveAnalyzer.advisoryKmh(c(100)), 55); // 59.6
      expect(CurveAnalyzer.advisoryKmh(c(200)), 80); // 84.4
      expect(CurveAnalyzer.advisoryKmh(c(3)), 15);
    });

    test('lower in the dark, in rain and for a cautious rider; never above the limit', () {
      final n = CurveAnalyzer.advisoryKmh(c(60));
      final dark = CurveAnalyzer.advisoryKmh(c(60), conditions: const CurveConditions(dark: true));
      final rain = CurveAnalyzer.advisoryKmh(c(60), conditions: const CurveConditions(rain: true));
      final careful = CurveAnalyzer.advisoryKmh(c(60), conditions: const CurveConditions(dark: true, rain: true, cautious: true));
      expect(dark, lessThan(n));
      expect(rain, lessThanOrEqualTo(dark));
      expect(careful, lessThanOrEqualTo(rain));
      expect(CurveAnalyzer.lateralG(const CurveConditions(dark: true, rain: true, cautious: true)), closeTo(0.17, 1e-9));
      expect(CurveAnalyzer.advisoryKmh(c(200), limitKmh: 60), 60);
      expect(CurveAnalyzer.advisoryKmh(c(30), limitKmh: 60), 30);
    });
  });

  group('warning timing and the no-nag rule', () {
    late Path p;
    late List<RoadCurve> curves;
    setUp(() {
      p = Path()
        ..straight(1000)
        ..arc(35, 90)
        ..straight(1000);
      curves = CurveAnalyzer.analyze(p.pts);
    });

    test('lead distance: 7 s of riding, at least 80 m, at most 400 m', () {
      expect(CurveWarner.leadFor(20), 80);
      expect(CurveWarner.leadFor(72), closeTo(140, 0.1));
      expect(CurveWarner.leadFor(100), closeTo(194.4, 0.1));
      expect(CurveWarner.leadFor(250), 400);
    });

    test('warned once, at the lead distance, with side, class and advisory', () {
      final w = CurveWarner();
      final start = curves.single.startM;
      CurveWarning? got;
      double? at;
      var t = 0;
      for (var along = 0.0; along < start + 100; along += 20) {
        t += 1000;
        final r = w.onFix(curves: curves, alongM: along, speedKmh: 72, nowMs: t);
        if (r != null) {
          expect(got, isNull, reason: 'one warning per bend');
          got = r;
          at = start - along;
        }
      }
      expect(got, isNotNull);
      expect(at!, inInclusiveRange(118, 141));
      expect(got!.curve.cls, CurveClass.sharp);
      expect(got.advisoryKmh, inInclusiveRange(30, 40));
      expect(got.title, startsWith('Sharp right bend in 1'));
      expect(got.speech, contains('Slow to'));
      expect(got.isSeries, isFalse);
    });

    test('no nagging: at or near the advisory speed nothing is said; quiet on the straight', () {
      final w = CurveWarner();
      final start = curves.single.startM;
      final adv = CurveAnalyzer.advisoryKmh(curves.single);
      for (var along = 0.0; along < start + 200; along += 10) {
        expect(w.onFix(curves: curves, alongM: along, speedKmh: adv + 4.0, nowMs: along.round() * 100), isNull);
      }
      expect(CurveWarner.tooFast(adv + 5.0, adv), isFalse);
      expect(CurveWarner.tooFast(adv + 6.0, adv), isTrue);
      expect(CurveWarner.tooFast(24, 15), isFalse, reason: 'below 25 km/h never');
      final fast = CurveWarner();
      for (var along = 0.0; along < start - 420; along += 10) {
        expect(fast.onFix(curves: curves, alongM: along, speedKmh: 110, nowMs: along.round() * 100), isNull);
      }
    });

    test('a rider who speeds up inside the lead distance is still warned; too late (15 m) is not', () {
      final w = CurveWarner();
      final start = curves.single.startM;
      expect(w.onFix(curves: curves, alongM: start - 100, speedKmh: 35, nowMs: 1000), isNull);
      expect(w.onFix(curves: curves, alongM: start - 80, speedKmh: 60, nowMs: 2000), isNotNull);
      final late = CurveWarner();
      expect(late.onFix(curves: curves, alongM: start - 10, speedKmh: 80, nowMs: 1000), isNull);
    });

    test('the same bend on a rebuilt look-ahead line (free riding) is not warned twice', () {
      final w = CurveWarner();
      final start = curves.single.startM;
      expect(w.onFix(curves: curves, alongM: start - 120, speedKmh: 70, nowMs: 1000), isNotNull);
      // The line now starts 60 m further on: the bend has other along values but the same apex.
      final shifted = [for (final c in curves) c.shifted(-(start - 60))];
      expect(w.onFix(curves: shifted, alongM: 0, speedKmh: 70, nowMs: 20000), isNull);
    });

    test('junction corners are left to the navigation voice on a route, warned in free riding', () {
      final j = Path()..straight(400, step: 100);
      j.h = 90;
      j.straight(400, step: 100);
      final c = CurveAnalyzer.analyze(j.pts);
      expect(CurveWarner().onFix(curves: c, alongM: 300, speedKmh: 60, nowMs: 1), isNull);
      expect(CurveWarner().onFix(curves: c, alongM: 300, speedKmh: 60, nowMs: 1, includeJunctions: true), isNotNull);
    });

    test('switched off: nothing', () {
      expect(CurveWarner().onFix(curves: curves, alongM: curves.single.startM - 100, speedKmh: 90, nowMs: 1, enabled: false), isNull);
    });

    test('a ghat is one "series of bends" warning; the hairpins inside do not each speak', () {
      final g = Path()..straight(500);
      for (var i = 0; i < 6; i++) {
        g
          ..arc(15, i.isEven ? 170 : -170, stepDeg: 25)
          ..straight(100);
      }
      final c = CurveAnalyzer.analyze(g.pts);
      final w = CurveWarner();
      final warnings = <CurveWarning>[];
      var t = 0;
      for (var along = 0.0; along < g.length; along += 8) {
        t += 600;
        final r = w.onFix(curves: c, alongM: along, speedKmh: 45, nowMs: t);
        if (r != null) warnings.add(r);
      }
      expect(warnings.length, 1, reason: '$warnings');
      expect(warnings.single.isSeries, isTrue);
      expect(warnings.single.seriesCount, 6);
      expect(warnings.single.title, startsWith('Series of bends for'));
      expect(warnings.single.advisoryKmh, lessThanOrEqualTo(25));
    });

    test('dark lowers the advisory, so the same speed warns only at night', () {
      final q = Path()
        ..straight(600)
        ..arc(90, 80)
        ..straight(300);
      final c = CurveAnalyzer.analyze(q.pts);
      final adv = CurveAnalyzer.advisoryKmh(c.single);
      final speed = adv + 5.0; // inside the margin by day
      expect(CurveWarner().onFix(curves: c, alongM: c.single.startM - 90, speedKmh: speed, nowMs: 1), isNull);
      expect(CurveWarner().onFix(curves: c, alongM: c.single.startM - 90, speedKmh: speed, nowMs: 1, conditions: const CurveConditions(dark: true)), isNotNull);
    });
  });
}
