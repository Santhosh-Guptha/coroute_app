import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/tracking/nav_motion.dart';

void main() {
  group('bearing interpolation', () {
    test('normalizes into [0, 360)', () {
      expect(NavMath.normalizeDeg(-10), closeTo(350, 1e-9));
      expect(NavMath.normalizeDeg(360), closeTo(0, 1e-9));
      expect(NavMath.normalizeDeg(725), closeTo(5, 1e-9));
      expect(NavMath.normalizeDeg(double.nan), 0);
    });

    test('shortest delta never spins the long way round', () {
      expect(NavMath.shortestDelta(359, 1), closeTo(2, 1e-9));
      expect(NavMath.shortestDelta(1, 359), closeTo(-2, 1e-9));
      expect(NavMath.shortestDelta(90, 270), closeTo(180, 1e-9));
      expect(NavMath.shortestDelta(10, 10), closeTo(0, 1e-9));
    });

    test('lerpAngle crosses north through 0, not through 180', () {
      expect(NavMath.lerpAngle(350, 10, 0.5), closeTo(0, 1e-9));
      expect(NavMath.lerpAngle(10, 350, 0.25), closeTo(5, 1e-9));
      expect(NavMath.lerpAngle(350, 10, 0), closeTo(350, 1e-9));
      expect(NavMath.lerpAngle(350, 10, 1), closeTo(10, 1e-9));
      // Every intermediate step stays within the 20 degree arc around north.
      for (var t = 0.0; t <= 1.0; t += 0.1) {
        final v = NavMath.lerpAngle(350, 10, t);
        expect(v >= 349.999 || v <= 10.001, isTrue, reason: 't=$t gave $v');
      }
    });

    test('smoothing alpha is frame-rate independent', () {
      // Two 1/60 s steps cover the same share as one 1/30 s step.
      final a60 = NavMath.smoothingAlpha(1 / 60, 0.3);
      final a30 = NavMath.smoothingAlpha(1 / 30, 0.3);
      expect(1 - (1 - a60) * (1 - a60), closeTo(a30, 1e-12));
      expect(NavMath.smoothingAlpha(0, 0.3), 0);
      expect(NavMath.smoothingAlpha(0.1, 0), 1);
    });

    test('heading fusion: compass when slow, GPS course when moving, with hysteresis', () {
      final f = HeadingFusion();
      expect(f.usingGps, isFalse);
      f.addCompass(350, 0);
      expect(f.bearing, closeTo(350, 1e-9));
      // Compass jitter inside the dead band is ignored.
      expect(f.addCompass(351, 50), isFalse);
      // A real turn is low-passed the short way (towards 10 through 0).
      f.addCompass(10, 100);
      final b = f.bearing!;
      expect(b > 350 || b < 10, isTrue);
      // 8 km/h: still compass (switches above 9).
      expect(f.updateSpeed(8), isFalse);
      expect(f.usingGps, isFalse);
      expect(f.addCourse(90), isFalse);
      expect(f.updateSpeed(12), isTrue);
      expect(f.usingGps, isTrue);
      expect(f.addCourse(20), isTrue);
      // 7.5 km/h is inside the hysteresis gap: stays on GPS.
      expect(f.updateSpeed(7.5), isFalse);
      expect(f.usingGps, isTrue);
      expect(f.addCompass(200, 200), isFalse);
      expect(f.updateSpeed(5), isTrue);
      expect(f.usingGps, isFalse);
    });
  });

  group('extrapolation (dead reckoning between fixes)', () {
    test('moves along the heading at the given speed', () {
      final (lat, lng) = NavMath.extrapolate(12.0, 77.0, 90, 20, 1.0);
      expect(NavMath.distanceM(12.0, 77.0, lat, lng), closeTo(20, 0.2));
      expect(NavMath.bearingDeg(12.0, 77.0, lat, lng), closeTo(90, 0.5));
      final (nLat, nLng) = NavMath.extrapolate(12.0, 77.0, 0, 10, 1.0);
      expect(nLat, greaterThan(12.0));
      expect(nLng, closeTo(77.0, 1e-9));
    });

    test('never projects more than 1.5 s ahead', () {
      final (lat, lng) = NavMath.extrapolate(12.0, 77.0, 45, 30, 10.0);
      expect(NavMath.distanceM(12.0, 77.0, lat, lng), closeTo(45, 0.5));
    });

    test('no motion for zero speed, negative time or bad heading', () {
      expect(NavMath.extrapolate(1, 2, 90, 0, 1), (1.0, 2.0));
      expect(NavMath.extrapolate(1, 2, 90, 10, -1), (1.0, 2.0));
      expect(NavMath.extrapolate(1, 2, double.nan, 10, 1), (1.0, 2.0));
    });

    test('smoother never slides backwards along the heading while moving', () {
      final s = PositionSmoother();
      s.snap(12.0, 77.0);
      // Target 5 m behind (south of) the drawn point while heading north.
      final (bLat, bLng) = NavMath.offsetMeters(12.0, 77.0, 0, -5);
      for (var i = 0; i < 30; i++) {
        s.step(targetLat: bLat, targetLng: bLng, headingDeg: 0, speedMps: 10, dtSec: 1 / 60);
        expect(s.lat!, greaterThanOrEqualTo(12.0 - 1e-12));
      }
      // Sideways error is still corrected.
      final (sLat, sLng) = NavMath.offsetMeters(12.0, 77.0, 4, -2);
      for (var i = 0; i < 120; i++) {
        s.step(targetLat: sLat, targetLng: sLng, headingDeg: 0, speedMps: 10, dtSec: 1 / 60);
      }
      final (east, _) = NavMath.deltaMeters(12.0, 77.0, s.lat!, s.lng!);
      expect(east, closeTo(4, 0.1));
    });

    test('smoother converges forward and snaps on a teleport', () {
      final s = PositionSmoother();
      s.snap(12.0, 77.0);
      final (fLat, fLng) = NavMath.offsetMeters(12.0, 77.0, 0, 10);
      for (var i = 0; i < 180; i++) {
        s.step(targetLat: fLat, targetLng: fLng, headingDeg: 0, speedMps: 10, dtSec: 1 / 60);
      }
      expect(NavMath.distanceM(s.lat!, s.lng!, fLat, fLng), lessThan(0.05));
      final moved = s.step(targetLat: 13.0, targetLng: 77.0, headingDeg: 0, speedMps: 10, dtSec: 1 / 60);
      expect(moved, greaterThan(250));
      expect(s.lat, 13.0);
    });
  });

  group('camera offset', () {
    test('cameraCenterFor puts the rider at the requested screen offset', () {
      for (final rot in [0.0, -37.0, -90.0, -200.0, 123.0]) {
        final (cLat, cLng) = NavMath.cameraCenterFor(
            lat: 17.385, lng: 78.4867, zoom: 16, rotationDeg: rot, screenOffsetX: 30, screenOffsetY: 180);
        final (x, y) = NavMath.screenOffsetOf(
            lat: 17.385, lng: 78.4867, centerLat: cLat, centerLng: cLng, zoom: 16, rotationDeg: rot);
        expect(x, closeTo(30, 0.01), reason: 'rotation $rot');
        expect(y, closeTo(180, 0.01), reason: 'rotation $rot');
      }
    });

    test('course-up rotation (-heading) puts the direction of travel at the top', () {
      const heading = 63.0;
      final (aLat, aLng) = NavMath.extrapolate(17.385, 78.4867, heading, 50, 1.0);
      final (x, y) = NavMath.screenOffsetOf(
          lat: aLat, lng: aLng, centerLat: 17.385, centerLng: 78.4867, zoom: 16, rotationDeg: -heading);
      expect(x.abs(), lessThan(0.5));
      expect(y, lessThan(0));
    });

    test('project / unproject round trip', () {
      final (x, y) = NavMath.project(-33.86, 151.21, 15.3);
      final (lat, lng) = NavMath.unproject(x, y, 15.3);
      expect(lat, closeTo(-33.86, 1e-9));
      expect(lng, closeTo(151.21, 1e-9));
    });
  });

  group('speed bands with hysteresis', () {
    test('BandSelector needs the margin and the dwell time', () {
      final b = BandSelector(thresholds: const [10, 40], marginUp: 1, marginDown: 4, upDwellMs: 2000, downDwellMs: 6000);
      expect(b.update(10.5, 0), 0); // below 10 + 1
      expect(b.update(12, 0), 0); // pending
      expect(b.update(12, 1999), 0);
      expect(b.update(12, 2000), 1);
      expect(b.update(7, 3000), 1); // inside the gap (10 - 4 = 6)
      expect(b.update(5, 4000), 1); // pending down
      expect(b.update(5, 9999), 1);
      expect(b.update(5, 10000), 0);
    });

    test('a dip back above the boundary restarts the dwell', () {
      final b = BandSelector(thresholds: const [10], marginUp: 1, upDwellMs: 2000);
      b.update(12, 0);
      b.update(10, 1000); // back below the margin: pending cleared
      b.update(12, 1500);
      expect(b.update(12, 3000), 0);
      expect(b.update(12, 3500), 1);
    });

    test('jumps several bands at once when far above', () {
      final b = BandSelector(thresholds: const [10, 40, 80]);
      expect(b.update(100, 0), 3);
      expect(b.rawLevelFor(39.9), 1);
    });

    test('speed zoom: closer in town, wider at highway speed', () {
      final z = SpeedZoomPolicy();
      z.seed(5);
      expect(z.zoom, 16.5);
      z.seed(120);
      expect(z.zoom, 14.7);
      final z2 = SpeedZoomPolicy()..seed(50);
      expect(z2.zoom, 15.7);
      // 61 km/h is inside the up margin (60 + 2): no change.
      z2.update(61, 0);
      expect(z2.update(61, 10000), 15.7);
      z2.update(70, 10000);
      expect(z2.update(70, 12500), 15.2);
    });
  });

  group('bad-fix filter', () {
    test('rejects poor accuracy and impossible jumps', () {
      final g = FixGate();
      expect(g.check(lat: 12, lng: 77, tsMs: 0, accuracyM: 8), FixVerdict.accept);
      expect(g.check(lat: 12.0001, lng: 77, tsMs: 1000, accuracyM: 80), FixVerdict.rejectInaccurate);
      // ~1.1 km in 1 s = 1100 m/s.
      expect(g.check(lat: 12.01, lng: 77, tsMs: 2000, accuracyM: 5), FixVerdict.rejectJump);
      // 25 m/s from the last good fix is fine.
      final (lat, lng) = NavMath.offsetMeters(12, 77, 0, 75);
      expect(g.check(lat: lat, lng: lng, tsMs: 3000, accuracyM: 5), FixVerdict.accept);
    });

    test('rejects null island and out-of-range coordinates', () {
      final g = FixGate();
      expect(g.check(lat: 0, lng: 0, tsMs: 0), FixVerdict.rejectInvalid);
      expect(g.check(lat: 91, lng: 0, tsMs: 0), FixVerdict.rejectInvalid);
      expect(g.check(lat: double.nan, lng: 1, tsMs: 0), FixVerdict.rejectInvalid);
    });

    test('re-anchors after a run of rejects so a wrong anchor cannot freeze the map', () {
      final g = FixGate(reanchorAfterRejects: 3);
      g.check(lat: 12, lng: 77, tsMs: 0, accuracyM: 5); // a bad anchor
      expect(g.check(lat: 13, lng: 77, tsMs: 1000, accuracyM: 5), FixVerdict.rejectJump);
      expect(g.check(lat: 13, lng: 77, tsMs: 2000, accuracyM: 5), FixVerdict.rejectJump);
      expect(g.check(lat: 13, lng: 77, tsMs: 3000, accuracyM: 5), FixVerdict.reanchor);
      expect(g.check(lat: 13.0001, lng: 77, tsMs: 4000, accuracyM: 5), FixVerdict.accept);
      expect(FixVerdict.reanchor.accepted, isTrue);
      expect(FixVerdict.rejectJump.accepted, isFalse);
    });

    test('accuracy slack: a jittery but plausible fix passes', () {
      final g = FixGate();
      g.check(lat: 12, lng: 77, tsMs: 0, accuracyM: 30);
      final (lat, lng) = NavMath.offsetMeters(12, 77, 90, 0);
      // 90 m in 1 s is 90 m/s, but 40 m of it is inside the reported accuracy.
      expect(g.check(lat: lat, lng: lng, tsMs: 1000, accuracyM: 40), FixVerdict.accept);
    });
  });

  group('marker tween', () {
    test('glides between reports over the report interval', () {
      final t = MarkerTrack(12, 77, 0, 0);
      expect(t.isAnimating(0), isFalse);
      t.retarget(12.001, 77, 10, 1000);
      expect(t.isAnimating(1500), isTrue);
      final (midLat, _, midH) = t.valueAt(1500);
      expect(midLat, closeTo(12.0005, 1e-9));
      expect(midH, closeTo(5, 1e-9));
      expect(t.isAnimating(2000), isFalse);
      expect(t.valueAt(2000).$1, closeTo(12.001, 1e-12));
    });

    test('heading tween takes the short way round', () {
      final t = MarkerTrack(12, 77, 350, 0);
      t.retarget(12.0001, 77, 10, 1000);
      final (_, _, h) = t.valueAt(1500);
      expect(h, closeTo(0, 1e-9));
    });

    test('a teleport snaps instead of sliding across the map', () {
      final t = MarkerTrack(12, 77, 0, 0);
      t.retarget(13, 77, 0, 1000);
      expect(t.isAnimating(1000), isFalse);
      expect(t.valueAt(1000).$1, 13);
    });

    test('an unchanged report does nothing', () {
      final t = MarkerTrack(12, 77, 0, 0);
      expect(t.retarget(12, 77, 0, 1000), isFalse);
    });
  });

  group('clustering', () {
    test('groups nearby markers and keeps pinned ones alone', () {
      final pts = <({double lat, double lng, bool pinned})>[
        (lat: 12.0, lng: 77.0, pinned: false),
        (lat: 12.00001, lng: 77.00001, pinned: false),
        (lat: 12.00002, lng: 77.0, pinned: true),
        (lat: 12.5, lng: 77.5, pinned: false),
      ];
      final groups = clusterByGrid(pts, zoom: 12);
      expect(groups.length, 3);
      expect(groups.any((g) => g.length == 2 && g.contains(0) && g.contains(1)), isTrue);
      expect(groups.any((g) => g.length == 1 && g.first == 2), isTrue);
      // Zoomed far in, the same two riders separate.
      expect(clusterByGrid(pts.sublist(0, 2), zoom: 21, cellPx: 8).length, 2);
    });
  });
}
