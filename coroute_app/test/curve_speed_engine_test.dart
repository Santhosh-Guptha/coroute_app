// Round 7: the road-ahead engine (route mode, free riding, limit + overspeed + chip state).
//   DART=/opt/dartpkg/bin/dart tool/pure_dart_test/run.sh test/curve_speed_engine_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/road/curve_predictor.dart';
import 'package:coroute_app/domain/road/road_ahead_engine.dart';
import 'package:coroute_app/domain/road/road_cell.dart';
import 'package:coroute_app/domain/road/speed_limit_resolver.dart';

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

/// A road north along lng 77.6 for 660 m, then a tight right bend (radius about 50 m), then east.
final List<(double, double)> road = [
  (12.9000, 77.6000), (12.9030, 77.6000), (12.9060, 77.6000),
  (12.90625, 77.60003), (12.90648, 77.60012), (12.90665, 77.60026), (12.90676, 77.60044), (12.9068, 77.60065),
  (12.9068, 77.6040),
];

RoadCell cell({String? ms, Map<String, int> fx = const {}, List<List<Object>> z = const []}) => RoadCell.fromJson({
      'v': 1, 'c': 'tdr1v0',
      'w': [
        {'i': 7, 'h': roadClasses.indexOf('secondary'), 'n': 'Hill Road', 'ms': ?ms, 'g': g(road)},
      ],
      'z': z, 'u': {'b': 0, 'lu': 0}, 'fx': fx,
    })!;

void main() {
  test('no road data: silent and empty (free riding)', () {
    final e = RoadAheadEngine();
    final o = e.onFix(lat: 12.9040, lng: 77.6, speedKmh: 70, nowMs: 1000, headingDeg: 0);
    expect(o.curveWarning, isNull);
    expect(o.view.isEmpty, isTrue);
    expect(o.matched, isFalse);
  });

  test('free riding: the bend on the matched road is warned once, the chip stays until the apex is passed', () {
    final e = RoadAheadEngine()..matcher.addCell(cell(ms: '60'));
    final warnings = <CurveWarning>[];
    var chipSeen = false, chipGone = false;
    var t = 0;
    // 54 km/h north: 15 m a second.
    for (var lat = 12.9005; lat < 12.9060; lat += 0.000135) {
      t += 1000;
      final o = e.onFix(lat: lat, lng: 77.6000, speedKmh: 54, nowMs: t, headingDeg: 0);
      expect(o.matched, isTrue);
      if (o.curveWarning != null) warnings.add(o.curveWarning!);
      if (o.view.curve != null) chipSeen = true;
    }
    expect(warnings.length, 1);
    expect(warnings.single.curve.right, isTrue);
    expect(warnings.single.distanceM, inInclusiveRange(80, 110));
    expect(warnings.single.advisoryKmh, lessThanOrEqualTo(45));
    expect(chipSeen, isTrue);
    // Through the bend and on to the east: the chip goes.
    for (final p in [(12.90648, 77.60012), (12.90676, 77.60044), (12.9068, 77.6010), (12.9068, 77.6020)]) {
      t += 1500;
      final o = e.onFix(lat: p.$1, lng: p.$2, speedKmh: 35, nowMs: t, headingDeg: 80);
      expect(o.curveWarning, isNull);
      chipGone = o.view.curve == null;
    }
    expect(chipGone, isTrue);
  });

  test('free riding below the advisory speed, or with curve warnings off: nothing', () {
    for (final (speed, prefs) in [(30.0, const RoadAheadPrefs()), (70.0, const RoadAheadPrefs(curveWarnings: false))]) {
      final e = RoadAheadEngine()..matcher.addCell(cell());
      var t = 0;
      for (var lat = 12.9005; lat < 12.9060; lat += 0.0001) {
        t += 1000;
        final o = e.onFix(lat: lat, lng: 77.6000, speedKmh: speed, nowMs: t, headingDeg: 0, prefs: prefs);
        expect(o.curveWarning, isNull);
        expect(o.view.curve, isNull);
      }
    }
  });

  test('on a route the bends come from the route line (no road cells needed), analysed once', () {
    final e = RoadAheadEngine();
    final line = List<(double, double)>.of(road);
    CurveWarning? got;
    var t = 0;
    for (var along = 0.0; along < 660; along += 15) {
      t += 1000;
      final o = e.onFix(lat: 12.9 + along / 110540, lng: 77.6, speedKmh: 54, nowMs: t, headingDeg: 0, routeLine: line, routeAlongM: along, onRoute: true);
      got ??= o.curveWarning;
      expect(o.matched, isFalse);
    }
    expect(got, isNotNull);
    expect(identical(e.routeCurves, e.routeCurves), isTrue);
    expect(e.routeCurves.length, 1);
  });

  test('the limit comes from the matched road: tag, estimate ("~"), correction; it caps the bend advisory', () {
    final tagged = RoadAheadEngine()..matcher.addCell(cell(ms: '40'));
    final a = tagged.onFix(lat: 12.9010, lng: 77.6, speedKmh: 30, nowMs: 1, headingDeg: 0);
    expect((a.view.limit!.kmh, a.view.limit!.estimated, a.view.limit!.label), (40, false, '40'));
    final est = RoadAheadEngine()..matcher.addCell(cell());
    final b = est.onFix(lat: 12.9010, lng: 77.6, speedKmh: 30, nowMs: 1, headingDeg: 0);
    expect((b.view.limit!.kmh, b.view.limit!.estimated, b.view.limit!.label), (60, true, '~60'));
    final fixed = RoadAheadEngine()..matcher.addCell(cell(fx: {'7': 40}));
    final c = fixed.onFix(lat: 12.9010, lng: 77.6, speedKmh: 30, nowMs: 1, headingDeg: 0);
    expect((c.view.limit!.kmh, c.view.limit!.source), (40, LimitSource.corrected));
    final hidden = est.onFix(lat: 12.9011, lng: 77.6, speedKmh: 30, nowMs: 2, headingDeg: 0, prefs: const RoadAheadPrefs(limitDisplay: false));
    expect(hidden.view.limit, isNull);
  });

  test('overspeed: tagged limit speaks once then shows; estimated limit only shows; tolerance from settings', () {
    final e = RoadAheadEngine()..matcher.addCell(cell(ms: '40'));
    var spoken = 0;
    OverspeedLevel last = OverspeedLevel.none;
    for (var i = 0; i < 20; i++) {
      final o = e.onFix(lat: 12.9010 + i * 0.0001, lng: 77.6, speedKmh: 47, nowMs: i * 1000, headingDeg: 0);
      if (o.overspeed.speak) spoken++;
      last = o.view.level;
    }
    expect(spoken, 1);
    expect(last, OverspeedLevel.over);
    final wide = RoadAheadEngine()..matcher.addCell(cell(ms: '40'));
    for (var i = 0; i < 6; i++) {
      final o = wide.onFix(lat: 12.9010 + i * 0.0001, lng: 77.6, speedKmh: 47, nowMs: i * 1000, headingDeg: 0, prefs: const RoadAheadPrefs(tolerancePct: 20));
      expect(o.view.level, OverspeedLevel.none);
    }
    final est = RoadAheadEngine()..matcher.addCell(cell());
    for (var i = 0; i < 6; i++) {
      final o = est.onFix(lat: 12.9010 + i * 0.0001, lng: 77.6, speedKmh: 80, nowMs: i * 1000, headingDeg: 0);
      expect(o.overspeed.speak, isFalse);
      if (i > 3) expect(o.view.level, OverspeedLevel.strong);
    }
    final off = RoadAheadEngine()..matcher.addCell(cell(ms: '40'));
    for (var i = 0; i < 6; i++) {
      final o = off.onFix(lat: 12.9010 + i * 0.0001, lng: 77.6, speedKmh: 80, nowMs: i * 1000, headingDeg: 0, prefs: const RoadAheadPrefs(overspeedWarning: false));
      expect((o.overspeed.speak, o.view.level, o.view.limit!.kmh), (false, OverspeedLevel.none, 40));
    }
  });

  test('school next to a road with a tagged limit: no tolerance, in school hours only; not for an estimate', () {
    final z = [
      [1290150, 7760020, 's']
    ];
    final e = RoadAheadEngine()..matcher.addCell(cell(ms: '40', z: z));
    final o = e.onFix(lat: 12.9015, lng: 77.6, speedKmh: 43, nowMs: 0, headingDeg: 0);
    expect((o.view.limit!.school, o.view.level), (true, OverspeedLevel.over));
    final night = e.onFix(lat: 12.9016, lng: 77.6, speedKmh: 43, nowMs: 1000, headingDeg: 0, schoolHours: false);
    expect((night.view.limit!.school, night.view.level), (false, OverspeedLevel.none));
    final est = RoadAheadEngine()..matcher.addCell(cell(z: z));
    expect(est.onFix(lat: 12.9015, lng: 77.6, speedKmh: 43, nowMs: 0, headingDeg: 0).view.limit!.zone, isFalse);
  });

  test('the view only changes when something visible changes (the chips repaint only then)', () {
    final e = RoadAheadEngine()..matcher.addCell(cell(ms: '60'));
    final a = e.onFix(lat: 12.9010, lng: 77.6, speedKmh: 40, nowMs: 0, headingDeg: 0).view;
    final b = e.onFix(lat: 12.9011, lng: 77.6, speedKmh: 41, nowMs: 1000, headingDeg: 0).view;
    expect(a == b, isTrue);
    expect(a.hashCode, b.hashCode);
    final c = e.onFix(lat: 12.9012, lng: 77.6, speedKmh: 80, nowMs: 2000, headingDeg: 0).view;
    expect(a == c, isFalse);
  });
}
