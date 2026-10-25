import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/services/satellite_sos_service.dart';
import 'package:coroute_app/data/services/sos_transport_adapter.dart';
import 'package:coroute_app/domain/safety/sos_event.dart';
import 'package:coroute_app/domain/safety/sos_packet_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FeatureGates.forceAllUnlocked = false;
  });

  group('FEAT-05: SosPacketCodec (16-Byte Compact Binary Protocol)', () {
    test('TEST-SAT-01: 16-Byte Codec Valid Round-Trip', () {
      final timestamp = DateTime.utc(2026, 10, 23, 12, 0, 0);
      const lat = 34.152588; // Khardung La Pass, Ladakh, India
      const lng = 77.604739;
      const alt = 5359.0;
      const severity = SosSeverity.criticalTraumaL1;
      const bloodGroup = 'O+';

      final packet = SosPacketCodec.encode(
        latitude: lat,
        longitude: lng,
        altitudeMeters: alt,
        timestamp: timestamp,
        severity: severity,
        bloodGroup: bloodGroup,
      );

      expect(packet.length, equals(16));
      expect(SosPacketCodec.verifyChecksum(packet), isTrue);

      final decoded = SosPacketCodec.decode(packet);
      expect((decoded.latitude - lat).abs(), lessThan(1e-6));
      expect((decoded.longitude - lng).abs(), lessThan(1e-6));
      expect(decoded.altitudeMeters, equals(5359.0));
      expect(decoded.timestamp, equals(timestamp));
      expect(decoded.severity, equals(SosSeverity.criticalTraumaL1));
      expect(decoded.bloodGroup, equals('O+'));
    });

    test('TEST-SAT-02: Invalid Latitude Out-of-Range throws ArgumentError', () {
      final timestamp = DateTime.utc(2026, 10, 23, 12, 0, 0);

      expect(
        () => SosPacketCodec.encode(
          latitude: 91.0,
          longitude: 77.0,
          timestamp: timestamp,
        ),
        throwsArgumentError,
      );

      expect(
        () => SosPacketCodec.encode(
          latitude: -90.0001,
          longitude: 77.0,
          timestamp: timestamp,
        ),
        throwsArgumentError,
      );
    });

    test('TEST-SAT-03: Invalid Longitude Out-of-Range throws ArgumentError', () {
      final timestamp = DateTime.utc(2026, 10, 23, 12, 0, 0);

      expect(
        () => SosPacketCodec.encode(
          latitude: 25.0,
          longitude: 180.001,
          timestamp: timestamp,
        ),
        throwsArgumentError,
      );

      expect(
        () => SosPacketCodec.encode(
          latitude: 25.0,
          longitude: -180.001,
          timestamp: timestamp,
        ),
        throwsArgumentError,
      );
    });

    test('TEST-SAT-04: Negative Coordinates (S / W Hemispheres)', () {
      final timestamp = DateTime.utc(2026, 5, 10, 8, 30, 0);
      const lat = -33.868820; // Sydney, Southern Hemisphere
      const lng = -151.209296; // Western Hemisphere
      const alt = 42.0;

      final packet = SosPacketCodec.encode(
        latitude: lat,
        longitude: lng,
        altitudeMeters: alt,
        timestamp: timestamp,
        severity: SosSeverity.manual,
        bloodGroup: 'B+',
      );

      expect(packet.length, equals(16));
      final decoded = SosPacketCodec.decode(packet);
      expect((decoded.latitude - lat).abs(), lessThan(1e-6));
      expect((decoded.longitude - lng).abs(), lessThan(1e-6));
      expect(decoded.altitudeMeters, equals(42.0));
      expect(decoded.bloodGroup, equals('B+'));
    });

    test('TEST-SAT-05: Unknown Altitude Sentinel (0x7FFF / null)', () {
      final timestamp = DateTime.utc(2026, 10, 23, 12, 0, 0);

      final packet = SosPacketCodec.encode(
        latitude: 12.9716,
        longitude: 77.5946,
        altitudeMeters: null, // Unknown GPS altitude
        timestamp: timestamp,
      );

      expect(packet.length, equals(16));
      final decoded = SosPacketCodec.decode(packet);
      expect(decoded.altitudeMeters, isNull);
    });

    test('TEST-SAT-06: Timestamp Boundary & Epoch serialization', () {
      final ts = DateTime.utc(2035, 1, 1, 0, 0, 0);
      final packet = SosPacketCodec.encode(
        latitude: 13.0,
        longitude: 80.0,
        timestamp: ts,
      );

      final decoded = SosPacketCodec.decode(packet);
      expect(decoded.timestamp, equals(ts));
    });

    test('TEST-SAT-07: Corruption & Checksum Rejection', () {
      final timestamp = DateTime.utc(2026, 10, 23, 12, 0, 0);
      final packet = SosPacketCodec.encode(
        latitude: 28.6139,
        longitude: 77.2090,
        timestamp: timestamp,
        bloodGroup: 'AB+',
      );

      expect(SosPacketCodec.verifyChecksum(packet), isTrue);

      // Corrupt a byte in the payload
      final corrupted = Uint8List.fromList(packet);
      corrupted[3] ^= 0x01; // flip single bit

      expect(SosPacketCodec.verifyChecksum(corrupted), isFalse);
      expect(() => SosPacketCodec.decode(corrupted), throwsFormatException);
    });
  });

  group('FEAT-05: SatelliteSosService & Transport Orchestration', () {
    late SatelliteSosService service;

    setUp(() {
      service = SatelliteSosService(
        transports: [
          MockSatelliteTransportAdapter(shouldSucceed: true),
        ],
        baseRetryDelay: const Duration(milliseconds: 10),
      );
      service.resetForTesting();
    });

    tearDown(() {
      service.dispose();
    });

    test('TEST-SAT-08: SOS Event Lifecycle State Machine', () async {
      final mock = MockSatelliteTransportAdapter(shouldSucceed: true);
      final testService = SatelliteSosService(
        transports: [mock],
        baseRetryDelay: const Duration(milliseconds: 10),
      );

      final event = await testService.dispatchSos(
        latitude: 34.1525,
        longitude: 77.6047,
        altitudeMeters: 5359.0,
        severity: SosSeverity.criticalTraumaL1,
        bloodGroup: 'O+',
        isSimulated: true,
      );

      expect(event.deliveryState, equals(SosDeliveryState.providerAccepted));
      expect(event.lastProviderId, equals('mock_satellite_ci'));
      expect(event.isSimulated, isTrue);

      testService.dispose();
    });

    test('TEST-SAT-09: Deduplication by Event ID', () async {
      final mock = MockSatelliteTransportAdapter(shouldSucceed: true);
      final testService = SatelliteSosService(
        transports: [mock],
        baseRetryDelay: const Duration(milliseconds: 10),
      );

      const eventId = 'unique_sos_test_001';
      final event1 = await testService.dispatchSos(
        id: eventId,
        latitude: 34.1525,
        longitude: 77.6047,
        isSimulated: true,
      );

      final event2 = await testService.dispatchSos(
        id: eventId,
        latitude: 34.1525,
        longitude: 77.6047,
        isSimulated: true,
      );

      expect(identical(event1, event2) || event1.id == event2.id, isTrue);
      expect(mock.transmissionAttempts, equals(1)); // Only attempted once!

      testService.dispose();
    });

    test('TEST-SAT-10: Offline Queue & Bounded Retries', () async {
      final failingMock = MockSatelliteTransportAdapter(shouldSucceed: false);
      final testService = SatelliteSosService(
        transports: [failingMock],
        maxRetries: 3,
        baseRetryDelay: const Duration(milliseconds: 20),
      );

      final event = await testService.dispatchSos(
        latitude: 12.0,
        longitude: 77.0,
        isSimulated: true,
      );

      expect(event.deliveryState, equals(SosDeliveryState.failed));
      expect(event.retryCount, equals(1));

      // Wait for bounded retries to execute
      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsedMilliseconds < 1000) {
        final list = testService.activeEventsNotifier.value;
        if (list.isNotEmpty && list.firstWhere((e) => e.id == event.id).retryCount >= 3) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final activeList = testService.activeEventsNotifier.value;
      expect(activeList.isNotEmpty, isTrue);
      final finalEvent = activeList.firstWhere((e) => e.id == event.id);
      expect(finalEvent.retryCount, equals(3));
      expect(finalEvent.deliveryState, equals(SosDeliveryState.failed));

      testService.dispose();
    });

    test('TEST-SAT-11: Transport Selection Routing (Online vs Handoff)', () async {
      bool isOnline = true;
      final onlineTransport = CoRouteOnlineTransportAdapter(
        connectivityChecker: () async => isOnline,
        onlineDispatcher: (event) async => true,
      );

      final handoffTransport = CellularEmergencyHandoffAdapter();

      final testService = SatelliteSosService(
        transports: [onlineTransport, handoffTransport],
      );

      // 1. Online condition -> routes to online gateway
      final event1 = await testService.dispatchSos(
        id: 'test_online_01',
        latitude: 12.9716,
        longitude: 77.5946,
        isSimulated: true,
      );
      expect(event1.deliveryState, equals(SosDeliveryState.providerAccepted));
      expect(event1.lastProviderId, equals('coroute_gateway_online'));

      // 2. Offline condition -> falls back to cellular 112 emergency handoff
      isOnline = false;
      final event2 = await testService.dispatchSos(
        id: 'test_offline_02',
        latitude: 12.9716,
        longitude: 77.5946,
        isSimulated: true,
      );
      expect(event2.deliveryState, equals(SosDeliveryState.handoffRequired));
      expect(event2.lastProviderId, equals('india_112_erss'));

      testService.dispose();
    });

    test('TEST-SAT-12: India 112 ERSS Message Formatting', () {
      final ts = DateTime.utc(2026, 10, 23, 14, 30, 0);
      final event = SosEvent(
        id: 'erss_msg_test',
        latitude: 34.152588,
        longitude: 77.604739,
        altitudeMeters: 5359.0,
        timestamp: ts,
        severity: SosSeverity.criticalTraumaL1,
        bloodGroup: 'O+',
      );

      final message = event.toIndiaErssMessage();

      expect(message, contains('EMERGENCY SOS: CoRoute Rider in distress!'));
      expect(message, contains('Severity: Critical Trauma Level 1'));
      expect(message, contains('Location: 34.152588, 77.604739 | Alt: 5359m'));
      expect(message, contains('https://maps.google.com/?q=34.152588,77.604739'));
      expect(message, contains('Time: 14:30:00Z'));
      expect(message, contains('Blood: O+'));
    });

    test('TEST-SAT-13: Simulation Transport Explicit Flagging', () async {
      final mock = MockSatelliteTransportAdapter(shouldSucceed: true);
      expect(mock.isSimulated, isTrue);

      final result = await mock.transmit(
        SosEvent(
          id: 'sim_test',
          latitude: 10.0,
          longitude: 76.0,
          timestamp: DateTime.now().toUtc(),
        ),
      );

      expect(result.isSimulated, isTrue);
      expect(result.state, equals(SosDeliveryState.providerAccepted));
    });

    test('TEST-SAT-14: Privacy & Consent Enforcement (No Consent = Blood Group Empty)', () {
      final ts = DateTime.utc(2026, 10, 23, 12, 0, 0);

      // When blood group is not provided or user has not consented
      final packet = SosPacketCodec.encode(
        latitude: 12.0,
        longitude: 77.0,
        timestamp: ts,
        bloodGroup: null,
      );

      final decoded = SosPacketCodec.decode(packet);
      expect(decoded.bloodGroup, isNull);

      final event = SosEvent(
        id: 'no_blood_test',
        latitude: 12.0,
        longitude: 77.0,
        timestamp: ts,
        bloodGroup: null,
      );

      final erss = event.toIndiaErssMessage();
      expect(erss.contains('Blood:'), isFalse);
    });

    test('TEST-SAT-15: Feature Entitlement Gating', () async {
      // 1. Pro Rider has satelliteSosRelay unlocked
      expect(
        FeatureGates.isUnlocked(Feature.satelliteSosRelay, SubscriptionTier.proRider),
        isTrue,
      );

      // 2. Road Captain has satelliteSosRelay unlocked
      expect(
        FeatureGates.isUnlocked(Feature.satelliteSosRelay, SubscriptionTier.roadCaptain),
        isTrue,
      );

      // 3. Tour Operator has satelliteSosRelay unlocked
      expect(
        FeatureGates.isUnlocked(Feature.satelliteSosRelay, SubscriptionTier.tourOperator),
        isTrue,
      );

      // 4. Community tier does not have satelliteSosRelay unlocked
      expect(
        FeatureGates.isUnlocked(Feature.satelliteSosRelay, SubscriptionTier.community),
        isFalse,
      );

      // 5. Community tier still successfully routes to Cellular ERSS 112 emergency handoff!
      final nativeSat = NativeSatelliteHandoffAdapter(isSupportedDevice: true);
      final erssHandoff = CellularEmergencyHandoffAdapter();

      final communityService = SatelliteSosService(
        transports: [nativeSat, erssHandoff],
      );

      final event = await communityService.dispatchSos(
        latitude: 13.0,
        longitude: 80.0,
        tier: SubscriptionTier.community, // Free Community rider
      );

      // Native satellite skipped due to tier, safely routed to India 112 ERSS
      expect(event.deliveryState, equals(SosDeliveryState.handoffRequired));
      expect(event.lastProviderId, equals('india_112_erss'));

      communityService.dispose();
    });
  });
}
