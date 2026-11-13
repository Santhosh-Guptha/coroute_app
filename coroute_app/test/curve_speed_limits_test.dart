// Round 7: road cells, map matching, speed limit resolution, estimate table, overspeed rule.
//   DART=/opt/dartpkg/bin/dart tool/pure_dart_test/run.sh test/curve_speed_limits_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/intel/geohash.dart';
import 'package:coroute_app/domain/road/curve_predictor.dart';
import 'package:coroute_app/domain/road/india_speed_limits.dart';
import 'package:coroute_app/domain/road/road_cell.dart';
import 'package:coroute_app/domain/road/road_matcher.dart';
import 'package:coroute_app/domain/road/speed_limit_resolver.dart';

/// Wire geometry (delta-encoded 1e-5 degrees) from (lat, lng) points.
List<int> g(List<(double, double)> pts) {
  final out = <int>[];
  var a = 0, o = 0;
  for (final p in pts) {
    final la = (p.$1 * 1e5).round(), lo = (p.$2 * 1e5).round();
    out..add(la - a)..add(lo - o);
    a = la;
    o = lo;
  }
  return out;
}

int cls(String h) => roadClasses.indexOf(h);

/// A small road graph around (12.9000, 77.6000); 0.0001 degrees is about 11 m.
///   way 1: main road, northbound carriageway along lng 77.6000 from lat 12.9000 to 12.9040 (tag 50)
///   way 2: its continuation north, 12.9040 to 12.9080, bends right at the end (same name, no tag)
///   way 3: side street east from (12.9040, 77.6000) (residential)
///   way 4: a parallel one-way road 25 m east (lng 77.60023), southbound only
///   way 5: service lane 8 m west of the main road
Map<String, Object> cellJson({Map<String, int> fx = const {}, int buildings = 0}) => {
      'v': 1,
      'c': 'tdr1v0',
      'w': [
        {'i': 1, 'h': cls('primary'), 'n': 'Main Road', 'ms': '50', 'ow': 1, 'ln': 2, 'g': g([(12.9000, 77.6000), (12.9020, 77.6000), (12.9040, 77.6000)])},
        {
          'i': 2, 'h': cls('primary'), 'n': 'Main Road',
          'g': g([(12.9040, 77.6000), (12.9070, 77.6000), (12.9074, 77.6001), (12.9077, 77.6004), (12.9078, 77.6008), (12.9078, 77.6030)])
        },
        {'i': 3, 'h': cls('residential'), 'n': 'Side Street', 'g': g([(12.9040, 77.6000), (12.9040, 77.6030)])},
        {'i': 4, 'h': cls('primary'), 'n': 'Main Road', 'ow': -1, 'ln': 2, 'g': g([(12.9000, 77.60023), (12.9040, 77.60023)])},
        {'i': 5, 'h': cls('service'), 'g': g([(12.9000, 77.59993), (12.9040, 77.59993)])},
      ],
      'z': [[1290300, 7760050, 's'], [1290700, 7760040, 'h']],
      'u': {'b': buildings, 'lu': 0},
      'fx': fx,
    };

RoadWay way({String h = 'primary', String? ms, String? mm, String? mt, int ow = 0, int ln = 0, bool lit = false}) =>
    RoadWay(id: 9, cls: cls(h), lat5: [1290000, 1290100], lng5: [7760000, 7760000], maxspeed: ms, maxspeedMotorcycle: mm, maxspeedType: mt, oneway: ow, lanes: ln, lit: lit);

void main() {
  group('road cell', () {
    test('decodes the wire format; bad input is refused', () {
      final c = RoadCell.fromJson(cellJson(fx: {'3': 20}))!;
      expect(c.ways.length, 5);
      expect(c.ways[0].highway, 'primary');
      expect(c.ways[0].latAt(2), closeTo(12.9040, 1e-9));
      expect(c.ways[3].oneway, -1);
      expect(c.zones.length, 2);
      expect(c.zones.first.school, isTrue);
      expect(c.corrections, {3: 20});
      expect(RoadCell.fromJson({'v': 2, 'c': 'x', 'w': []}), isNull);
      expect(RoadCell.fromJson('nope'), isNull);
      expect(RoadWay.fromJson({'i': 1, 'h': 2, 'g': [1, 2, 3]}), isNull);
      expect(RoadWay.fromJson({'i': 1, 'h': 2, 'g': [99999999, 2, 3, 4]}), isNull);
    });

    test('urban hint: buildings, or mostly residential streets', () {
      expect(RoadCell.fromJson(cellJson())!.urban, isFalse);
      expect(RoadCell.fromJson(cellJson(buildings: 200))!.urban, isTrue);
    });

    test('cells to fetch: mine first, then ahead on my heading; along a route in order', () {
      final mine = Geohash.encode(12.9, 77.6, 6)!;
      final north = RoadCellPlanner.around(12.9, 77.6, headingDeg: 0);
      expect(north.first, mine);
      expect(north.length, inInclusiveRange(3, 9));
      expect(north.contains(Geohash.encode(12.9 + 2000 / 110540, 77.6, 6)), isTrue);
      expect(north.contains(Geohash.encode(12.9 - 2000 / 110540, 77.6, 6)), isFalse, reason: 'nothing behind me');
      final still = RoadCellPlanner.around(12.9, 77.6);
      expect(still.first, mine);
      expect(still.length, lessThanOrEqualTo(9));
      final route = RoadCellPlanner.alongRoute([(12.9, 77.6), (12.95, 77.6)]);
      expect(route.first, mine);
      expect(route.last, Geohash.encode(12.95, 77.6, 6));
      expect(route.toSet().length, route.length);
      expect(RoadCellPlanner.alongRoute([(12.9, 77.6), (12.95, 77.6)], aheadM: 1000).length, lessThan(route.length));
    });

    test('LRU bounded in bytes: the least recently used cells go first', () {
      final l = RoadCellLru(maxBytes: 1000);
      expect(l.put('a', 400, 1), isEmpty);
      expect(l.put('b', 400, 2), isEmpty);
      l.touch('a');
      expect(l.put('c', 400, 3), ['b']);
      expect(l.usedBytes, 800);
      expect(l.has('a'), isTrue);
      expect(l.put('d', 900, 4), ['a', 'c']);
      expect(l.usedBytes, 900);
      final copy = RoadCellLru(maxBytes: 1000)..load(l.toJson());
      expect(copy.usedBytes, 900);
      expect(copy.fetchedAt('d'), 4);
    });
  });

  group('map matching', () {
    late RoadMatcher m;
    setUp(() => m = RoadMatcher()..addCell(RoadCell.fromJson(cellJson())!));

    test('no data, or too far from any road: null (the app stays silent)', () {
      expect(RoadMatcher().match(12.9, 77.6, headingDeg: 0, speedKmh: 40), isNull);
      expect(m.match(12.9020, 77.6100, headingDeg: 0, speedKmh: 40), isNull);
    });

    test('heading picks the carriageway: northbound on the main road, southbound on the one-way', () {
      // Half way between way 1 and way 4 (12 m from each).
      final north = m.match(12.9020, 77.60011, headingDeg: 2, speedKmh: 50)!;
      expect(north.way.id, 1);
      expect(north.forward, isTrue);
      final south = m.match(12.9020, 77.60013, headingDeg: 181, speedKmh: 50)!;
      expect(south.way.id, 4, reason: 'the one-way road runs south');
      expect(m.match(12.9020, 77.60023, headingDeg: 0, speedKmh: 50)!.way.id, 1, reason: 'never the wrong way on a one-way road');
    });

    test('a road across my heading is not matched; the service lane does not win over the main road', () {
      // On the side street's start, riding north: the main road, not the street going east.
      expect(m.match(12.90401, 77.60003, headingDeg: 0, speedKmh: 40)!.way.cls, cls('primary'));
      expect(m.match(12.9020, 77.59997, headingDeg: 0, speedKmh: 40)!.way.id, 1);
      // Riding east on the side street.
      expect(m.match(12.90401, 77.6015, headingDeg: 90, speedKmh: 30)!.way.id, 3);
    });

    test('continuity: a noisy fix between two roads stays on the road I was on', () {
      expect(m.match(12.9010, 77.60002, headingDeg: 0, speedKmh: 50)!.way.id, 1);
      // 14 m east: nearer to nothing in particular, both directions plausible without heading.
      final r = m.match(12.9015, 77.60013, speedKmh: 0)!;
      expect(r.way.id, 1);
    });

    test('look ahead: follows the road through the junction onto its continuation, bend included', () {
      final at = m.match(12.9030, 77.6000, headingDeg: 0, speedKmh: 50)!;
      final a = m.ahead(at, maxM: 900);
      expect(a.spans.map((s) => s.way.id).toList(), [1, 2]);
      expect(a.spans[1].fromM, closeTo(110, 5));
      expect(a.wayAt(50)!.id, 1);
      expect(a.wayAt(300)!.id, 2);
      final curves = CurveAnalyzer.analyze(a.line);
      expect(curves.length, 1);
      expect(curves.single.right, isTrue);
      expect(curves.single.startM, inInclusiveRange(380, 460));
      expect(curves.single.cls.index, greaterThanOrEqualTo(CurveClass.medium.index));
    });

    test('look ahead ends at a junction where the way on is not clear, and against a one-way', () {
      // Riding west on the side street to the T-junction: left or right is a guess.
      final at = m.match(12.9040, 77.6015, headingDeg: 270, speedKmh: 30)!;
      final a = m.ahead(at);
      expect(a.spans.single.way.id, 3);
      expect(a.endedAtJunction, isTrue);
      expect(a.line.last.$2, closeTo(77.6000, 1e-6));
    });

    test('zones near a point and corrections by way', () {
      expect(m.zonesNear(12.9030, 77.6000), (true, false));
      expect(m.zonesNear(12.9070, 77.6000), (false, true));
      expect(m.zonesNear(12.9050, 77.6020), (false, false));
      final fixed = RoadMatcher()..addCell(RoadCell.fromJson(cellJson(fx: {'2': 40}))!);
      expect(fixed.correctionFor(2), 40);
      expect(fixed.correctionFor(1), isNull);
    });

    test('at most 24 cells stay loaded', () {
      for (var i = 0; i < 40; i++) {
        m.addCell(RoadCell(id: 'c$i', ways: const []));
      }
      expect(m.cellCount, 24);
    });
  });

  group('limit resolution order', () {
    test('1: maxspeed:motorcycle, then maxspeed; a car limit above 80 reads 80', () {
      final a = SpeedLimitResolver.resolve(way(ms: '70', mm: '50'), urban: false);
      expect((a.kmh, a.source, a.estimated, a.label), (50, LimitSource.osmMotorcycle, false, '50'));
      final b = SpeedLimitResolver.resolve(way(ms: '40'), urban: true);
      expect((b.kmh, b.source, b.confidence), (40, LimitSource.osm, LimitConfidence.high));
      final c = SpeedLimitResolver.resolve(way(h: 'trunk', ms: '100'), urban: false);
      expect((c.kmh, c.source), (80, LimitSource.osm));
      expect(SpeedLimitResolver.resolve(way(ms: '30 mph'), urban: false).kmh, 48);
    });

    test('2: a correction replaces an estimate, lowers a tag, never raises a tag', () {
      final est = SpeedLimitResolver.resolve(way(h: 'residential'), urban: true, correctionKmh: 20);
      expect((est.kmh, est.source, est.estimated), (20, LimitSource.corrected, false));
      final lower = SpeedLimitResolver.resolve(way(ms: '50'), urban: true, correctionKmh: 30);
      expect((lower.kmh, lower.source), (30, LimitSource.corrected));
      final up = SpeedLimitResolver.resolve(way(ms: '50'), urban: true, correctionKmh: 70);
      expect((up.kmh, up.source), (50, LimitSource.osm));
      expect(SpeedLimitResolver.resolve(way(h: 'residential'), urban: true, correctionKmh: 100).source, LimitSource.estimate, reason: 'above the motorcycle maximum is ignored');
    });

    test('3: the implied type: IN:urban is 60 for a motorcycle (70 is the car value), zones by number', () {
      final u = SpeedLimitResolver.resolve(way(mt: 'IN:urban'), urban: true);
      expect((u.kmh, u.source, u.estimated, u.label), (60, LimitSource.osmImplicit, true, '~60'));
      expect(SpeedLimitResolver.resolve(way(mt: 'IN:rural'), urban: false).kmh, 60);
      expect(SpeedLimitResolver.resolve(way(mt: 'IN:rural', ow: 1, ln: 2), urban: false).kmh, 80);
      expect(SpeedLimitResolver.resolve(way(mt: 'DE:zone30'), urban: true).kmh, 30);
      expect(SpeedLimitResolver.resolve(way(ms: 'IN:urban'), urban: true).kmh, 60);
      expect(SpeedLimitResolver.implicit('sign'), isNull);
      expect(SpeedLimitResolver.numeric('none'), isNull);
      expect(SpeedLimitResolver.numeric('walk'), isNull);
    });

    test('4: the estimate table by class and built-up area, marked estimated with a confidence', () {
      ResolvedLimit e(String h, bool urban, {int ow = 0, int ln = 0, bool lit = false}) => SpeedLimitResolver.resolve(way(h: h, ow: ow, ln: ln, lit: lit), urban: urban);
      expect((e('motorway', false).kmh, e('motorway', false).confidence), (80, LimitConfidence.high));
      expect((e('trunk', false).kmh, e('trunk', false).confidence), (60, LimitConfidence.medium));
      expect(e('trunk', false, ow: 1, ln: 2).kmh, 80, reason: 'divided 4-lane road');
      expect(e('trunk', true, ow: 1, ln: 2).kmh, 50, reason: 'not in a built-up area');
      expect(e('primary', true).kmh, 50);
      expect(e('secondary', false).kmh, 60);
      expect(e('tertiary', true).kmh, 40);
      expect(e('tertiary', false).kmh, 50);
      expect((e('residential', false).kmh, e('residential', false).confidence), (30, LimitConfidence.low));
      expect(e('living_street', true).kmh, 20);
      expect(e('service', false).kmh, 20);
      expect(e('primary_link', false).kmh, 40);
      expect(e('secondary', false, lit: true).kmh, 50, reason: 'a lit road is treated as built-up');
      final r = e('tertiary', false);
      expect((r.source, r.estimated, r.label), (LimitSource.estimate, true, '~50'));
      expect(r.basis, isNotEmpty);
    });

    test('the table never exceeds the statutory motorcycle maximum (S.O. 1522(E)); overrides are empty until verified', () {
      for (final row in IndiaSpeedLimits.table.entries) {
        final rural = row.key == 'motorway' ? 80 : 60;
        expect(row.value.$1.kmh, lessThanOrEqualTo(60 + (row.key == 'motorway' ? 20 : 0)), reason: row.key);
        expect(row.value.$2.kmh, lessThanOrEqualTo(rural), reason: row.key);
      }
      expect(IndiaSpeedLimits.dividedRural.kmh, IndiaSpeedLimits.motorcycleMaxKmh);
      expect(IndiaSpeedLimits.implicit.values.every((v) => v <= 80), isTrue);
      expect(IndiaSpeedLimits.stateOverrides, isEmpty);
    });

    test('typical speeds are a sanity check only: the number never changes', () {
      final e = SpeedLimitResolver.resolve(way(h: 'secondary'), urban: false);
      final low = SpeedLimitResolver.sanity(e, typicalKmh: 25);
      expect((low.kmh, low.confidence), (60, LimitConfidence.low));
      expect(SpeedLimitResolver.sanity(e, typicalKmh: 55).confidence, LimitConfidence.medium);
      expect(SpeedLimitResolver.sanity(e, typicalKmh: 95).kmh, 60, reason: 'fast riders never raise it');
      final tagged = SpeedLimitResolver.resolve(way(ms: '50'), urban: false);
      expect(identical(SpeedLimitResolver.sanity(tagged, typicalKmh: 10), tagged), isTrue);
    });
  });

  group('overspeed rule', () {
    ResolvedLimit lim(int kmh, {LimitSource s = LimitSource.osm, bool school = false}) =>
        ResolvedLimit(kmh: kmh, source: s, confidence: LimitConfidence.high, school: school);

    test('thresholds: +10% but at least 5 km/h; strong above 20%; a zone has no tolerance', () {
      expect(OverspeedPolicy.thresholdKmh(40), 45);
      expect(OverspeedPolicy.thresholdKmh(80), 88);
      expect(OverspeedPolicy.thresholdKmh(80, tolerancePct: 5), 85);
      expect(OverspeedPolicy.thresholdKmh(100, tolerancePct: 20), 120);
      expect(OverspeedPolicy.thresholdKmh(25, zone: true), 25);
      expect(OverspeedPolicy.levelOf(45, 40), OverspeedLevel.none);
      expect(OverspeedPolicy.levelOf(46, 40), OverspeedLevel.over);
      expect(OverspeedPolicy.levelOf(48.1, 40), OverspeedLevel.strong);
      expect(OverspeedPolicy.levelOf(88, 80), OverspeedLevel.none);
      expect(OverspeedPolicy.levelOf(90, 80), OverspeedLevel.over);
      expect(OverspeedPolicy.levelOf(97, 80), OverspeedLevel.strong);
      expect(OverspeedPolicy.levelOf(27, 25, zone: true), OverspeedLevel.over);
      expect(OverspeedPolicy.levelOf(27, 25), OverspeedLevel.none);
    });

    test('voice once after 2 s, then visual only; strong speaks once more; re-armed after 20 s under the limit', () {
      final p = OverspeedPolicy();
      final l = lim(50);
      expect(p.onSpeed(limit: l, speedKmh: 58, nowMs: 0).speak, isFalse);
      expect(p.onSpeed(limit: l, speedKmh: 58, nowMs: 1000).level, OverspeedLevel.over);
      final first = p.onSpeed(limit: l, speedKmh: 58, nowMs: 2100);
      expect((first.speak, first.speech), (true, 'Speed limit 50. Please slow down.'));
      for (var t = 3000; t < 60000; t += 1000) {
        final d = p.onSpeed(limit: l, speedKmh: 58, nowMs: t);
        expect((d.speak, d.level), (false, OverspeedLevel.over), reason: 'visual only at $t');
      }
      final strong = p.onSpeed(limit: l, speedKmh: 66, nowMs: 61000);
      expect((strong.speak, strong.level), (true, OverspeedLevel.strong));
      expect(p.onSpeed(limit: l, speedKmh: 70, nowMs: 62000).speak, isFalse);
      // Back under the limit for 10 s: not re-armed yet.
      for (var t = 63000; t <= 73000; t += 1000) {
        p.onSpeed(limit: l, speedKmh: 45, nowMs: t);
      }
      p.onSpeed(limit: l, speedKmh: 58, nowMs: 74000);
      expect(p.onSpeed(limit: l, speedKmh: 58, nowMs: 77000).speak, isFalse);
      // Under for 20 s: the next stretch speaks again.
      for (var t = 78000; t <= 99000; t += 1000) {
        p.onSpeed(limit: l, speedKmh: 45, nowMs: t);
      }
      p.onSpeed(limit: l, speedKmh: 58, nowMs: 100000);
      expect(p.onSpeed(limit: l, speedKmh: 58, nowMs: 102500).speak, isTrue);
    });

    test('an estimated limit never speaks; voice off never speaks; the level still shows', () {
      final p = OverspeedPolicy();
      final e = lim(50, s: LimitSource.estimate);
      p.onSpeed(limit: e, speedKmh: 70, nowMs: 0);
      final d = p.onSpeed(limit: e, speedKmh: 70, nowMs: 5000);
      expect((d.speak, d.level), (false, OverspeedLevel.strong));
      final q = OverspeedPolicy();
      q.onSpeed(limit: lim(50), speedKmh: 70, nowMs: 0, voice: false);
      expect(q.onSpeed(limit: lim(50), speedKmh: 70, nowMs: 5000, voice: false).speak, isFalse);
    });

    test('limit changes: announced only when lower and the rider is above it', () {
      final p = OverspeedPolicy();
      expect(p.onSpeed(limit: lim(60), speedKmh: 55, nowMs: 0).speak, isFalse);
      final up = p.onSpeed(limit: lim(80), speedKmh: 55, nowMs: 1000);
      expect((up.speak, up.limitDropped), (false, false), reason: 'a higher limit is not announced');
      final under = p.onSpeed(limit: lim(60), speedKmh: 50, nowMs: 2000);
      expect((under.speak, under.limitDropped), (false, false), reason: 'lower, but the rider is already under it');
      final down = p.onSpeed(limit: lim(40), speedKmh: 50, nowMs: 3000);
      expect((down.speak, down.limitDropped), (true, true));
      expect(down.speech, 'Speed limit now 40. Please slow down.');
      expect(p.onSpeed(limit: lim(40), speedKmh: 50, nowMs: 6000).speak, isFalse, reason: 'said once');
      final q = OverspeedPolicy();
      q.onSpeed(limit: lim(60), speedKmh: 43, nowMs: 0);
      final calm = q.onSpeed(limit: lim(40), speedKmh: 43, nowMs: 1000);
      expect((calm.speak, calm.speech, calm.level), (true, 'Speed limit now 40.', OverspeedLevel.none));
    });

    test('school zone: no tolerance and it says so; no limit: nothing', () {
      final p = OverspeedPolicy();
      final z = lim(25, school: true);
      p.onSpeed(limit: z, speedKmh: 28, nowMs: 0);
      final d = p.onSpeed(limit: z, speedKmh: 28, nowMs: 2500);
      expect((d.speak, d.speech), (true, 'School zone. Speed limit 25. Please slow down.'));
      expect(p.onSpeed(limit: null, speedKmh: 120, nowMs: 3000).level, OverspeedLevel.none);
    });
  });
}
