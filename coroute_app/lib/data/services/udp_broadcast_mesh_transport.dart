import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../domain/mesh/mesh_transport.dart';

/// Zero-configuration UDP broadcast peer-to-peer transport for offline convoy meshes.
/// Operates across Android / iOS devices on local tethered Wi-Fi hotspots, ad-hoc wireless links,
/// or peer subnets without requiring cellular signal or an internet gateway.
class UdpBroadcastMeshTransport implements MeshTransport {
  static const int defaultPort = 42424;

  final int port;
  RawDatagramSocket? _socket;
  final StreamController<MeshIncomingPacket> _incoming = StreamController<MeshIncomingPacket>.broadcast();
  bool _running = false;

  UdpBroadcastMeshTransport({this.port = defaultPort});

  @override
  bool get isRunning => _running;

  @override
  Stream<MeshIncomingPacket> get incoming => _incoming.stream;

  @override
  Future<void> start({required String joinCode, int? port}) async {
    if (_running) await stop();

    final bindPort = port ?? this.port;
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        bindPort,
        reuseAddress: true,
        reusePort: true,
      );
      _socket?.broadcastEnabled = true;
      _running = true;

      _socket?.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            final dg = _socket?.receive();
            if (dg != null && dg.data.isNotEmpty) {
              _incoming.add(
                MeshIncomingPacket(
                  data: Uint8List.fromList(dg.data),
                  senderAddress: dg.address.address,
                  senderPort: dg.port,
                ),
              );
            }
          }
        },
        onError: (Object error) {
          debugPrint('P2P Mesh UDP error: $error');
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('P2P Mesh UDP bind failed on port $bindPort: $e');
      _running = false;
    }
  }

  @override
  void send(Uint8List data) {
    if (!_running || _socket == null) return;
    try {
      _socket?.send(data, InternetAddress('255.255.255.255'), port);
    } catch (e) {
      debugPrint('P2P Mesh UDP send failed: $e');
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
  }
}
