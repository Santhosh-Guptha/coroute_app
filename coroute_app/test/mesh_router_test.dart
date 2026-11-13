import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/mesh/mesh_frame.dart';
import 'package:coroute_app/domain/mesh/mesh_messages.dart';
import 'package:coroute_app/domain/mesh/mesh_neighbors.dart';
import 'package:coroute_app/domain/mesh/mesh_router.dart';

// Round 10 offline link: flooding, dedup, hop limit, relay suppression, priority and starvation prevention
// (pure Dart: tool/pure_dart_test/run.sh test/mesh_router_test.dart).
final keyring = MeshKeyring(Uint8List.fromList(List.generate(32, (i) => i)));

class Net {
  Net(int n, {this.rssi = -80, MeshRouterConfig config = const MeshRouterConfig()}) {
    for (var i = 0; i < n; i++) {
      final id = 100 + i;
      nodes.add(MeshRouter(
        codec: MeshFrameCodec(keyring),
        myId: id,
        boot: 1,
        clockMs: () => now,
        config: config,
        random: math.Random(i),
        transmit: (b, c) {
          sent.add((id, c, b.length));
          for (final to in links[id] ?? const <int>{}) {
            air.add((now + 3, to, b));
          }
        },
        onDeliver: (f, m) => delivered.putIfAbsent(id, () => []).add(f),
      ));
    }
  }

  int now = 1800000000000;
  final int rssi;
  final List<MeshRouter> nodes = [];
  final Map<int, Set<int>> links = {};
  final List<(int, int, Uint8List)> air = [];
  final List<(int, MeshClass, int)> sent = [];
  final Map<int, List<MeshFrame>> delivered = {};

  MeshRouter node(int id) => nodes[id - 100];

  void link(int a, int b) {
    links.putIfAbsent(a, () => {}).add(b);
    links.putIfAbsent(b, () => {}).add(a);
  }

  void line() {
    for (var i = 0; i < nodes.length - 1; i++) {
      link(100 + i, 101 + i);
    }
  }

  void full() {
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        link(100 + i, 100 + j);
      }
    }
  }

  void run(int ms) {
    for (var t = 0; t < ms; t += 5) {
      now += 5;
      final due = air.where((a) => a.$1 <= now).toList();
      air.removeWhere((a) => a.$1 <= now);
      for (final d in due) {
        node(d.$2).receive(d.$3, rssi: rssi);
      }
      for (final n in nodes) {
        n.tick();
      }
    }
  }

  int got(int id, MeshClass c) => (delivered[id] ?? const []).where((f) => f.cls == c).length;
}

Uint8List pos(double lat) => MeshPos(lat: lat, lng: 78, speedKmh: 50, heading: 90).encode();

void main() {
  test('a frame floods down a line of riders, each delivers it once, hops counted', () {
    final net = Net(6)..line();
    net.node(100).originate(pos(17), MeshClass.position);
    net.run(2000);
    for (var id = 101; id <= 105; id++) {
      expect(net.got(id, MeshClass.position), 1, reason: 'rider $id');
    }
    expect(net.delivered[105]!.single.hops, 4);
    expect(net.got(100, MeshClass.position), 0, reason: 'never delivered back to its origin');
  });

  test('hop limit: a TTL of 3 reaches 3 hops and stops', () {
    final net = Net(6)..line();
    net.node(100).originate(pos(17), MeshClass.position, ttl: 3);
    net.run(2000);
    expect([for (var id = 101; id <= 105; id++) net.got(id, MeshClass.position)], [1, 1, 1, 0, 0]);
    expect(net.node(103).stats.ttlExpired, 1);
  });

  test('dense group: counter-based suppression keeps relays far below one per rider; SOS is never suppressed', () {
    final net = Net(12)..full();
    net.node(100).originate(pos(17), MeshClass.position);
    net.run(2000);
    final posRelays = net.nodes.fold<int>(0, (a, n) => a + n.stats.relayed);
    expect(posRelays, lessThanOrEqualTo(4), reason: 'everyone hears everyone: a couple of relays are enough');
    for (var id = 101; id < 112; id++) {
      expect(net.got(id, MeshClass.position), 1);
    }
    final sosNet = Net(12)..full();
    sosNet.node(100).originate(const MeshSos(clientId: 'c', alertType: 'CRASH', lat: 1, lng: 2, occurredAtMs: 0).encode(), MeshClass.sos);
    sosNet.run(2000);
    expect(sosNet.nodes.fold<int>(0, (a, n) => a + n.stats.relayed), 11, reason: 'every rider relays an SOS once');
  });

  test('progress suppression: a rider the flood has already passed does not relay', () {
    final net = Net(3, rssi: -60);
    net.link(100, 101);
    net.link(101, 102);
    net.link(100, 102);
    // Origin at 0 m, rider 101 at 100 m, rider 102 at 600 m - the relay from 102 is already past 101.
    final where = {100: (lat: 17.0, lng: 78.0), 101: (lat: 17.0, lng: 78.00094), 102: (lat: 17.0, lng: 78.0056)};
    for (final n in net.nodes) {
      n.myPosition = () => where[n.myId];
      n.positionOf = (id) => where[id];
    }
    net.node(100).originate(pos(17), MeshClass.position);
    // 102 hears the origin weakly in reality; here: let 102 relay first by giving it a head start.
    net.run(20);
    final relayed = MeshFrameCodec.rewriteRelay(MeshFrameCodec(keyring).seal(MeshFrame(cls: MeshClass.alert, origin: 100, boot: 1, seq: 77, originTimeSec: net.now ~/ 1000, initialTtl: 4, ttl: 4, payload: const MeshAlert(code: 2).encode())),
        ttl: 3, relay: 102, relayLat: 17.0, relayLng: 78.0056);
    net.node(101).receive(relayed, rssi: -95);
    net.run(500);
    expect(net.node(101).stats.suppressed, greaterThanOrEqualTo(1));
  });

  test('priority + budgets: a flood of voice never delays an SOS; positions keep flowing; late live voice is dropped', () {
    final net = Net(2, config: const MeshRouterConfig(linkBytesPerSec: 4000))..link(100, 101);
    final a = net.node(100);
    // 2 s of queued live voice (8 KB at 4 KB/s airtime, voice share 50%: far more than fits).
    for (var i = 0; i < 100; i++) {
      a.originate(MeshVoice(streamId: 1, frameSeq: i, codec: 1, sampleRate: 16000, payload: Uint8List(60)).encode(), MeshClass.voice, live: true);
    }
    a.originate(pos(17), MeshClass.position);
    a.originate(const MeshSos(clientId: 's', alertType: 'CRASH', lat: 1, lng: 2, occurredAtMs: 0).encode(), MeshClass.sos);
    net.run(10);
    // The SOS went out in the very first tick, ahead of 100 queued voice frames.
    expect(net.sent.first.$2, MeshClass.sos);
    expect(net.sent.take(2).map((e) => e.$2), containsAll([MeshClass.sos, MeshClass.position]));
    net.run(2000);
    expect(net.got(101, MeshClass.sos), 1);
    expect(net.got(101, MeshClass.position), 1);
    expect(a.stats.droppedLate, greaterThan(50), reason: 'live audio older than 300 ms is useless and dropped');
    final voiceBytes = a.stats.txBytesByClass[MeshClass.voice]!;
    expect(voiceBytes, lessThanOrEqualTo(4000 * 0.5 * 2.1 + 2000), reason: 'voice stays inside its share of the airtime');
  });

  test('positions are latest-only in the queue (a backlog never sends stale fixes)', () {
    final net = Net(2, config: const MeshRouterConfig(linkBytesPerSec: 200))..link(100, 101);
    final a = net.node(100);
    net.run(3000); // drain the initial burst allowance
    for (var i = 0; i < 5; i++) {
      a.originate(pos(17 + i / 1000), MeshClass.position);
    }
    expect(a.queued(MeshClass.position), lessThanOrEqualTo(1));
  });

  test('neighbour table: new links, RSSI trend, hops', () {
    final t = MeshNeighborTable();
    expect(t.noteHeard(5, -70, 0), isTrue);
    expect(t.noteHeard(5, -71, 1000), isFalse);
    for (var i = 2; i <= 10; i++) {
      t.noteHeard(5, -70 - i * 2, i * 1000);
    }
    expect(t.rssiSlope(5, 10000), closeTo(-2.0, 0.3));
    expect(t.hopsTo(5, 10000), 0);
    expect(t.noteHeard(5, -80, 25000), isTrue, reason: 'back after a gap counts as a new link');
    t.noteFix(9, const MeshRiderFix(lat: 1, lng: 2, speedKmh: 0, heading: 0, atMs: 25000, hops: 3));
    expect(t.hopsTo(9, 26000), 3);
    t.noteFix(9, const MeshRiderFix(lat: 9, lng: 9, speedKmh: 0, heading: 0, atMs: 20000, hops: 1));
    expect(t.fixes[9]!.lat, 1, reason: 'an older (stored) fix never replaces a newer one');
  });
}
