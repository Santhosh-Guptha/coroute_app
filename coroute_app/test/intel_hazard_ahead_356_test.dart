import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/intel/geohash.dart';
import 'package:coroute_app/domain/intel/hazard_ahead.dart';

/// Round 4 "Hazard ahead" / "Rough road ahead" / "Twisty section ahead" rules (lib/domain/intel/hazard_ahead.dart):
/// distance window, direction, rate limit, emergency and mute, the offline tile cache, and geohash parity with the
/// gateway (gateway/src/intel/geohash.js).
(double, double) _move(double lat, double lng, double deg, double m) {
  final r = deg * math.pi / 180;
  return (lat + (m * math.cos(r)) / 111320, lng + (m * math.sin(r)) / (111320 * math.cos(lat * math.pi / 180)));
}

void main() {
  const start = (12.95, 77.50);
  final hazardNorth = _move(start.$1, start.$2, 0, 2000);
  final cell = IntelCell(id: 'hz:a', lat: hazardNorth.$1, lng: hazardNorth.$2, kind: 'hard_brake', level: 'high', dirs: const [0]);

  /// Rides north from [start] in 20 m steps; returns the warnings and the distance at which each came.
  List<(AheadWarning, double)> rideNorth(AheadMonitor m, {double metres = 3000, double heading = 0, bool emergency = false}) {
    final out = <(AheadWarning, double)>[];
    for (var d = 0.0; d <= metres; d += 20) {
      final p = _move(start.$1, start.$2, 0, d);
      final w = m.onFix(lat: p.$1, lng: p.$2, headingDeg: heading, speedKmh: 50, emergency: emergency, describe: AheadMonitor.hazard);
      if (w != null) out.add((w, d));
    }
    return out;
  }

  group('hazard ahead', () {
    test('warns once, 300-500 m before the spot, in the direction of travel', () {
      final m = AheadMonitor()..setCells([cell]);
      final got = rideNorth(m);
      expect(got, hasLength(1));
      expect(got.first.$1.distanceM, inInclusiveRange(300, 500));
      expect(got.first.$2, inInclusiveRange(1500, 1700));
      expect(got.first.$1.title, startsWith('Hazard ahead'));
      expect(got.first.$1.speech, contains('Riders brake hard here'));
    });

    test('not for riders going the other way (cell direction) or with the spot behind them', () {
      final m = AheadMonitor()..setCells([cell]);
      expect(rideNorth(m, heading: 180), isEmpty, reason: 'heading south: the spot is behind and the cell is northbound');
      final both = AheadMonitor()..setCells([IntelCell(id: 'hz:b', lat: hazardNorth.$1, lng: hazardNorth.$2, kind: 'crash', dirs: const [4])]);
      expect(rideNorth(both), isEmpty, reason: 'riders there were southbound');
      final any = AheadMonitor()..setCells([IntelCell(id: 'hz:c', lat: hazardNorth.$1, lng: hazardNorth.$2, kind: 'crash')]);
      expect(rideNorth(any).single.$1.speech, contains('Accident-prone spot'), reason: 'no direction known: both ways');
    });

    test('at most one warning per 2 km of riding; rough road one per 5 km', () {
      final cells = [for (var k = 1; k <= 8; k++) IntelCell(id: 'hz:$k', lat: _move(start.$1, start.$2, 0, k * 700.0).$1, lng: start.$2)];
      final m = AheadMonitor(spacingM: 2000)..setCells(cells);
      final got = rideNorth(m, metres: 6000);
      expect(got.length, inInclusiveRange(2, 3));
      for (var i = 1; i < got.length; i++) {
        expect(got[i].$2 - got[i - 1].$2, greaterThanOrEqualTo(2000));
      }
      final r = AheadMonitor(spacingM: 5000)..setCells(cells);
      final rr = rideNorth(r, metres: 6000);
      expect(rr.length, inInclusiveRange(1, 2));
      if (rr.length == 2) expect(rr[1].$2 - rr[0].$2, greaterThanOrEqualTo(5000));
      expect(rideNorth(AheadMonitor(spacingM: 5000)..setCells(cells), metres: 4000), hasLength(1));
    });

    test('never during an SOS / crash alarm, nothing when muted, nothing when slow or heading unknown', () {
      expect(rideNorth(AheadMonitor()..setCells([cell]), emergency: true), isEmpty);
      expect(rideNorth(AheadMonitor()..setCells([cell])..muted = true), isEmpty);
      final m = AheadMonitor()..setCells([cell]);
      final p = _move(start.$1, start.$2, 0, 1600);
      expect(m.onFix(lat: p.$1, lng: p.$2, headingDeg: 0, speedKmh: 8, emergency: false, describe: AheadMonitor.hazard), isNull);
      expect(m.onFix(lat: p.$1, lng: p.$2, headingDeg: null, speedKmh: 50, emergency: false, describe: AheadMonitor.hazard), isNull);
    });
  });

  group('offline cache', () {
    test('tiles survive a JSON round trip and expire after 14 days', () {
      final c = IntelTileCache()..put('tdr1', [cell], 1000);
      final back = IntelTileCache.fromJson(c.toJson());
      expect(back.cells(2000).single.id, 'hz:a');
      expect(back.cells(2000).single.dirs, [0]);
      expect(back.cells(1000 + const Duration(days: 15).inMilliseconds), isEmpty);
      expect(back.fresh('tdr1', 1000 + const Duration(hours: 13).inMilliseconds), isFalse, reason: 'refetched after 12 h when online');
      final m = AheadMonitor()..setCells(back.cells(2000));
      expect(rideNorth(m), hasLength(1), reason: 'works from the cache with no network');
    });

    test('the cache keeps at most maxTiles', () {
      final c = IntelTileCache(maxTiles: 3);
      for (var i = 0; i < 5; i++) {
        c.put('t$i', const [], i);
      }
      expect(c.tileCount, 3);
    });
  });

  group('twisty section', () {
    test('cells along the route merge into sections; announced once, 1 km before', () {
      final cells = [for (var a = 10000.0; a <= 18000; a += 800) (alongM: a, ghat: a > 14000)];
      final s = TwistyAhead.sectionsOf(cells);
      expect(s, hasLength(1));
      expect(s.first.lengthKm, closeTo(9, 0.1));
      expect(s.first.ghat, isTrue);
      final t = TwistyAhead()..setSections(s);
      expect(t.onAlong(8000, emergency: false), isNull);
      expect(t.onAlong(8600, emergency: true), isNull, reason: 'not over an emergency');
      final hit = t.onAlong(8700, emergency: false);
      expect(hit, isNotNull);
      expect(TwistyAhead.title(hit!), 'Ghat section next 9 km');
      expect(t.onAlong(9000, emergency: false), isNull, reason: 'once');
      expect(TwistyAhead.sectionsOf([(alongM: 5000, ghat: false)]), isEmpty, reason: 'one cell is not a section');
    });
  });

  group('geohash', () {
    test('same cell ids as the gateway', () {
      expect(Geohash.encode(12.9716, 77.5946, 7), 'tdr1v9q');
      expect(Geohash.encode(28.6139, 77.209, 4), 'ttnf');
      expect(Geohash.encode(57.64911, 10.40744, 11), 'u4pruydqqvj');
      final b = Geohash.bbox('tdr1v9q')!;
      expect(12.9716, inInclusiveRange(b.$1, b.$3));
      expect(77.5946, inInclusiveRange(b.$2, b.$4));
      expect(Geohash.encode(91, 0), isNull);
    });

    test('tiles along a long route cover every tile it crosses (prefetch)', () {
      final tiles = Geohash.tilesAlong([(12.9, 77.5), (13.9, 77.5)]);
      expect(tiles.length, greaterThanOrEqualTo(6));
      expect(tiles, contains(Geohash.encode(13.4, 77.5, 4)));
    });
  });
}
