import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/services/offline_link/mesh_bridge_client.dart';
import 'package:coroute_app/domain/mesh/mesh_frame.dart';
import 'package:coroute_app/domain/mesh/mesh_link_planner.dart';
import 'package:coroute_app/domain/mesh/mesh_messages.dart';

// Round 10 offline link: who opens which Bluetooth link, and what a bridge phone forwards each way
// (pure Dart: tool/pure_dart_test/run.sh test/mesh_bridge_link_test.dart).
MeshFrame frame(MeshClass c, {int origin = 7, bool proxied = false, int kind = MeshKind.pos}) =>
    MeshFrame(cls: c, origin: origin, boot: 1, seq: 1, originTimeSec: 0, initialTtl: 3, ttl: 3, payload: Uint8List.fromList([kind, 0]), proxied: proxied);

void main() {
  group('link planner', () {
    final peers = {
      5: (address: 'A5', rssi: -70, psm: 0x81, caps: MeshCaps.codedPhy | MeshCaps.extendedAdv, firstMs: 0),
      50: (address: 'A50', rssi: -60, psm: 0x82, caps: 0, firstMs: 0),
      60: (address: 'A60', rssi: -90, psm: 0, caps: MeshCaps.codedPhy, firstMs: 9000),
    };
    test('the lower id opens the link, strongest first, within the link budget; Coded PHY only when both have it', () {
      final p = MeshLinkPlanner().plan(myId: 10, myCoded: true, maxLinks: 4, linked: {}, pending: {}, peers: peers, nowMs: 5000);
      expect(p.map((e) => e.address), ['A50', 'A60'], reason: 'rider 5 has the lower id: it connects to us');
      expect(p.first.coded, isFalse, reason: 'rider 50 has no Coded PHY: 1M');
      expect(p.last.coded, isTrue);
    });
    test('after 10 s without a link the higher id connects itself; full budget or pending connects stop it', () {
      final p = MeshLinkPlanner().plan(myId: 10, myCoded: true, maxLinks: 4, linked: {'A50'}, pending: {}, peers: peers, nowMs: 10000);
      expect(p.map((e) => e.address), ['A5', 'A60']);
      expect(MeshLinkPlanner().plan(myId: 10, myCoded: true, maxLinks: 1, linked: {'A50'}, pending: {}, peers: peers, nowMs: 20000), isEmpty);
      expect(MeshLinkPlanner().plan(myId: 1, myCoded: true, maxLinks: 4, linked: {}, pending: {'X', 'Y'}, peers: peers, nowMs: 20000), isEmpty);
      expect(MeshLinkPlanner().plan(myId: 1, myCoded: true, maxLinks: 0, linked: {}, pending: {}, peers: peers, nowMs: 20000), isEmpty, reason: 'standby: beacons only');
    });
  });

  group('bridge', () {
    test('uplink: SOS and positions from other riders only; SOS makes it urgent; acks and proxied copies stay in the mesh', () {
      final u = BridgeUplink();
      expect(u.offer(frame(MeshClass.position), Uint8List(4), myId: 1), isTrue);
      expect(u.urgent, isFalse);
      expect(u.offer(frame(MeshClass.position, origin: 1), Uint8List(4), myId: 1), isFalse, reason: 'my own position goes over my socket');
      expect(u.offer(frame(MeshClass.position, proxied: true), Uint8List(4), myId: 1), isFalse);
      expect(u.offer(frame(MeshClass.voice, kind: MeshKind.voice), Uint8List(4), myId: 1), isFalse);
      expect(u.offer(frame(MeshClass.sos, kind: MeshKind.sosAck), Uint8List(4), myId: 1), isFalse);
      expect(u.offer(frame(MeshClass.sos, kind: MeshKind.sos), Uint8List.fromList([1, 2, 3]), myId: 1), isTrue);
      expect(u.urgent, isTrue);
      final m = u.take()!;
      expect(m['type'], 'MESH_BRIDGE');
      expect((m['f'] as List).length, 2);
      expect(base64.decode((m['f'] as List).last as String), [1, 2, 3]);
      expect(u.take(), isNull);
    });
    test('downlink: online riders the mesh does not hear, and alerts raised outside the mesh (once each)', () {
      final d = BridgeDownlinkPlanner();
      final heard = {meshShortId('near')};
      final ids = d.ridersToProxy(riders: const [
        BridgeRider(userId: 'me', online: true, lastSeenMs: 1000, isMeshPeer: false),
        BridgeRider(userId: 'far', online: true, lastSeenMs: 9000, isMeshPeer: false),
        BridgeRider(userId: 'near', online: true, lastSeenMs: 9000, isMeshPeer: false),
        BridgeRider(userId: 'stale', online: true, lastSeenMs: 0, isMeshPeer: false),
        BridgeRider(userId: 'nosignal', online: false, lastSeenMs: 9000, isMeshPeer: false),
        BridgeRider(userId: 'meshpeer', online: true, lastSeenMs: 9000, isMeshPeer: true),
      ], myUserId: 'me', heardRecently: heard, nowMs: 20000);
      expect(ids, ['far']);
      final open = [(alertId: 'SOS-1', userId: 'far', fromMesh: false), (alertId: 'mesh_x_1', userId: 'x', fromMesh: true), (alertId: 'SOS-2', userId: 'near', fromMesh: false)];
      expect(d.alertsToProxy(open: open, heardRecently: heard), ['SOS-1']);
      expect(d.alertsToProxy(open: open, heardRecently: heard), isEmpty, reason: 'once');
    });
  });
}
