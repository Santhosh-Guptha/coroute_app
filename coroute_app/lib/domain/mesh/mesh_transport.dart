import 'dart:typed_data';

/// Incoming raw packet received from a mesh peer over radio or socket.
class MeshIncomingPacket {
  final Uint8List data;
  final String senderAddress;
  final int senderPort;
  final int receivedAtMs;

  MeshIncomingPacket({
    required this.data,
    required this.senderAddress,
    required this.senderPort,
    int? receivedAtMs,
  }) : receivedAtMs = receivedAtMs ?? DateTime.now().millisecondsSinceEpoch;
}

/// Abstract contract for offline peer-to-peer mesh transports.
abstract class MeshTransport {
  /// Starts listening and prepares the transport for the given convoy join code.
  Future<void> start({required String joinCode, int port = 42424});

  /// Sends a raw mesh packet to all nearby peers.
  void send(Uint8List data);

  /// Stream of all incoming raw packets from nearby peers.
  Stream<MeshIncomingPacket> get incoming;

  /// Stops the transport and releases any sockets or hardware radios.
  Future<void> stop();

  /// Whether the transport is currently active and bound to a network interface.
  bool get isRunning;
}
