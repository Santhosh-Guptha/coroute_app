import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/services/pos2_codec.dart';

// Round 8 'pos2' codec (pure Dart: tool/pure_dart_test/run.sh test/rt8_pos2_codec_test.dart). The gateway side is
// gateway/src/pos2.js; the field names and scales here must match it (gateway/test/rt8_pos2.test.js).
void main() {
  const now = 1800000000000;

  test('P2 frame: short keys, integers, ~65 bytes for a typical fix', () {
    final c = Pos2Codec();
    final f = c.encode(lat: 17.385044, lng: 78.486671, speedKmh: 58.3, heading: 90.4, nowMs: now, batteryLevel: 64);
    expect(f['t'], 'P2');
    expect(f['q'], 1);
    expect(f['a'], 1738504);
    expect(f['o'], 7848667);
    expect(f['v'], 162); // 58.3 km/h = 16.2 m/s = 162 dm/s
    expect(f['h'], 90);
    expect(f['b'], 64);
    expect(f.containsKey('c'), isFalse);
    expect(f.containsKey('sr'), isFalse);
    expect(jsonEncode(f).length, lessThan(80));
    expect(c.encode(lat: 1, lng: 1, speedKmh: 0, heading: -10, nowMs: now)['q'], 2);
    expect(c.encode(lat: 1, lng: 1, speedKmh: 0, heading: -10, nowMs: now)['h'], 350);
  });

  test('P2 optional fields: status, stop time in seconds, fuel, fatigue, charging', () {
    final f = Pos2Codec().encode(
      lat: 17.4,
      lng: 78.4,
      speedKmh: 500,
      heading: 0,
      nowMs: now,
      batteryLevel: 120,
      isCharging: true,
      statusReason: 'FUEL',
      statusMessage: 'Filling up',
      stoppedSince: now - 42000,
      fuelEstimate: {'usableKm': 120.7, 'confirmedAt': now - 60000},
      fatigueLevel: 2,
    );
    expect(f['v'], 1000, reason: 'clamped');
    expect(f['b'], 100);
    expect(f['c'], 1);
    expect(f['sr'], 'FUEL');
    expect(f['sm'], 'Filling up');
    expect(f['ss'], 42);
    expect(f['fu'], [120, (now - 60000) ~/ 1000]);
    expect(f['fl'], 2);
  });

  test('RU2 entries merge into the known rider; unknown riders are skipped; name and contacts stay', () {
    final cache = RiderCache();
    cache.putSnapshot({
      'u1': {'userId': 'u1', 'name': 'Asha', 'phone': '+910000000000', 'role': 'LEAD', 'lat': 0.0, 'lng': 0.0},
      'u2': {'userId': 'u2', 'name': 'Ravi', 'role': 'PACK'},
    });
    final frame = jsonDecode(
        '{"type":"RU2","ts":$now,"r":[{"u":"u1","a":1738504,"o":7848667,"v":162,"h":90,"b":64,"c":1,"sr":"FUEL","ss":42,"t":${now - 400},"fu":[120,1799999940],"fl":2},'
        '{"u":"zz","a":1,"o":1,"v":0,"h":0,"b":1,"t":$now}]}') as Map<String, dynamic>;
    final out = cache.applyRu2(frame);
    expect(out, hasLength(1));
    final r = out.single;
    expect(r['name'], 'Asha');
    expect(r['phone'], '+910000000000');
    expect(r['role'], 'LEAD');
    expect(r['lat'], closeTo(17.385044, 1e-5));
    expect(r['lng'], closeTo(78.486671, 1e-5));
    expect(r['speedKmh'], closeTo(58.3, 0.1));
    expect(r['heading'], 90.0);
    expect(r['batteryLevel'], 64);
    expect(r['isCharging'], isTrue);
    expect(r['statusReason'], 'FUEL');
    expect(r['statusMessage'], '');
    expect(r['stoppedSince'], now - 42000);
    expect(r['lastSeenEpochMs'], now - 400);
    expect((r['fuelEstimate'] as Map)['usableKm'], 120);
    expect(r['fatigueLevel'], 2);
    expect(cache['u1']!['lat'], closeTo(17.385044, 1e-5), reason: 'the cache keeps the merged rider');
  });

  test('cache follows full updates and leaves; a list snapshot works too', () {
    final cache = RiderCache()..putSnapshot([
        {'userId': 'a', 'name': 'A'},
      ]);
    expect(cache.knows('a'), isTrue);
    cache.put({'userId': 'b', 'name': 'B'});
    expect(cache.length, 2);
    cache.remove('a');
    expect(cache.knows('a'), isFalse);
    expect(RiderCache.applyEntry({'userId': 'b'}, {'u': 'b', 'a': 'x'}, now), isNull, reason: 'malformed entry');
    cache.clear();
    expect(cache.length, 0);
  });

  test('round trip with the gateway scales: P2 out, RU2 in', () {
    final f = Pos2Codec().encode(lat: 12.971599, lng: 77.594566, speedKmh: 36, heading: 271, nowMs: now, batteryLevel: 50);
    final entry = {'u': 'x', 'a': f['a'], 'o': f['o'], 'v': f['v'], 'h': f['h'], 'b': f['b'], 't': now};
    final r = RiderCache.applyEntry({'userId': 'x', 'name': 'X'}, entry, now)!;
    expect(r['lat'], closeTo(12.971599, 1e-5));
    expect(r['lng'], closeTo(77.594566, 1e-5));
    expect(r['speedKmh'], 36.0);
    expect(r['heading'], 271.0);
  });
}
