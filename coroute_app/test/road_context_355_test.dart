import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/places/road_context.dart';
import 'package:coroute_app/domain/route/bend_advisor.dart';
import 'package:coroute_app/domain/safety/altitude_care.dart';
import 'package:coroute_app/domain/safety/night_care.dart';
import 'package:coroute_app/domain/safety/speed_limit_advisor.dart';

// Synthetic lines in local metres (x east, y north) around 17N 78E.
const double _lat0 = 17.0, _lng0 = 78.0;
(double, double) ll(double x, double y) =>
    (_lat0 + y / 111320.0, _lng0 + x / (111320.0 * math.cos(_lat0 * math.pi / 180)));

/// A polyline builder: straight runs and circular arcs (turn > 0 = right).
class _Path {
  double x = 0, y = 0, hdg = 0; // heading in degrees, 0 = north
  final List<(double, double)> pts = [ll(0, 0)];
  void straight(double m, {double step = 50}) {
    final n = (m / step).ceil();
    for (var i = 0; i < n; i++) {
      final d = m / n;
      x += d * math.sin(hdg * math.pi / 180);
      y += d * math.cos(hdg * math.pi / 180);
      pts.add(ll(x, y));
    }
  }

  void arc(double radius, double turnDeg, {double stepDeg = 5}) {
    final n = (turnDeg.abs() / stepDeg).ceil();
    final dTurn = turnDeg / n;
    final chord = 2 * radius * math.sin((dTurn.abs() / 2) * math.pi / 180);
    for (var i = 0; i < n; i++) {
      final h = hdg + dTurn / 2;
      x += chord * math.sin(h * math.pi / 180);
      y += chord * math.cos(h * math.pi / 180);
      hdg += dTurn;
      pts.add(ll(x, y));
    }
  }
}

void main() {
  group('sharp-bend detection', () {
    test('a straight line has no bends', () {
      final p = _Path()..straight(2000);
      expect(BendAdvisor.detect(p.pts), isEmpty);
    });

    test('a gentle curve (r 1 km) is not a sharp bend', () {
      final p = _Path()
        ..straight(500)
        ..arc(1000, 40, stepDeg: 2)
        ..straight(500);
      expect(BendAdvisor.detect(p.pts), isEmpty);
    });

    test('a hairpin is one tight bend with a 20 km/h advisory', () {
      final p = _Path()
        ..straight(500)
        ..arc(15, 180, stepDeg: 10)
        ..straight(500);
      final bends = BendAdvisor.detect(p.pts);
      expect(bends.length, 1);
      expect(bends.single.turnDeg, closeTo(180, 2));
      expect(bends.single.radiusM, closeTo(15, 5));
      expect(bends.single.advisoryKmh, 20);
      expect(bends.single.startAlongM, closeTo(500, 15));
    });

    test('an S-bend is two bends in opposite directions', () {
      final p = _Path()
        ..straight(400)
        ..arc(60, 90)
        ..arc(60, -90)
        ..straight(400);
      final bends = BendAdvisor.detect(p.pts);
      expect(bends.length, 2);
      expect(bends[0].turnDeg, greaterThan(80));
      expect(bends[1].turnDeg, lessThan(-80));
      for (final b in bends) {
        expect(b.radiusM, closeTo(60, 12));
        expect(b.advisoryKmh, 40);
      }
    });

    test('a junction corner (one vertex) is left to the navigation voice', () {
      final p = _Path()
        ..straight(300)
        ..arc(1, 90, stepDeg: 90)
        ..straight(300);
      expect(BendAdvisor.detect(p.pts), isEmpty);
    });
  });

  group('advisory speed and warning', () {
    test('advisory speed: sqrt(2.5 r), rounded down to 5, at least 20', () {
      expect(BendAdvisor.advisoryKmhFor(60), 40);
      expect(BendAdvisor.advisoryKmhFor(100), 55);
      expect(BendAdvisor.advisoryKmhFor(200), 80);
      expect(BendAdvisor.advisoryKmhFor(15), 20);
      expect(BendAdvisor.advisoryKmhFor(2), 20);
    });

    test('lead distance: at least 6 s plus a gentle slow-down, 150..600 m', () {
      expect(BendAdvisor.leadFor(40, 35), 150);
      expect(BendAdvisor.leadFor(80, 40), closeTo(207, 3));
      expect(BendAdvisor.leadFor(160, 20), 600);
    });

    List<(double, double)> sBend() => (_Path()
          ..straight(800)
          ..arc(60, 90)
          ..arc(60, -90)
          ..straight(400))
        .pts;

    test('warns once, ahead of the bend, with the chained S-bend as one warning', () {
      final a = BendAdvisor()..setLine(sBend());
      final warnings = <(double, BendWarning)>[];
      var t = 0;
      for (var along = 0.0; along < 1200; along += 20, t += 1000) {
        final w = a.onFix(alongM: along, speedKmh: 80, nowMs: t);
        if (w != null) warnings.add((along, w));
      }
      expect(warnings.length, 1);
      final (at, w) = warnings.single;
      expect(w.count, 2);
      expect(w.advisoryKmh, 40);
      expect(w.distanceM, inInclusiveRange(150, 210));
      expect(at, lessThan(a.bends.first.startAlongM));
      expect(w.speech, startsWith('Sharp bends in'));
    });

    test('no warning when already slow enough, off the line or in town traffic', () {
      final a = BendAdvisor()..setLine(sBend());
      for (var along = 0.0; along < 1200; along += 10) {
        expect(a.onFix(alongM: along, speedKmh: 45, nowMs: along.toInt() * 100), isNull);
      }
      final b = BendAdvisor()..setLine(sBend());
      expect(b.onFix(alongM: 650, speedKmh: 90, nowMs: 0, onLine: false), isNull);
      expect(BendAdvisor.tooFast(30, 20), isFalse, reason: 'below 35 km/h never warns');
      expect(BendAdvisor.tooFast(50, 40), isTrue);
      expect(BendAdvisor.tooFast(45, 40), isFalse);
    });

    test('the same line instance is analysed once; locate follows the line', () {
      final line = sBend();
      final a = BendAdvisor()..setLine(line);
      final first = a.bends;
      a.setLine(line);
      expect(identical(first, a.bends), isTrue);
      final at = BendAdvisor.locate(line[4].$1, line[4].$2, line, hintAlongM: 150)!;
      expect(at.onLine, isTrue);
      expect(at.alongM, closeTo(200, 2));
    });
  });

  group('smart speed limits', () {
    test('maxspeed parsing', () {
      expect(SpeedLimitAdvisor.parseMaxspeed('50'), 50);
      expect(SpeedLimitAdvisor.parseMaxspeed('30 km/h'), 30);
      expect(SpeedLimitAdvisor.parseMaxspeed('50 mph'), 80);
      expect(SpeedLimitAdvisor.parseMaxspeed('IN:urban'), 50);
      expect(SpeedLimitAdvisor.parseMaxspeed('IN:rural'), 80);
      expect(SpeedLimitAdvisor.parseMaxspeed('IN:motorway'), 100);
      expect(SpeedLimitAdvisor.parseMaxspeed('DE:zone30'), 30);
      expect(SpeedLimitAdvisor.parseMaxspeed('60;40'), 60);
      for (final bad in ['none', 'signals', 'walk', 'variable', '', '300', '0', null]) {
        expect(SpeedLimitAdvisor.parseMaxspeed(bad), isNull, reason: '$bad');
      }
    });

    test('road context items from the cell wire (schools and road limits only)', () {
      final road = RoadContextItem.fromWire({'i': 'w1', 'a': 17.0, 'o': 78.0, 't': {'highway': 'primary', 'source:maxspeed': 'IN:urban'}});
      expect(road?.road?.limitKmh, 50);
      final school = RoadContextItem.fromWire({'i': 'w2', 'a': 17.0, 'o': 78.0, 't': {'amenity': 'school'}});
      expect(school?.zone?.kind, SpeedZoneKind.school);
      expect(RoadContextItem.fromWire({'i': 'n3', 'a': 17.0, 'o': 78.0, 't': {'amenity': 'bench'}}), isNull);
      expect(RoadContextItem.fromWire({'i': 'w4', 'a': 17.0, 'o': 78.0, 't': {'highway': 'primary', 'maxspeed': 'none'}}), isNull);
      expect(road!.toWire()['i'], 'w1');
    });

    final monday10 = DateTime(2026, 11, 9, 10);
    final sunday10 = DateTime(2026, 11, 8, 10);

    test('nearest road limit within 40 m; school and hospital zones are stricter', () {
      final a = SpeedLimitAdvisor();
      final (rLat, rLng) = ll(20, 0);
      final roads = [RoadLimitPoint(lat: rLat, lng: rLng, limitKmh: 50, highway: 'primary')];
      final (sLat, sLng) = ll(0, 100);
      final school = [SpeedZonePoint(lat: sLat, lng: sLng, kind: SpeedZoneKind.school)];
      final hospital = [SpeedZonePoint(lat: sLat, lng: sLng, kind: SpeedZoneKind.hospital)];
      final (lat, lng) = ll(0, 0);
      expect(a.limitAt(lat: lat, lng: lng, roads: roads, zones: const [], localNow: monday10)?.limitKmh, 50);
      final sc = a.limitAt(lat: lat, lng: lng, roads: roads, zones: school, localNow: monday10)!;
      expect((sc.limitKmh, sc.reason), (25, LimitReason.school));
      expect(a.limitAt(lat: lat, lng: lng, roads: roads, zones: school, localNow: sunday10)?.limitKmh, 50, reason: 'no school on Sunday');
      expect(a.limitAt(lat: lat, lng: lng, roads: roads, zones: hospital, localNow: monday10)?.limitKmh, 30);
      // A hospital beside a fast road does not cap it; nor without road data.
      final fast = [RoadLimitPoint(lat: rLat, lng: rLng, limitKmh: 80)];
      expect(SpeedLimitAdvisor().limitAt(lat: lat, lng: lng, roads: fast, zones: hospital, localNow: monday10)?.limitKmh, 80);
      expect(SpeedLimitAdvisor().limitAt(lat: lat, lng: lng, roads: const [], zones: hospital, localNow: monday10), isNull);
      // A school with no road data still counts (school hours).
      expect(SpeedLimitAdvisor().limitAt(lat: lat, lng: lng, roads: const [], zones: school, localNow: monday10)?.limitKmh, 25);
      // No data: no limit.
      expect(SpeedLimitAdvisor().limitAt(lat: lat, lng: lng, roads: const [], zones: const [], localNow: monday10), isNull);
    });

    test('a matched limit stays while riding on along the same heading, not after a turn', () {
      final a = SpeedLimitAdvisor();
      final (rLat, rLng) = ll(0, 10);
      final roads = [RoadLimitPoint(lat: rLat, lng: rLng, limitKmh: 40)];
      var (lat, lng) = ll(0, 0);
      expect(a.limitAt(lat: lat, lng: lng, headingDeg: 0, roads: roads, zones: const [], localNow: monday10)?.limitKmh, 40);
      (lat, lng) = ll(0, 300);
      expect(a.limitAt(lat: lat, lng: lng, headingDeg: 2, roads: roads, zones: const [], localNow: monday10)?.limitKmh, 40);
      expect(a.limitAt(lat: lat, lng: lng, headingDeg: 90, roads: roads, zones: const [], localNow: monday10), isNull);
      // A road point ahead on my heading matches before I reach it.
      final b = SpeedLimitAdvisor();
      final (aLat, aLng) = ll(5, 120);
      final ahead = [RoadLimitPoint(lat: aLat, lng: aLng, limitKmh: 60)];
      final (oLat, oLng) = ll(0, 0);
      expect(b.limitAt(lat: oLat, lng: oLng, headingDeg: 0, roads: ahead, zones: const [], localNow: monday10)?.limitKmh, 60);
      expect(SpeedLimitAdvisor().limitAt(lat: oLat, lng: oLng, headingDeg: 180, roads: ahead, zones: const [], localNow: monday10), isNull);
    });

    test('warns after 2 s over limit + 5 (3.55: was 8 s), then not again for 60 s; the stricter other limit wins', () {
      const ctx = LimitContext(limitKmh: 50, reason: LimitReason.road, roadLimitKmh: 50);
      final a = SpeedLimitAdvisor();
      expect(a.onSpeed(context: ctx, speedKmh: 55, nowMs: 0), isNull, reason: 'within the tolerance');
      expect(a.onSpeed(context: ctx, speedKmh: 60, nowMs: 1000), isNull);
      expect(a.onSpeed(context: ctx, speedKmh: 60, nowMs: 2500), isNull);
      final w = a.onSpeed(context: ctx, speedKmh: 61, nowMs: 3000);
      expect(w?.limitKmh, 50);
      expect(w?.speech, contains('50'));
      expect(a.onSpeed(context: ctx, speedKmh: 61, nowMs: 30000), isNull, reason: 'cooldown');
      expect(a.onSpeed(context: ctx, speedKmh: 61, nowMs: 70000), isNotNull);
      // Slowing down resets the hold.
      final b = SpeedLimitAdvisor();
      b.onSpeed(context: ctx, speedKmh: 62, nowMs: 0);
      b.onSpeed(context: ctx, speedKmh: 45, nowMs: 5000);
      expect(b.onSpeed(context: ctx, speedKmh: 62, nowMs: 9000), isNull);
      // The group limit (40) is stricter: it alone warns. Or it is warning already.
      final c = SpeedLimitAdvisor();
      expect(c.onSpeed(context: ctx, speedKmh: 70, nowMs: 0, otherLimitKmh: 40), isNull);
      expect(c.onSpeed(context: ctx, speedKmh: 70, nowMs: 9000, otherLimitKmh: 40), isNull);
      expect(c.onSpeed(context: ctx, speedKmh: 70, nowMs: 20000, otherLimitKmh: 80, otherActive: true), isNull);
      // A looser group limit (80): the road limit warns.
      final d = SpeedLimitAdvisor();
      d.onSpeed(context: ctx, speedKmh: 70, nowMs: 0, otherLimitKmh: 80);
      expect(d.onSpeed(context: ctx, speedKmh: 70, nowMs: 8000, otherLimitKmh: 80), isNotNull);
      // No data never warns.
      expect(SpeedLimitAdvisor().onSpeed(context: null, speedKmh: 150, nowMs: 0), isNull);
    });
  });

  group('high-altitude care', () {
    test('first time above 3,000 m after a 30 s hold, once per ride', () {
      final a = AltitudeCare();
      final got = <AltitudeNotice>[];
      for (var t = 0; t <= 120000; t += 5000) {
        final n = a.onFix(ts: t, altM: 3100);
        if (n != null) got.add(n);
      }
      expect(got.length, 1);
      expect(got.single.kind, AltitudeNoticeKind.high);
      expect(got.single.speech, contains('above 3,000 metres'));
    });

    test('above 4,500 m: the stronger wording', () {
      final a = AltitudeCare();
      AltitudeNotice? n;
      for (var t = 0; t <= 60000 && n == null; t += 5000) {
        n = a.onFix(ts: t, altM: 4600);
      }
      expect(n?.kind, AltitudeNoticeKind.veryHigh);
      expect(n?.speech, contains('go lower'));
    });

    test('a climb of more than 800 m within 60 min (above 2,500 m) asks for a break', () {
      final a = AltitudeCare();
      final got = <(int, AltitudeNotice)>[];
      // 2,000 m to 2,950 m in 50 min, never above 3,000 m.
      for (var t = 0; t <= 50 * 60000; t += 10000) {
        final n = a.onFix(ts: t, altM: 2000 + 950 * t / (50 * 60000));
        if (n != null) got.add((t, n));
      }
      expect(got.length, 1);
      expect(got.single.$2.kind, AltitudeNoticeKind.fastClimb);
      expect(got.single.$2.speech, 'Fast climb. Take a 10-minute break.');
    });

    test('a slow climb, the plains and missing altitude say nothing', () {
      final a = AltitudeCare();
      for (var t = 0; t <= 3 * 3600000; t += 30000) {
        expect(a.onFix(ts: t, altM: 1000 + 400 * t / 3600000), isNull); // 400 m per hour
      }
      final b = AltitudeCare();
      for (var t = 0; t <= 600000; t += 5000) {
        expect(b.onFix(ts: t, altM: null), isNull);
        expect(b.onFix(ts: t, altM: 0), isNull);
      }
      expect(b.altitudeM, isNull);
    });

    test('reminders at most every 45 min; a single GPS spike does not count', () {
      final a = AltitudeCare();
      final got = <int>[];
      // A spike to 3,500 m among 2,900 m readings is ignored by the median.
      for (var t = 0; t < 60000; t += 5000) {
        expect(a.onFix(ts: t, altM: t == 20000 ? 3500 : 2900), isNull);
      }
      // Above 3,000 m (notice), then a fast climb right after: held until 45 min have passed.
      var alt = 3100.0;
      for (var t = 60000; t <= 60 * 60000; t += 10000) {
        if (t > 5 * 60000 && alt < 4400) alt += 30;
        if (a.onFix(ts: t, altM: alt) != null) got.add(t);
      }
      expect(got.length, 2);
      expect(got[1] - got[0], greaterThanOrEqualTo(45 * 60000));
    });
  });

  group('night riding care', () {
    test('one sunset note when a ride that saw daylight gets dark', () {
      final n = NightCare();
      expect(n.onDark(false), isFalse);
      expect(n.onDark(true), isTrue);
      expect(n.onDark(true), isFalse);
      expect(n.onDark(false), isFalse);
      expect(n.onDark(true), isFalse, reason: 'once per ride');
      final started = NightCare();
      expect(started.onDark(true), isFalse, reason: 'a ride started at night gets no sunset note');
      expect(NightCare.sunsetSpeech, 'Sun has set. Breaks come a little earlier tonight. Keep extra distance.');
    });

    test('break interval: 2 h by day, 90 min at night; one early prompt per stretch', () {
      final n = NightCare();
      expect(n.breakInterval(dark: false), const Duration(hours: 2));
      expect(n.breakInterval(dark: true), const Duration(minutes: 90));
      const start = 1000000;
      const min = 60000;
      expect(n.earlyBreakDue(stretchStartMs: start, nowMs: start + 89 * min, dark: true), isFalse);
      expect(n.earlyBreakDue(stretchStartMs: start, nowMs: start + 90 * min, dark: false), isFalse, reason: 'not by day');
      expect(n.earlyBreakDue(stretchStartMs: start, nowMs: start + 91 * min, dark: true), isTrue);
      expect(n.earlyBreakDue(stretchStartMs: start, nowMs: start + 95 * min, dark: true), isFalse, reason: 'once per stretch');
      expect(n.earlyBreakDue(stretchStartMs: null, nowMs: start + 95 * min, dark: true), isFalse);
      // After a real break a new stretch gets its own early prompt; past 2 h the regular one is due.
      const next = start + 200 * min;
      expect(n.earlyBreakDue(stretchStartMs: next, nowMs: next + 121 * min, dark: true), isFalse);
      expect(n.earlyBreakDue(stretchStartMs: next, nowMs: next + 100 * min, dark: true), isTrue);
    });
  });
}
