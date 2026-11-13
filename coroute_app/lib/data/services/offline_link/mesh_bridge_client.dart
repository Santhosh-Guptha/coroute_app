// Round 10 offline link: a phone with a healthy server link bridges the mesh (gateway/src/mesh_bridge.js).
//  * uplink: fresh SOS and position frames heard over the mesh from riders without signal go to the gateway as
//    MESH_BRIDGE {f: [base64 sealed frames]} (SOS at once, positions batched once a second);
//  * the gateway answers MESH_BRIDGE_ACK {acks: [{o, cid, alertId}]}: the bridge puts a "server has it" SOS
//    acknowledgement into the mesh, so the SOS origin stops resending;
//  * downlink: the room's riders the mesh does not hear (online, far away) and open alerts raised outside the mesh are
//    put into the mesh as PROXIED frames, so riders without signal still see the whole group and every SOS.
// Pure decisions here ([BridgeDownlinkPlanner]); the service does the I/O.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../../domain/mesh/mesh_frame.dart';

class BridgeUplink {
  BridgeUplink({this.maxFrames = 48});
  final int maxFrames;
  final List<String> _queue = <String>[];
  bool _urgent = false;

  bool get urgent => _urgent;
  int get length => _queue.length;

  /// Keeps a frame for the gateway: SOS and positions only, never from this phone, never proxied copies.
  bool offer(MeshFrame f, Uint8List sealed, {required int myId}) {
    if (f.proxied || f.origin == myId) return false;
    if (f.cls != MeshClass.sos && f.cls != MeshClass.position) return false;
    if (f.cls == MeshClass.sos && f.payload.isNotEmpty && f.payload[0] != 0x01) return false; // acks stay in the mesh
    if (_queue.length >= maxFrames * 4) _queue.removeAt(0);
    _queue.add(base64.encode(sealed));
    if (f.cls == MeshClass.sos) _urgent = true;
    return true;
  }

  /// The next MESH_BRIDGE message (null when nothing waits).
  Map<String, dynamic>? take() {
    if (_queue.isEmpty) return null;
    final n = _queue.length < maxFrames ? _queue.length : maxFrames;
    final f = _queue.sublist(0, n);
    _queue.removeRange(0, n);
    _urgent = false;
    return <String, dynamic>{'type': 'MESH_BRIDGE', 'f': f};
  }

  void clear() {
    _queue.clear();
    _urgent = false;
  }
}

class BridgeRider {
  const BridgeRider({required this.userId, required this.online, required this.lastSeenMs, required this.isMeshPeer});
  final String userId;
  final bool online;
  final int lastSeenMs;
  final bool isMeshPeer;
}

class BridgeDownlinkPlanner {
  final Set<String> _sentAlerts = <String>{};

  /// Riders whose server position should go into the mesh: online on the server, fresh, not this phone, and not heard
  /// over the mesh in the last 30 s (the mesh already has a better copy of those).
  List<String> ridersToProxy({required List<BridgeRider> riders, required String myUserId, required Set<int> heardRecently, required int nowMs}) => [
        for (final r in riders)
          if (r.userId != myUserId && r.online && !r.isMeshPeer && nowMs - r.lastSeenMs <= 15000 && !heardRecently.contains(meshShortId(r.userId))) r.userId,
      ];

  /// Open alerts not raised over the mesh: each goes into the mesh once.
  List<String> alertsToProxy({required List<({String alertId, String userId, bool fromMesh})> open, required Set<int> heardRecently}) {
    final out = <String>[];
    for (final a in open) {
      if (a.fromMesh || heardRecently.contains(meshShortId(a.userId))) continue;
      if (_sentAlerts.add(a.alertId)) out.add(a.alertId);
    }
    return out;
  }

  void reset() => _sentAlerts.clear();
}
