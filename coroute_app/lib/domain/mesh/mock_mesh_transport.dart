import 'dart:async';
import 'dart:typed_data';
import 'mesh_transport.dart';

/// Test mock transport for deterministic testing of P2P mesh telemetry,
/// multi-hop relay forwarding, and dead-zone emergency SOS beacons.
class MockMeshTransport implements MeshTransport {
  final StreamController<MeshIncomingPacket> _incoming = StreamController<MeshIncomingPacket>.broadcast();
  final List<Uint8List> sentPackets = [];
  bool _running = false;
  String? activeJoinCode;
  int? activePort;

  @override
  bool get isRunning => _running;

  @override
  Stream<MeshIncomingPacket> get incoming => _incoming.stream;

  @override
  Future<void> start({required String joinCode, int port = 42424}) async {
    _running = true;
    activeJoinCode = joinCode;
    activePort = port;
  }

  @override
  void send(Uint8List data) {
    if (!_running) return;
    sentPackets.add(Uint8List.fromList(data));
  }

  @override
  Future<void> stop() async {
    _running = false;
  }

  /// Injects an incoming mesh packet as if received over radio from a peer bike.
  void simulateIncoming(Uint8List data, {String senderAddress = '192.168.43.10', int senderPort = 42424}) {
    if (!_running) return;
    _incoming.add(
      MeshIncomingPacket(
        data: data,
        senderAddress: senderAddress,
        senderPort: senderPort,
      ),
    );
  }

  void clearSent() {
    sentPackets.clear();
  }
}
