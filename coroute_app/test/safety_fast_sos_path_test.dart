// Round 7 faster SOS: the position rule of the SOS path (lib/domain/safety/sos_fast_path.dart).
// Measured here: time from the hold completing to the send call, before (3.55 rule) and after.
//   DART=/opt/dartpkg/bin/dart tool/pure_dart_test/run.sh test/safety_fast_sos_path_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/safety/sos_fast_path.dart';

Future<SosPosition?> after(int ms, [SosPosition? p]) => Future<SosPosition?>.delayed(Duration(milliseconds: ms), () => p);

/// The 3.55 rule, for the before / after comparison: the rider record, else a fresh fix (5 s).
Future<int> before355({required SosPosition? riderRecord, required Future<SosPosition?> Function() current, required void Function(double, double) send}) async {
  final sw = Stopwatch()..start();
  var lat = riderRecord?.lat ?? 0.0, lng = riderRecord?.lng ?? 0.0;
  if (lat == 0.0 && lng == 0.0) {
    final p = await current().timeout(const Duration(seconds: 5), onTimeout: () => null);
    lat = p?.lat ?? 0.0;
    lng = p?.lng ?? 0.0;
  }
  send(lat, lng);
  return sw.elapsedMilliseconds;
}

void main() {
  test('a position in memory: the SOS is sent in the same call, before any await', () {
    final sent = <(double, double)>[];
    var gpsAsked = 0;
    final f = SosFastPath.run(
      cachedSources: [() => null, () => (lat: 12.9, lng: 77.6, source: 'safety_fix')],
      lastKnown: () {
        gpsAsked++;
        return after(1);
      },
      current: () {
        gpsAsked++;
        return after(1);
      },
      send: (a, b) => sent.add((a, b)),
    );
    // No await yet: already sent.
    expect(sent, [(12.9, 77.6)]);
    expect(gpsAsked, 0);
    return f.then((t) {
      expect((t.source, t.hadPosition), ('safety_fix', true));
      expect(t.waitedMs, lessThan(5));
    });
  });

  test('sources are tried in order; 0,0, NaN, out-of-range and throwing sources are skipped', () {
    expect(SosFastPath.usable(0, 0), isFalse);
    expect(SosFastPath.usable(double.nan, 1), isFalse);
    expect(SosFastPath.usable(91, 1), isFalse);
    expect(SosFastPath.usable(0, 77.5), isTrue);
    final p = SosFastPath.cached([
      () => (lat: 0.0, lng: 0.0, source: 'rider'),
      () => throw StateError('gone'),
      () => (lat: 13.0, lng: 77.0, source: 'safety_fix'),
      () => (lat: 14.0, lng: 78.0, source: 'later'),
    ]);
    expect(p!.source, 'safety_fix');
    expect(SosFastPath.cached([() => null]), isNull);
  });

  test('BEFORE / AFTER, no fix in the rider record but the safety service has one: 5 s wait -> none', () async {
    final sentBefore = <(double, double)>[], sentAfter = <(double, double)>[];
    // GPS is slow to answer (800 ms here; up to 5 s on a phone).
    final beforeMs = await before355(riderRecord: null, current: () => after(800, (lat: 12.9, lng: 77.6, source: 'gps')), send: (a, b) => sentBefore.add((a, b)));
    final t = await SosFastPath.run(
      cachedSources: [() => null, () => (lat: 12.9, lng: 77.6, source: 'safety_fix')],
      lastKnown: () => after(50),
      current: () => after(800, (lat: 12.9, lng: 77.6, source: 'gps')),
      send: (a, b) => sentAfter.add((a, b)),
    );
    expect(beforeMs, greaterThanOrEqualTo(780));
    expect(t.waitedMs, lessThan(10));
    expect(sentAfter, sentBefore, reason: 'the same position, sooner');
  });

  test('BEFORE / AFTER, no position anywhere in memory: the last known position within 300 ms instead of a fresh fix', () async {
    final sent = <(double, double)>[];
    final beforeMs = await before355(riderRecord: null, current: () => after(900, (lat: 12.91, lng: 77.61, source: 'gps')), send: (a, b) {});
    final t = await SosFastPath.run(
      cachedSources: [() => null],
      lastKnown: () => after(40, (lat: 12.9, lng: 77.6, source: 'last_known')),
      current: () => after(900, (lat: 12.91, lng: 77.61, source: 'gps')),
      send: (a, b) => sent.add((a, b)),
    );
    expect(beforeMs, greaterThanOrEqualTo(880));
    expect(t.source, 'last_known');
    expect(t.waitedMs, lessThan(250));
    expect(sent, [(12.9, 77.6)]);
  });

  test('the last known position is slow or missing: a fresh fix, bounded; the SOS always goes out', () async {
    final sent = <(double, double)>[];
    final t = await SosFastPath.run(
      cachedSources: const [],
      lastKnown: () => after(2000, (lat: 1.0, lng: 1.0, source: 'last_known')),
      current: () => after(30, (lat: 12.9, lng: 77.6, source: 'gps')),
      send: (a, b) => sent.add((a, b)),
      quick: const Duration(milliseconds: 60),
    );
    expect(t.source, 'gps');
    expect(t.waitedMs, inInclusiveRange(60, 400));
    final none = await SosFastPath.run(
      cachedSources: const [],
      lastKnown: () => Future<SosPosition?>.error(StateError('no permission')),
      current: () => after(5000),
      send: (a, b) => sent.add((a, b)),
      quick: const Duration(milliseconds: 20),
      slow: const Duration(milliseconds: 80),
    );
    expect((none.source, none.hadPosition), ('none', false));
    expect(none.waitedMs, lessThan(400));
    expect(sent, [(12.9, 77.6), (0.0, 0.0)], reason: 'sent without a position rather than not at all');
  });
}
