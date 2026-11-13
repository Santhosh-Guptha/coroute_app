import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/mesh/mesh_chain_keeper.dart';
import 'package:coroute_app/domain/mesh/mesh_neighbors.dart';

// Round 10 offline link: chain-keeper prediction, who is warned, rate limits and emergency silence
// (pure Dart: tool/pure_dart_test/run.sh test/mesh_chain_keeper_test.dart).
const double mPerDegLng = 111320 * 0.9563; // at 17 degrees latitude

ChainRider at(int id, double xM, {bool lead = false}) => ChainRider(id: id, lat: 17.0, lng: 78.0 + xM / mPerDegLng, lead: lead);

void main() {
  test('time to break from the RSSI trend and from the growing gap (the earlier one counts)', () {
    expect(ChainKeeper.secondsToBreak(rssi: -90, rssiSlope: -0.5, breakRssi: -100, rangeM: 450), closeTo(20, 0.01));
    expect(ChainKeeper.secondsToBreak(rssi: -90, rssiSlope: 0.2, breakRssi: -100, rangeM: 450), isNull);
    expect(ChainKeeper.secondsToBreak(rssi: -90, rssiSlope: -0.1, breakRssi: -100, gapM: 400, gapRateMps: 5, rangeM: 450), closeTo(10, 0.01));
  });

  test('convoy order: front to back from the lead (or along the mean heading without one)', () {
    final o = convoyOrder([at(3, -400), at(1, 0, lead: true), at(2, -150)]);
    expect(o.map((r) => r.id), [1, 2, 3]);
    final noLead = convoyOrder([at(3, -400), at(1, 0), at(2, -150)], meanHeadingDeg: 90);
    expect(noLead.map((r) => r.id), [1, 2, 3]);
  });

  ({ChainAdvice? advice, int t}) stretch({bool emergency = false, ChainKeeper? keeper, int start = 0, int myId = 2}) {
    final k = keeper ?? ChainKeeper();
    final table = MeshNeighborTable();
    ChainAdvice? out;
    var t = start;
    // Rider 3 (behind me) drifts back 5 m/s; RSSI falls 0.8 dB/s from -85 dBm.
    for (var i = 0; i <= 12; i++) {
      t = start + i * 1000;
      table.noteHeard(3, (-85 - i * 0.8).round(), t);
      final order = [at(1, 300, lead: true), at(2, 0), at(3, -250.0 - i * 5)];
      out ??= k.evaluate(nowMs: t, myId: myId, order: order, table: table, coded: true, emergency: emergency);
    }
    return (advice: out, t: t);
  }

  test('the rider in front of a stretching gap is told to ease off, and the lead gets a note about them', () {
    final r = stretch();
    expect(r.advice, isNotNull);
    expect(r.advice!.speech, 'Signal chain stretching, ease off a little.');
    expect(r.advice!.leadSubject, 2);
    expect(r.advice!.secondsToBreak, lessThanOrEqualTo(25));
    final lead = ChainKeeper().leadNote(nowMs: 0, subject: 2, name: 'Ravi', emergency: false)!;
    expect(lead.speech, 'Group link stretched behind Ravi, slow down.');
  });

  test('no warning without a trend, for a rider who is not my direct link, or during an emergency', () {
    final k = ChainKeeper();
    final table = MeshNeighborTable();
    for (var i = 0; i <= 12; i++) {
      table.noteHeard(3, -96, i * 1000); // weak but steady
      expect(k.evaluate(nowMs: i * 1000, myId: 2, order: [at(1, 300, lead: true), at(2, 0), at(3, -380)], table: table, coded: true, emergency: false), isNull);
    }
    expect(stretch(emergency: true).advice, isNull, reason: 'never over an SOS or a crash alarm');
    expect(stretch(myId: 3).advice, isNull, reason: 'the last rider has nobody behind');
  });

  test('rate limited: one warning per gap every 2 minutes, lead notes per rider every 90 s', () {
    final k = ChainKeeper();
    expect(stretch(keeper: k).advice, isNotNull);
    expect(stretch(keeper: k, start: 30000).advice, isNull);
    expect(stretch(keeper: k, start: 130000).advice, isNotNull);
    final lead = ChainKeeper();
    expect(lead.leadNote(nowMs: 0, subject: 2, name: 'Ravi', emergency: false), isNotNull);
    expect(lead.leadNote(nowMs: 60000, subject: 2, name: 'Ravi', emergency: false), isNull);
    expect(lead.leadNote(nowMs: 60000, subject: 5, name: 'Ann', emergency: false), isNotNull);
    expect(lead.leadNote(nowMs: 100000, subject: 2, name: 'Ravi', emergency: true), isNull);
  });
}
