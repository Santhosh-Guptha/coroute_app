import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/p2p_mesh_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/domain/mesh/mesh_packet_codec.dart';
import 'package:coroute_app/domain/mesh/mesh_telemetry_packet.dart';
import 'mocks/mock_mesh_transport.dart';
import 'package:coroute_app/presentation/rider/widgets/cockpit_action_stack.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Convoy P2P Mesh Integration Tests', () {
    late MockMeshTransport transport;
    late P2pMeshService mesh;
    late ConvoyService convoyService;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      transport = MockMeshTransport();
      mesh = P2pMeshService(transport: transport);
      final client = MockClient((request) async => http.Response('{}', 200));
      final api = ApiClient(httpClient: client);
      convoyService = ConvoyService(
        api,
        RealtimeService(),
        TripStorageService(api),
        mesh: mesh,
      );
      convoyService.setMyUserIdForTesting('user_me');
    });

    tearDown(() async {
      convoyService.dispose();
      await mesh.stop();
      mesh.dispose();
    });

    test('Convoy activates P2P mesh and updates teammate position from mesh packet', () async {
      final testConvoy = ConvoyModel(
        groupId: 'grp_dead_zone',
        name: 'Western Ghats Ride',
        joinCode: 'GHAT9',
        createdByUserId: 'user_me',
        createdByUserName: 'Me',
        createdAtEpochMs: 1000,
        riders: {
          'user_me': RiderModel(
            userId: 'user_me',
            name: 'Me',
            lat: 13.0000,
            lng: 75.0000,
            lastSeenEpochMs: 1000,
          ),
          'rider_rahul': RiderModel(
            userId: 'rider_rahul',
            name: 'Rahul',
            lat: 12.9000,
            lng: 74.9000,
            speedKmh: 40.0,
            lastSeenEpochMs: 1000,
          ),
        },
      );

      convoyService.setActiveConvoyForTesting(testConvoy);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(convoyService.isP2pMeshActive, isTrue);

      // Teammate transmits over offline mesh
      final joinHash = MeshTelemetryPacket.hashJoinCode('GHAT9');
      final teammatePacket = MeshTelemetryPacket(
        joinCodeHash: joinHash,
        userId: 'rider_rahul',
        userName: 'Rahul',
        lat: 12.9950,
        lng: 75.0050,
        speedKmh: 75.0,
        heading: 90.0,
        batteryLevel: 80,
        role: 'PACK',
        seq: 42,
        ttl: 3,
        hopCount: 0,
        timestampMs: 5000,
      );

      transport.simulateIncoming(MeshPacketCodec.encode(teammatePacket));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final rahul = convoyService.activeConvoy?.riders['rider_rahul'];
      expect(rahul, isNotNull);
      expect(rahul!.lat, closeTo(12.9950, 0.0001));
      expect(rahul.lng, closeTo(75.0050, 0.0001));
      expect(rahul.speedKmh, equals(75.0));
      expect(rahul.presence, equals('MESH'));
      expect(rahul.isMeshPeer, isTrue);
      expect(rahul.meshHops, equals(0));
    });

    test('Teammate offline SOS distress beacon creates alert in convoyService', () async {
      final testConvoy = ConvoyModel(
        groupId: 'grp_dead_zone',
        name: 'Valley Patrol',
        joinCode: 'VALLEY1',
        createdByUserId: 'user_me',
        createdByUserName: 'Me',
        createdAtEpochMs: 1000,
        riders: {
          'user_me': RiderModel(
            userId: 'user_me',
            name: 'Me',
            lat: 13.0000,
            lng: 75.0000,
            lastSeenEpochMs: 1000,
          ),
          'rider_kiran': RiderModel(
            userId: 'rider_kiran',
            name: 'Kiran',
            lat: 13.0010,
            lng: 75.0010,
            lastSeenEpochMs: 1000,
          ),
        },
      );

      convoyService.setActiveConvoyForTesting(testConvoy);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Kiran crashes in cellular dead zone and his phone broadcasts SOS over P2P mesh
      final joinHash = MeshTelemetryPacket.hashJoinCode('VALLEY1');
      final crashPacket = MeshTelemetryPacket(
        joinCodeHash: joinHash,
        userId: 'rider_kiran',
        userName: 'Kiran',
        lat: 13.0015,
        lng: 75.0015,
        speedKmh: 0.0,
        heading: 0.0,
        isSos: true,
        sosType: 'CRASH',
        seq: 1,
        timestampMs: 10000,
      );

      transport.simulateIncoming(MeshPacketCodec.encode(crashPacket));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(convoyService.activeConvoy?.activeAlerts, isNotEmpty);
      final alert = convoyService.activeConvoy!.activeAlerts.first;
      expect(alert.userId, equals('rider_kiran'));
      expect(alert.alertType, equals('CRASH'));
      expect(alert.alertId, startsWith('mesh_'));
    });

    testWidgets('Teammate offline SOS distress beacon renders on action stack', (tester) async {
      final testConvoy = ConvoyModel(
        groupId: 'grp_dead_zone',
        name: 'Valley Patrol',
        joinCode: 'VALLEY1',
        createdByUserId: 'user_me',
        createdByUserName: 'Me',
        createdAtEpochMs: 1000,
        riders: {
          'user_me': RiderModel(
            userId: 'user_me',
            name: 'Me',
            lat: 13.0000,
            lng: 75.0000,
            lastSeenEpochMs: 1000,
          ),
          'rider_kiran': RiderModel(
            userId: 'rider_kiran',
            name: 'Kiran',
            lat: 13.0010,
            lng: 75.0010,
            lastSeenEpochMs: 1000,
          ),
        },
        activeAlerts: [
          SosAlertModel(
            alertId: 'mesh_rider_kiran_10000',
            userId: 'rider_kiran',
            userName: 'Kiran',
            lat: 13.0015,
            lng: 75.0015,
            alertType: 'CRASH',
            occurredAt: 10000,
            timestamp: 10000,
            source: EmergencySource.meshBeacon,
            resolved: false,
          ),
        ],
      );

      // Render CockpitActionStack
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CockpitActionStack(
              convoy: testConvoy,
              me: testConvoy.riders['user_me']!,
              isLead: true,
            ),
          ),
        ),
      );

      await tester.pump();

      // Verify the P2P Mesh SOS alert card is prominently rendered
      expect(find.textContaining('SOS: Kiran (via Mesh)'), findsOneWidget);
      expect(find.textContaining('CRASH'), findsOneWidget);
    });
  });
}
