import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/server_emergency_gateway_service.dart';
import 'package:coroute_app/data/services/sms_sender.dart';
import 'package:coroute_app/data/services/sos_transport_adapter.dart';
import 'package:coroute_app/domain/safety/sos_event.dart';
import 'package:coroute_app/domain/safety/sos_packet_codec.dart';

class _FakeNativeSmsSender implements SmsSender {
  SmsCapability cap;
  SmsStatus statusToReturn;
  final List<(String, String)> sent = [];

  _FakeNativeSmsSender({
    this.cap = const SmsCapability(hasTelephony: true, permission: true, simReady: true),
    this.statusToReturn = SmsStatus.sent,
  });

  @override
  Future<SmsCapability> capability() async => cap;

  @override
  Future<SmsStatus> send(String to, String body) async {
    sent.add((to, body));
    return statusToReturn;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FEAT-08: ServerEmergencyGatewayService Platform & Fallback Policy', () {
    test('isServerFallbackNeeded reports true on Apple devices regardless of SIM', () {
      final api = ApiClient(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        storage: const FlutterSecureStorage(),
      );
      final gw = ServerEmergencyGatewayService(
        apiClient: api,
        isAppleDeviceOverride: () => true,
      );

      // Even if native reports telephony ready, iOS/macOS sandbox restricts background SMS
      const fullCap = SmsCapability(hasTelephony: true, permission: true, simReady: true);
      expect(gw.isServerFallbackNeeded(fullCap), isTrue);
    });

    test('isServerFallbackNeeded reports true when native SIM is missing or data-only', () {
      final api = ApiClient(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        storage: const FlutterSecureStorage(),
      );
      final gw = ServerEmergencyGatewayService(
        apiClient: api,
        isAppleDeviceOverride: () => false,
      );

      // Data-only SIM card
      const dataOnlySim = SmsCapability(hasTelephony: false, permission: true, simReady: true);
      expect(gw.isServerFallbackNeeded(dataOnlySim), isTrue);

      // SIM missing / not ready
      const simNotReady = SmsCapability(hasTelephony: true, permission: true, simReady: false);
      expect(gw.isServerFallbackNeeded(simNotReady), isTrue);

      // Standard Android with telephony and SIM ready does not strictly require fallback
      const readySim = SmsCapability(hasTelephony: true, permission: true, simReady: true);
      expect(gw.isServerFallbackNeeded(readySim), isFalse);
    });
  });

  group('FEAT-08: REST Endpoint Invocation (/api/v1/sos/dispatch-external)', () {
    test('dispatchExternal passes payload and parses response correctly', () async {
      http.Request? capturedRequest;
      Map<String, dynamic>? capturedBody;

      final mockHttp = MockClient((req) async {
        if (req.url.path.endsWith('/v1/sos/dispatch-external')) {
          capturedRequest = req;
          capturedBody = jsonDecode(req.body) as Map<String, dynamic>;

          final responseData = {
            'dispatched': true,
            'provider': 'twilio',
            'sentCount': 2,
            'trackingUrl': 'https://coroute.live/e/token-mock-1234567890123456789012',
            'results': [
              {
                'contact': '+919876543210',
                'name': 'Primary Guardian',
                'channel': 'sms',
                'success': true,
                'provider': 'twilio',
                'messageId': 'SM1001',
              },
              {
                'contact': '+919876543210',
                'name': 'Primary Guardian',
                'channel': 'whatsapp',
                'success': true,
                'provider': 'whatsapp_cloud_api',
                'messageId': 'wamid.1002',
              },
            ],
          };
          return http.Response(jsonEncode(responseData), 200);
        }
        return http.Response('{"error":"Not Found"}', 404);
      });

      final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
      await api.setToken('mock-valid-jwt');

      final gw = ServerEmergencyGatewayService(apiClient: api);
      final res = await gw.dispatchExternal(
        tripId: 'TRIP-SOS-001',
        riderId: 'u-12345',
        riderName: 'Priya Patel',
        lat: 12.9716,
        lng: 77.5946,
        speedKmh: 55.0,
        severity: 'CRITICAL',
        bloodGroup: 'O+',
        contacts: const [
          EmergencyContactInfo(phone: '+919876543210', name: 'Primary Guardian'),
        ],
      );

      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.headers['Authorization'], 'Bearer mock-valid-jwt');
      expect(capturedBody!['tripId'], 'TRIP-SOS-001');
      expect(capturedBody!['riderId'], 'u-12345');
      expect(capturedBody!['lat'], 12.9716);
      expect(capturedBody!['lng'], 77.5946);
      expect(capturedBody!['bloodGroup'], 'O+');

      expect(res.dispatched, isTrue);
      expect(res.provider, 'twilio');
      expect(res.sentCount, 2);
      expect(res.trackingUrl, contains('/e/'));
      expect(res.results.length, 2);
      expect(res.results.first.channel, 'sms');
      expect(res.results.last.channel, 'whatsapp');
    });

    test('dispatchFromSosEvent translates SosEvent and invokes gateway', () async {
      final mockHttp = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'dispatched': true,
            'provider': 'infobip',
            'sentCount': 2,
            'trackingUrl': 'https://coroute.live/e/token123',
            'results': [],
          }),
          200,
        );
      });

      final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
      await api.setToken('token');
      final gw = ServerEmergencyGatewayService(apiClient: api);

      final event = SosEvent(
        id: 'SOS-EVENT-99',
        latitude: 13.0827,
        longitude: 80.2707,
        timestamp: DateTime.now().toUtc(),
        severity: SosSeverity.crashAuto,
        bloodGroup: 'B-',
      );

      final transRes = await gw.dispatchFromSosEvent(
        event,
        tripId: 'TRIP-GROUP-1',
        riderId: 'rider-abc',
        riderName: 'Karthik',
        contacts: const [
          EmergencyContactInfo(phone: '+919000000001', name: 'Dad'),
        ],
      );

      expect(transRes.success, isTrue);
      expect(transRes.state, SosDeliveryState.providerAccepted);
      expect(transRes.providerId, contains('server_emergency_gateway_infobip'));
    });
  });

  group('FEAT-08: ServerFallbackSmsSender Transparent Integration', () {
    test('ServerFallbackSmsSender guarantees capability on Apple / data-only devices', () async {
      final fakeNative = _FakeNativeSmsSender(
        cap: const SmsCapability(hasTelephony: false, permission: false, simReady: false),
      );

      final api = ApiClient(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        storage: const FlutterSecureStorage(),
      );
      final gw = ServerEmergencyGatewayService(
        apiClient: api,
        nativeSender: fakeNative,
        isAppleDeviceOverride: () => true,
      );

      final fallbackSender = gw.createFallbackSmsSender();
      final cap = await fallbackSender.capability();

      // Cloud gateway guarantees readiness to the application layer
      expect(cap.ready, isTrue);
      expect(cap.hasTelephony, isTrue);
      expect(cap.simReady, isTrue);
    });

    test('ServerFallbackSmsSender falls back to server when native SMS fails', () async {
      final fakeNative = _FakeNativeSmsSender(
        cap: const SmsCapability(hasTelephony: true, permission: true, simReady: true),
        statusToReturn: SmsStatus.failed, // Native Android SMS failed (e.g. out of prepaid balance)
      );

      bool serverCalled = false;
      final mockHttp = MockClient((req) async {
        if (req.url.path.endsWith('/v1/sos/dispatch-external')) {
          serverCalled = true;
          return http.Response(
            jsonEncode({
              'dispatched': true,
              'provider': 'twilio',
              'sentCount': 1,
              'results': [],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
      await api.setToken('token');
      final gw = ServerEmergencyGatewayService(
        apiClient: api,
        nativeSender: fakeNative,
        isAppleDeviceOverride: () => false,
      );

      final fallbackSender = gw.createFallbackSmsSender(
        currentTripId: () => 'TRIP-BAL-0',
        currentRiderId: () => 'rider-low-balance',
        currentRiderName: () => 'Arjun',
        currentPosition: () => (12.9716, 77.5946),
      );

      final status = await fallbackSender.send('+919876543210', 'Help needed');

      expect(fakeNative.sent.length, 1); // Native was attempted first
      expect(serverCalled, isTrue); // Server fallback was triggered transparently
      expect(status, SmsStatus.sent); // Overall status succeeded via cloud gateway
    });

    test('ServerFallbackSmsSender routes directly to server on Apple devices without calling native', () async {
      final fakeNative = _FakeNativeSmsSender(
        cap: const SmsCapability(hasTelephony: false, permission: false, simReady: false),
      );

      bool serverCalled = false;
      final mockHttp = MockClient((req) async {
        if (req.url.path.endsWith('/v1/sos/dispatch-external')) {
          serverCalled = true;
          return http.Response(
            jsonEncode({
              'dispatched': true,
              'provider': 'webhook',
              'sentCount': 1,
              'results': [],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
      await api.setToken('token');
      final gw = ServerEmergencyGatewayService(
        apiClient: api,
        nativeSender: fakeNative,
        isAppleDeviceOverride: () => true, // iOS device
      );

      final fallbackSender = gw.createFallbackSmsSender();
      final status = await fallbackSender.send('+919876543210', 'iOS distress');

      expect(fakeNative.sent.isEmpty, isTrue); // Native skipped on Apple
      expect(serverCalled, isTrue);
      expect(status, SmsStatus.sent);
    });
  });

  group('FEAT-08: CellularEmergencyHandoffAdapter & Transport Orchestration', () {
    test('CellularEmergencyHandoffAdapter uses serverGateway fallback if provided', () async {
      final mockHttp = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'dispatched': true,
            'provider': 'twilio',
            'sentCount': 2,
            'results': [],
          }),
          200,
        );
      });

      final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
      await api.setToken('token');
      final gw = ServerEmergencyGatewayService(apiClient: api);

      final adapter = CellularEmergencyHandoffAdapter(
        serverGateway: gw,
      );

      final event = SosEvent(
        id: 'SOS-ADAPTER-1',
        latitude: 12.9716,
        longitude: 77.5946,
        timestamp: DateTime.now().toUtc(),
        severity: SosSeverity.manual,
      );

      final res = await adapter.transmit(event);

      expect(res.success, isTrue);
      expect(res.state, SosDeliveryState.providerAccepted);
      expect(res.providerId, contains('server_emergency_gateway'));
    });

    test('CellularEmergencyHandoffAdapter falls back to 112 dialer when serverGateway fails', () async {
      final mockHttp = MockClient((req) async => http.Response('Server Error', 500));
      final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
      final gw = ServerEmergencyGatewayService(apiClient: api);

      bool dialerTriggered = false;
      final adapter = CellularEmergencyHandoffAdapter(
        serverGateway: gw,
        dialerLauncher: () async {
          dialerTriggered = true;
          return true;
        },
      );

      final event = SosEvent(
        id: 'SOS-FALLBACK-112',
        latitude: 12.9716,
        longitude: 77.5946,
        timestamp: DateTime.now().toUtc(),
        severity: SosSeverity.manual,
      );

      final res = await adapter.transmit(event);

      // Returns handoffRequired for 112 ERSS
      expect(res.state, SosDeliveryState.handoffRequired);
      expect(res.providerId, 'india_112_erss');
      expect(dialerTriggered, isTrue);
    });

    test('ServerEmergencyGatewayTransportAdapter acts as standalone transport', () async {
      final mockHttp = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'dispatched': true,
            'provider': 'whatsapp_cloud_api',
            'sentCount': 1,
            'results': [],
          }),
          200,
        );
      });

      final api = ApiClient(httpClient: mockHttp, storage: const FlutterSecureStorage());
      await api.setToken('token');
      final gw = ServerEmergencyGatewayService(apiClient: api);

      final transport = ServerEmergencyGatewayTransportAdapter(
        gatewayService: gw,
        tripId: 'TRIP-STANDALONE',
        riderId: 'rider-1',
        riderName: 'Sanjay',
      );

      expect(transport.providerId, 'server_emergency_gateway');
      expect(await transport.isAvailable(), isTrue);

      final event = SosEvent(
        id: 'SOS-TRANSPORT-1',
        latitude: 12.9716,
        longitude: 77.5946,
        timestamp: DateTime.now().toUtc(),
      );

      final res = await transport.transmit(event);
      expect(res.success, isTrue);
      expect(res.state, SosDeliveryState.providerAccepted);
    });
  });
}
