import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/mesh/mesh_frame.dart';
import 'package:coroute_app/domain/mesh/mesh_messages.dart';
import 'package:coroute_app/domain/mesh/mesh_node.dart';
import 'package:coroute_app/domain/mesh/mesh_store_forward.dart';

// Round 10 offline link: store-and-forward expiry, latest-only, bounded storage, SOS retry until acknowledged and
// epidemic delivery across a gap (pure Dart: tool/pure_dart_test/run.sh test/mesh_store_forward_test.dart).
StoredFrame sf(String id, MeshClass c, int at, {String? key, bool own = false, String? cid, int size = 60}) =>
    StoredFrame(id: id, cls: c, sealed: Uint8List(size), storedAtMs: at, expiresAtMs: at + storeLifetimeMs(c), origin: 1, key: key, own: own, sosClientId: cid);

void main() {
  test('expiry per class: positions 2 min, alerts 10 min, SOS hours; an unacknowledged own SOS never expires', () {
    final s = StoreForward();
    s.put(sf('p', MeshClass.position, 0), 0);
    s.put(sf('a', MeshClass.alert, 0), 0);
    s.put(sf('s', MeshClass.sos, 0, cid: 'x'), 0);
    s.put(sf('own', MeshClass.sos, 0, own: true, cid: 'mine'), 0);
    s.due(121000, const {});
    expect(s['p'], isNull);
    expect(s['a'], isNotNull);
    s.due(601000, const {});
    expect(s['a'], isNull);
    s.due(7 * 3600 * 1000, const {});
    expect(s['s'], isNull);
    expect(s['own'], isNotNull, reason: 'kept (and resent) until someone acknowledges it');
  });

  test('positions are latest only per rider; an older one arriving late is not kept', () {
    final s = StoreForward();
    s.put(sf('p1', MeshClass.position, 1000, key: 'pos:7'), 1000);
    s.put(sf('p2', MeshClass.position, 3000, key: 'pos:7'), 3000);
    expect(s['p1'], isNull);
    expect(s.put(sf('p0', MeshClass.position, 500, key: 'pos:7'), 3100), isFalse);
    expect(s.length, 1);
  });

  test('own SOS is resent on 2/4/8/15/30 s back-off, with nobody in range, until acknowledged', () {
    final s = StoreForward();
    s.put(sf('sos', MeshClass.sos, 0, own: true, cid: 'c1'), 0);
    s.markSent('sos', const {}, 0);
    final times = <int>[];
    for (var t = 0; t <= 70000; t += 500) {
      if (s.due(t, const {}).isNotEmpty) times.add(t);
    }
    expect(times, [2000, 6000, 14000, 29000, 59000]);
    expect(s.unackedOwnSos.length, 1);
    expect(s.ackSos('c1'), isTrue);
    expect(s.due(200000, const {}), isEmpty);
    expect(s['sos'], isNotNull, reason: 'still carried for riders who have not heard it');
  });

  test('epidemic: stored frames are offered to a NEW neighbour, not again to one that already had them', () {
    final s = StoreForward();
    s.put(sf('a', MeshClass.alert, 0), 0);
    s.markSent('a', {5}, 0);
    expect(s.due(5000, {5}), isEmpty);
    expect(s.due(5000, {5, 6}).map((e) => e.id), ['a']);
    expect(s.due(10000, {5, 6}), isEmpty);
    s.forgetOffers(5);
    expect(s.due(15000, {5, 6}).map((e) => e.id), ['a'], reason: 'rider 5 came back after a gap');
  });

  test('bounded storage evicts chat, then positions, then clips, then alerts - never an SOS for space', () {
    final s = StoreForward(config: const StoreForwardConfig(maxItems: 10, maxBytes: 1 << 20));
    for (var i = 0; i < 6; i++) {
      s.put(sf('sos$i', MeshClass.sos, i, cid: 'c$i'), i);
    }
    s.put(sf('alert', MeshClass.alert, 10), 10);
    s.put(sf('clip', MeshClass.voice, 11), 11);
    s.put(sf('pos', MeshClass.position, 12, key: 'pos:1'), 12);
    s.put(sf('chat', MeshClass.chat, 13), 13);
    s.put(sf('clip2', MeshClass.voice, 14), 14);
    expect(s['chat'], isNull);
    s.put(sf('alert2', MeshClass.alert, 15), 15);
    expect(s['pos'], isNull);
    for (var i = 0; i < 6; i++) {
      expect(s['sos$i'], isNotNull);
    }
    expect(s.length, 10);
  });

  test('SOS across a gap: raised out of range, delivered and acknowledged when a rider comes into range', () {
    var now = 1800000000000;
    final keyring = MeshKeyring(Uint8List.fromList(List.generate(32, (i) => 3 * i)));
    var inRange = false;
    late MeshNodeEngine a, b;
    a = MeshNodeEngine(keyring: keyring, myId: 1, boot: 11, clockMs: () => now, random: math.Random(1), transmit: (bytes, c) {
      if (inRange) b.onRadioFrame(bytes, rssi: -80);
    });
    b = MeshNodeEngine(keyring: keyring, myId: 2, boot: 22, clockMs: () => now, random: math.Random(2), transmit: (bytes, c) {
      if (inRange) a.onRadioFrame(bytes, rssi: -80);
    });
    final got = <String>[];
    b.onSos = (o, s, f) => got.add(s.clientId);
    a.sendSos(const MeshSos(clientId: 'gap-sos', alertType: 'CRASH', lat: 1, lng: 2, occurredAtMs: 0));
    for (var i = 0; i < 3000; i++) {
      now += 20;
      if (i == 1500) inRange = true; // 30 s later rider B rounds the bend
      a.tick();
      b.tick();
    }
    expect(got, ['gap-sos']);
    expect(a.store.isAcked('gap-sos'), isTrue, reason: 'B acknowledged it; A stops resending');
    expect(a.store.unackedOwnSos, isEmpty);
  });
}
