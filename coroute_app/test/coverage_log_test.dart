import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/safety/coverage_log.dart';

/// 3.55 no-signal ahead: coverage log cells and the "dead stretch ahead" decision.
void main() {
  // A road north along lng 77.0 from lat 30.00 to 30.30 (~33 km); points every ~1.1 km.
  final line = [for (var i = 0; i <= 30; i++) (30.0 + i * 0.01, 77.0)];
  const t0 = 1700000000000;

  /// One ride along the road: offline between [offFrom] and [offTo] (lat), online elsewhere.
  void ride(CoverageLog log, String id, double offFrom, double offTo) {
    var t = t0;
    for (var lat = 30.0; lat <= 30.3; lat += 0.001) {
      log.record(lat: lat, lng: 77.0, online: !(lat >= offFrom && lat <= offTo), rideId: id, nowMs: t += 5000);
    }
  }

  test('cells are about 500 m and one pass counts once per ride', () {
    expect(CoverageLog.cellKey(30.0, 77.0), CoverageLog.cellKey(30.002, 77.002));
    expect(CoverageLog.cellKey(30.0, 77.0), isNot(CoverageLog.cellKey(30.006, 77.0)));
    final log = CoverageLog();
    for (var i = 0; i < 10; i++) {
      log.record(lat: 30.0001, lng: 77.0001, online: true, rideId: 'r1', nowMs: t0 + i);
    }
    final c = log.cell(CoverageLog.cellKey(30.0001, 77.0001))!;
    expect(c.online, 1);
    // The signal drops inside the cell during the same pass: an offline pass.
    log.record(lat: 30.0001, lng: 77.0001, online: false, rideId: 'r1', nowMs: t0 + 20);
    expect(c.online, 0);
    expect(c.offline, 1);
    log.record(lat: 30.0001, lng: 77.0001, online: false, rideId: 'r2', nowMs: t0 + 30);
    expect(c.offline, 2);
    expect(c.dead(2), isTrue);
  });

  test('a stretch offline on 2 past rides is found 2 to 5 km ahead, with its length', () {
    final log = CoverageLog();
    ride(log, 'a', 30.15, 30.20);
    ride(log, 'b', 30.15, 30.20);
    // Rider at lat 30.115 (~3.9 km before the stretch).
    final along = (30.115 - 30.0) * 111195;
    final s = log.deadAhead(line: line, myAlongM: along);
    expect(s, isNotNull);
    expect(s!.startAheadM, inInclusiveRange(3000, 4600));
    expect(s.lengthM, inInclusiveRange(4500, 6500));
    // Too close (stretch starts 1 km ahead) or too far (8 km): nothing (the 2-5 km window).
    expect(log.deadAhead(line: line, myAlongM: (30.14 - 30.0) * 111195), isNull);
    expect(log.deadAhead(line: line, myAlongM: (30.08 - 30.0) * 111195), isNull);
  });

  test('one offline pass is not enough; mostly online cells are not dead', () {
    final log = CoverageLog();
    ride(log, 'a', 30.15, 30.20);
    expect(log.deadAhead(line: line, myAlongM: (30.115 - 30.0) * 111195), isNull);
    ride(log, 'b', 30.15, 30.20);
    ride(log, 'c', 0, 0);
    ride(log, 'd', 0, 0);
    ride(log, 'e', 0, 0);
    expect(log.deadAhead(line: line, myAlongM: (30.115 - 30.0) * 111195), isNull, reason: 'signal there on most rides');
  });

  test('at most maxCells, least recently passed dropped; saved and restored', () {
    final log = CoverageLog(maxCells: 50);
    for (var i = 0; i < 80; i++) {
      log.record(lat: 20.0 + i * 0.01, lng: 75.0, online: i.isEven, rideId: 'r', nowMs: t0 + i * 60000);
    }
    expect(log.length, 50);
    expect(log.cell(CoverageLog.cellKey(20.0, 75.0)), isNull, reason: 'oldest evicted');
    expect(log.cell(CoverageLog.cellKey(20.79, 75.0)), isNotNull);
    final back = CoverageLog.fromJson(log.toJson(), maxCells: 50);
    expect(back.length, 50);
    expect(back.cell(CoverageLog.cellKey(20.79, 75.0))!.offline, log.cell(CoverageLog.cellKey(20.79, 75.0))!.offline);
    expect(CoverageLog.fromJson('garbage').length, 0);
  });
}
