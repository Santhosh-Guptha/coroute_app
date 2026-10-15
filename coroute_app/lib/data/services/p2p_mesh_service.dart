import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../../domain/mesh/mesh_packet_codec.dart';
import '../../domain/mesh/mesh_telemetry_packet.dart';
import '../../domain/mesh/mesh_transport.dart';
import 'udp_broadcast_mesh_transport.dart';

/// Represents a nearby convoy teammate discovered and tracked via P2P mesh.
class MeshPeer {
  final String userId;
  final String name;
  final double lat;
  final double lng;
  final double speedKmh;
  final double heading;
  final int batteryLevel;
  final bool isCharging;
  final String role;
  final bool isSos;
  final String sosType;
  final int hopCount;
  final int lastSeenMs;
  final double? fuelUsableKm;

  const MeshPeer({
    required this.userId,
    required this.name,
    required this.lat,
    required this.lng,
    required this.speedKmh,
    required this.heading,
    required this.batteryLevel,
    required this.isCharging,
    required this.role,
    required this.isSos,
    required this.sosType,
    required this.hopCount,
    required this.lastSeenMs,
    this.fuelUsableKm,
  });

  bool get isDirect => hopCount == 0;
  bool get isRelayed => hopCount > 0;
}

/// Service that coordinates offline peer-to-peer mesh networking between motorcycle riders.
/// Seamlessly bridges distance, telemetry, and SOS distress beacons when cellular is lost.
class P2pMeshService extends ChangeNotifier {
  final MeshTransport transport;
  final math.Random _random = math.Random();

  String? _activeJoinCode;
  int _joinCodeHash = 0;
  String? _myUserId;
  String _myUserName = 'Rider';

  StreamSubscription<MeshIncomingPacket>? _incomingSub;
  Timer? _broadcastTimer;
  Timer? _pruneTimer;

  int _txSeq = 0;
  MeshTelemetryPacket? _latestMyTelemetry;

  final Map<String, MeshPeer> _peers = {};
  final Set<String> _seenPackets = <String>{};
  final List<String> _seenOrder = <String>[];

  final StreamController<MeshTelemetryPacket> _telemetryStream = StreamController<MeshTelemetryPacket>.broadcast();
  final StreamController<MeshTelemetryPacket> _sosStream = StreamController<MeshTelemetryPacket>.broadcast();

  Stream<MeshTelemetryPacket> get onTelemetryReceived => _telemetryStream.stream;
  Stream<MeshTelemetryPacket> get onSosReceived => _sosStream.stream;

  bool get isRunning => transport.isRunning;
  String? get activeJoinCode => _activeJoinCode;
  int get peerCount => _peers.length;
  List<MeshPeer> get activePeers => _peers.values.toList();
  bool get hasActiveSos => _peers.values.any((p) => p.isSos);

  P2pMeshService({MeshTransport? transport})
      : transport = transport ?? UdpBroadcastMeshTransport();

  /// Starts the P2P mesh network for a convoy with the given [joinCode].
  Future<void> start({
    required String joinCode,
    required String myUserId,
    String myUserName = 'Rider',
  }) async {
    if (_activeJoinCode == joinCode && isRunning) return;

    await stop();

    _activeJoinCode = joinCode.trim().toUpperCase();
    _joinCodeHash = MeshTelemetryPacket.hashJoinCode(_activeJoinCode!);
    _myUserId = myUserId;
    _myUserName = myUserName;

    await transport.start(joinCode: _activeJoinCode!);
    _incomingSub = transport.incoming.listen(_onIncomingPacket);

    // Prune stale peers every 5 seconds
    _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) => _pruneStalePeers());

    // Adaptive broadcast loop
    _scheduleNextBroadcast(delayMs: 200);

    notifyListeners();
  }

  /// Updates local rider telemetry to be broadcast to nearby mesh peers.
  void updateMyTelemetry({
    required double lat,
    required double lng,
    required double speedKmh,
    required double heading,
    int batteryLevel = 100,
    bool isCharging = false,
    String role = 'PACK',
    bool isSos = false,
    String sosType = 'CRASH',
    double? fuelUsableKm,
  }) {
    if (_activeJoinCode == null || _myUserId == null) return;

    final wasSos = _latestMyTelemetry?.isSos ?? false;
    _latestMyTelemetry = MeshTelemetryPacket(
      joinCodeHash: _joinCodeHash,
      userId: _myUserId!,
      userName: _myUserName,
      lat: lat,
      lng: lng,
      speedKmh: speedKmh,
      heading: heading,
      batteryLevel: batteryLevel,
      isCharging: isCharging,
      role: role,
      isSos: isSos,
      sosType: sosType,
      seq: ++_txSeq & 0xFFFF,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      fuelUsableKm: fuelUsableKm,
    );

    // If an SOS was just triggered, immediately broadcast without waiting for timer
    if (isSos && !wasSos) {
      _broadcastNow();
    }
  }

  void _scheduleNextBroadcast({int? delayMs}) {
    _broadcastTimer?.cancel();
    if (!isRunning) return;

    final int nextInterval;
    if (delayMs != null) {
      nextInterval = delayMs;
    } else if (_latestMyTelemetry?.isSos == true) {
      // High-frequency emergency pulse
      nextInterval = 500;
    } else if ((_latestMyTelemetry?.speedKmh ?? 0) > 3.0) {
      // Moving: 1.5s interval with +/- 150ms jitter to prevent sync collisions
      nextInterval = 1350 + _random.nextInt(300);
    } else {
      // Stationary / stopped: 4s interval
      nextInterval = 3800 + _random.nextInt(400);
    }

    _broadcastTimer = Timer(Duration(milliseconds: nextInterval), () {
      _broadcastNow();
      _scheduleNextBroadcast();
    });
  }

  void _broadcastNow() {
    final telemetry = _latestMyTelemetry;
    if (telemetry == null || !isRunning) return;

    // Refresh sequence and timestamp
    final packetToSend = MeshTelemetryPacket(
      joinCodeHash: telemetry.joinCodeHash,
      userId: telemetry.userId,
      userName: telemetry.userName,
      lat: telemetry.lat,
      lng: telemetry.lng,
      speedKmh: telemetry.speedKmh,
      heading: telemetry.heading,
      batteryLevel: telemetry.batteryLevel,
      isCharging: telemetry.isCharging,
      role: telemetry.role,
      isSos: telemetry.isSos,
      sosType: telemetry.sosType,
      seq: ++_txSeq & 0xFFFF,
      ttl: 3,
      hopCount: 0,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      fuelUsableKm: telemetry.fuelUsableKm,
    );

    final bytes = MeshPacketCodec.encode(packetToSend);
    transport.send(bytes);
  }

  void _onIncomingPacket(MeshIncomingPacket raw) {
    final packet = MeshPacketCodec.decode(raw.data);
    if (packet == null) return;

    // Filter packets from other convoys
    if (packet.joinCodeHash != _joinCodeHash) return;

    // Discard packets from self
    if (packet.userId == _myUserId) return;

    // Deduplication check: (userId:seq)
    final packetKey = '${packet.userId}:${packet.seq}';
    if (_seenPackets.contains(packetKey)) return;

    _seenPackets.add(packetKey);
    _seenOrder.add(packetKey);
    if (_seenOrder.length > 500) {
      final old = _seenOrder.removeAt(0);
      _seenPackets.remove(old);
    }

    // Update active peers table
    _peers[packet.userId] = MeshPeer(
      userId: packet.userId,
      name: packet.userName,
      lat: packet.lat,
      lng: packet.lng,
      speedKmh: packet.speedKmh,
      heading: packet.heading,
      batteryLevel: packet.batteryLevel,
      isCharging: packet.isCharging,
      role: packet.role,
      isSos: packet.isSos,
      sosType: packet.sosType,
      hopCount: packet.hopCount,
      lastSeenMs: raw.receivedAtMs,
      fuelUsableKm: packet.fuelUsableKm,
    );

    // Notify listeners & streams
    _telemetryStream.add(packet);
    if (packet.isSos) {
      _sosStream.add(packet);
    }
    notifyListeners();

    // Multi-Hop Mesh Relay Forwarding:
    // If packet has remaining TTL, forward it to extend range across the convoy line
    if (packet.ttl > 1) {
      _relayPacket(packet);
    }
  }

  void _relayPacket(MeshTelemetryPacket packet) {
    final relayPacket = packet.copyForRelay();
    final delayMs = 25 + _random.nextInt(50); // 25..75ms jitter prevents broadcast storm

    Timer(Duration(milliseconds: delayMs), () {
      if (!isRunning) return;
      final bytes = MeshPacketCodec.encode(relayPacket);
      transport.send(bytes);
    });
  }

  void _pruneStalePeers() {
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;

    _peers.removeWhere((_, peer) {
      // Discard peers not heard from for >30 seconds
      final stale = (now - peer.lastSeenMs) > 30000;
      if (stale) changed = true;
      return stale;
    });

    if (changed) {
      notifyListeners();
    }
  }

  bool _disposed = false;

  /// Stops mesh operations and cleans up network sockets.
  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _pruneTimer?.cancel();
    await _incomingSub?.cancel();
    _incomingSub = null;

    await transport.stop();
    _peers.clear();
    _seenPackets.clear();
    _seenOrder.clear();
    _activeJoinCode = null;
    _latestMyTelemetry = null;

    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _broadcastTimer?.cancel();
    _pruneTimer?.cancel();
    _incomingSub?.cancel();
    _incomingSub = null;
    transport.stop();
    _peers.clear();
    _seenPackets.clear();
    _seenOrder.clear();
    _telemetryStream.close();
    _sosStream.close();
    super.dispose();
  }
}
