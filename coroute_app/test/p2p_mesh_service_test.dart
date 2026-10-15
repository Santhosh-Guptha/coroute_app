import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/mesh/mesh_telemetry_packet.dart';
import 'package:coroute_app/domain/mesh/mesh_packet_codec.dart';
import 'package:coroute_app/domain/mesh/mock_mesh_transport.dart';
import 'package:coroute_app/data/services/p2p_mesh_service.dart';

void main() {
  group('P2pMeshService Tests', () {
    late MockMeshTransport transport;
    late P2pMeshService mesh;

    setUp(() {
      transport = MockMeshTransport();
      mesh = P2pMeshService(transport: transport);
    });

    tearDown(() async {
      await mesh.stop();
    });

    test('Starting mesh sets active join code and starts transport', () async {
      await mesh.start(joinCode: 'HAWK7', myUserId: 'user_me', myUserName: 'Santhosh');

      expect(mesh.isRunning, isTrue);
      expect(mesh.activeJoinCode, equals('HAWK7'));
      expect(transport.activeJoinCode, equals('HAWK7'));
    });

    test('Transmitting local telemetry encodes packet into transport', () async {
      await mesh.start(joinCode: 'HAWK7', myUserId: 'user_me', myUserName: 'Santhosh');

      mesh.updateMyTelemetry(
        lat: 12.9716,
        lng: 77.5946,
        speedKmh: 65.0,
        heading: 90.0,
        batteryLevel: 85,
        role: 'LEAD',
      );

      // Trigger immediate broadcast
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(transport.sentPackets, isNotEmpty);
      final decoded = MeshPacketCodec.decode(transport.sentPackets.last);
      expect(decoded, isNotNull);
      expect(decoded!.userId, equals('user_me'));
      expect(decoded.userName, equals('Santhosh'));
      expect(decoded.lat, closeTo(12.9716, 0.0001));
      expect(decoded.speedKmh, equals(65.0));
      expect(decoded.role, equals('LEAD'));
    });

    test('Incoming packet with matching join code discovers peer', () async {
      await mesh.start(joinCode: 'HAWK7', myUserId: 'user_me', myUserName: 'Santhosh');

      final joinHash = MeshTelemetryPacket.hashJoinCode('HAWK7');
      final peerPacket = MeshTelemetryPacket(
        joinCodeHash: joinHash,
        userId: 'peer_1',
        userName: 'Rahul',
        lat: 12.9750,
        lng: 77.5980,
        speedKmh: 70.0,
        heading: 88.0,
        seq: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );

      final bytes = MeshPacketCodec.encode(peerPacket);
      transport.simulateIncoming(bytes);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(mesh.peerCount, equals(1));
      final peer = mesh.activePeers.first;
      expect(peer.userId, equals('peer_1'));
      expect(peer.name, equals('Rahul'));
      expect(peer.speedKmh, equals(70.0));
      expect(peer.isDirect, isTrue);
    });

    test('Incoming packet with mismatched join code is ignored', () async {
      await mesh.start(joinCode: 'HAWK7', myUserId: 'user_me', myUserName: 'Santhosh');

      final otherHash = MeshTelemetryPacket.hashJoinCode('DIFFERENT');
      final strangerPacket = MeshTelemetryPacket(
        joinCodeHash: otherHash,
        userId: 'stranger_1',
        userName: 'Ghost',
        lat: 12.0,
        lng: 77.0,
        speedKmh: 40.0,
        heading: 0.0,
        seq: 1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );

      transport.simulateIncoming(MeshPacketCodec.encode(strangerPacket));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(mesh.peerCount, equals(0));
    });

    test('Multi-hop relay forwards packet with decremented TTL and incremented hopCount', () async {
      await mesh.start(joinCode: 'HAWK7', myUserId: 'user_intermediate', myUserName: 'RelayNode');

      final joinHash = MeshTelemetryPacket.hashJoinCode('HAWK7');
      final distantPacket = MeshTelemetryPacket(
        joinCodeHash: joinHash,
        userId: 'sweeper_1',
        userName: 'Deepak',
        lat: 12.9600,
        lng: 77.5800,
        speedKmh: 55.0,
        heading: 180.0,
        seq: 101,
        ttl: 3,
        hopCount: 0,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );

      transport.clearSent();
      transport.simulateIncoming(MeshPacketCodec.encode(distantPacket));

      // Allow jitter delay to fire relay
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(transport.sentPackets, isNotEmpty);
      final relayed = MeshPacketCodec.decode(transport.sentPackets.last);
      expect(relayed, isNotNull);
      expect(relayed!.userId, equals('sweeper_1'));
      expect(relayed.seq, equals(101));
      expect(relayed.ttl, equals(2)); // Decremented
      expect(relayed.hopCount, equals(1)); // Incremented
    });

    test('Emergency SOS beacon triggers SOS stream and flag', () async {
      await mesh.start(joinCode: 'HAWK7', myUserId: 'user_me', myUserName: 'Santhosh');

      MeshTelemetryPacket? sosEvent;
      mesh.onSosReceived.listen((p) => sosEvent = p);

      final joinHash = MeshTelemetryPacket.hashJoinCode('HAWK7');
      final crashPacket = MeshTelemetryPacket(
        joinCodeHash: joinHash,
        userId: 'fallen_rider',
        userName: 'Kiran',
        lat: 12.9800,
        lng: 77.6000,
        speedKmh: 0.0,
        heading: 0.0,
        isSos: true,
        sosType: 'CRASH',
        seq: 5,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );

      transport.simulateIncoming(MeshPacketCodec.encode(crashPacket));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(mesh.hasActiveSos, isTrue);
      expect(sosEvent, isNotNull);
      expect(sosEvent!.userId, equals('fallen_rider'));
      expect(sosEvent!.sosType, equals('CRASH'));
    });
  });
}
