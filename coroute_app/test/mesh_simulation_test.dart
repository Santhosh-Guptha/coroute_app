// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/mesh/mesh_sim.dart';

// Round 10 offline link: 10 simulated riders over ~1 km with random gaps, running the real MeshNodeEngine (router,
// store-and-forward, SOS acknowledgements, clip repair) over a simulated radio (lib/domain/mesh/mesh_sim.dart).
// Pure Dart: tool/pure_dart_test/run.sh test/mesh_simulation_test.dart (about 15 s). The full table with more seeds and
// harsher scenarios is in docs/quality/ROUND10_MESH_NOTES.md.
void printSim(String name, MeshSimResult r) {
  print('[$name] SOS ${r.sos.fmt('ms')} | SOS ack ${r.sosAck.fmt('ms')} | positions ${r.positions.fmt('ms')} | '
      'clips ${r.clips.fmt('ms')} | live voice ${r.liveVoice.fmt('ms')} | max hops ${r.maxHops} | busiest airtime ${(r.airtimeShareMax * 100).toStringAsFixed(0)} %');
}

void main() {
  test('Coded PHY, 10 riders, 1 km, random gaps: SOS always arrives, positions / clips / live voice measured', () {
    final total = MeshSimResult();
    for (final seed in [1, 2]) {
      total.merge(MeshSim(MeshSimConfig(seed: seed)).run());
    }
    printSim('coded', total);
    expect(total.sos.deliveryRate, greaterThanOrEqualTo(0.99), reason: 'SOS reaches every rider');
    expect(total.sos.pct(0.5), lessThan(500));
    expect(total.sosAck.deliveryRate, 1.0, reason: 'every SOS origin learns someone got it');
    expect(total.positions.deliveryRate, greaterThan(0.9));
    expect(total.clips.deliveryRate, greaterThan(0.95));
    expect(total.liveVoice.deliveryRate, greaterThan(0.8));
    expect(total.liveVoice.pct(0.95), lessThanOrEqualTo(450));
    expect(total.maxHops, greaterThanOrEqualTo(3), reason: '1 km needs multi-hop relays');
    expect(total.airtimeShareMax, lessThan(0.5), reason: 'no phone needs more than half its airtime');
  });

  test('harsh ride (4x the gaps, 20 % collision loss): SOS still reaches everyone through store-and-forward', () {
    final r = MeshSim(const MeshSimConfig(seed: 7, gapEventsPerMin: 0.6, collisionLoss: 0.2, durationMs: 400000, sosAtMs: [60000, 160000, 260000], clipAtMs: [100000, 220000])).run();
    printSim('harsh', r);
    expect(r.sos.deliveryRate, greaterThanOrEqualTo(0.99));
    expect(r.sosAck.deliveryRate, 1.0);
  });
}
