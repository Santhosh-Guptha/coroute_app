import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/ui/ride_alert.dart';
import 'package:coroute_app/data/services/road_care_service.dart';
import 'package:coroute_app/domain/safety/speed_limit_advisor.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

const double _lat0 = 17.0, _lng0 = 78.0;
(double, double) _ll(double x, double y) =>
    (_lat0 + y / 111320.0, _lng0 + x / (111320.0 * math.cos(_lat0 * math.pi / 180)));

/// North 800 m, then a right S-bend (r 60 m), then on.
List<(double, double)> _sBend() {
  final pts = <(double, double)>[];
  var x = 0.0, y = 0.0, h = 0.0;
  void add() => pts.add(_ll(x, y));
  add();
  for (var i = 0; i < 40; i++) {
    y += 20;
    add();
  }
  for (final turn in [5.0, -5.0]) {
    for (var i = 0; i < 18; i++) {
      final chord = 2 * 60 * math.sin(2.5 * math.pi / 180);
      final m = h + turn / 2;
      x += chord * math.sin(m * math.pi / 180);
      y += chord * math.cos(m * math.pi / 180);
      h += turn;
      add();
    }
  }
  for (var i = 0; i < 20; i++) {
    y += 20;
    add();
  }
  return pts;
}

void main() {
  RoadCareService make({bool emergency = false, Set<String> off = const {}, required List<(double, double)> line, required List<int> changes}) {
    var t = 0;
    return RoadCareService(
      voice: null,
      emergency: () => emergency,
      featureOn: (id) => !off.contains(id),
      convoyLine: () => line,
      onChanged: () => changes.add(1),
      now: () => t,
    );
  }

  test('a sharp bend ahead shows one road care notice at riding speed', () {
    final line = _sBend();
    final changes = <int>[];
    final rc = make(line: line, changes: changes);
    String? title;
    for (var i = 0; i < 40; i++) {
      final (lat, lng) = line[i];
      rc.onFix(TrackPoint(ts: i * 1000, lat: lat, lng: lng, speedKmh: 80, accuracyM: 5), dark: false);
      title ??= rc.notice?.title;
    }
    expect(title, startsWith('Sharp bend'));
  });

  test('silent during an emergency and when switched off', () {
    final line = _sBend();
    for (final rc in [
      make(line: line, changes: [], emergency: true),
      make(line: line, changes: [], off: {'bendWarning'}),
    ]) {
      for (var i = 0; i < 40; i++) {
        final (lat, lng) = line[i];
        rc.onFix(TrackPoint(ts: i * 1000, lat: lat, lng: lng, speedKmh: 80, accuracyM: 5), dark: false);
        expect(rc.notice, isNull);
      }
    }
  });

  test('no speed limit data: never a limit notice; night flag raises alert contrast', () {
    final rc = make(line: const [], changes: [])
      ..roadData = () => (roads: const <RoadLimitPoint>[], zones: const <SpeedZonePoint>[]);
    for (var i = 0; i < 30; i++) {
      rc.onFix(TrackPoint(ts: i * 1000, lat: 17.0 + i * 0.0003, lng: 78.0, speedKmh: 120, accuracyM: 5), dark: i > 10);
      expect(rc.notice?.key.startsWith('ROADCARE:LIMIT') ?? false, isFalse);
    }
    expect(rc.isNight, isTrue);
    expect(RideAlert.nightContrast, isTrue);
    expect(rc.notice?.title, 'Sun has set');
    rc.reset();
    expect(RideAlert.nightContrast, isFalse);
  });
}
