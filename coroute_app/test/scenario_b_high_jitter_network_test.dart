import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/pending_sos.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/domain/tracking/track_filter.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';
import 'package:coroute_app/presentation/widgets/connection_banner.dart';
import 'package:coroute_app/presentation/widgets/emergency_sos_sheet.dart';

/// Controllable Realtime mock for simulating connection jitter and duplicate packets.
class _JitteryRt extends RealtimeService {
  final List<Map<String, dynamic>> sentMessages = [];
  bool connected = true;
  RealtimeState customState = RealtimeState.connected;
  final StreamController<Map<String, dynamic>> _events = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  @override
  bool get isConnected => connected;
  @override
  RealtimeState get state => customState;
  @override
  bool supports(String feature) => true;

  @override
  bool send(Map<String, dynamic> message) {
    if (!connected) return false;
    sentMessages.add(message);
    return true;
  }

  void emit(Map<String, dynamic> msg) => _events.add(msg);

  void simulateDrop() {
    connected = false;
    customState = RealtimeState.disconnected;
  }

  void simulateReconnect() {
    connected = true;
    customState = RealtimeState.connected;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/charging'),
      (call) async => null,
    );
  });

  group('Scenario B: High-Jitter Patchy Cellular Network', () {
    test('TrackFilter strictly rejects out-of-order, duplicate, and teleported fixes', () {
      final filter = TrackFilter(maxAccuracyM: 30, maxKmh: 250, minMoveM: 3);

      // Initial fix at t = 10000ms
      final p1 = TrackPoint(ts: 10000, lat: 12.9716, lng: 77.5946, speedKmh: 45, accuracyM: 8);
      expect(filter.accept(p1), isTrue);
      expect(filter.last, equals(p1));

      // 1. Out-of-order delayed packet arrives with earlier timestamp (t = 8000ms)
      final pOld = TrackPoint(ts: 8000, lat: 12.9710, lng: 77.5940, speedKmh: 40, accuracyM: 8);
      expect(filter.accept(pOld), isFalse, reason: 'Packets with timestamp <= last timestamp are rejected');

      // 2. Duplicate packet arrives with identical timestamp (t = 10000ms)
      final pDup = TrackPoint(ts: 10000, lat: 12.9716, lng: 77.5946, speedKmh: 45, accuracyM: 8);
      expect(filter.accept(pDup), isFalse, reason: 'Duplicate timestamp rejected');

      // 3. Teleportation caused by cellular tower triangulation jump (distance 5 km in 2 sec => 9000 km/h)
      final pTeleport = TrackPoint(ts: 12000, lat: 13.0160, lng: 77.5946, speedKmh: 80, accuracyM: 10);
      expect(filter.accept(pTeleport), isFalse, reason: 'Physically impossible teleportation jump rejected');

      // 4. Minor GPS drift while bike is parked (moved 1.5m < minMoveM 3m in 5 sec, speed 0)
      final pParked = TrackPoint(ts: 15000, lat: 12.97161, lng: 77.59461, speedKmh: 0, accuracyM: 8);
      expect(filter.accept(pParked), isFalse, reason: 'Stationary drift under minMoveM rejected');

      // 5. Valid subsequent fix arrives in-order
      final pValid = TrackPoint(ts: 20000, lat: 12.9730, lng: 77.5946, speedKmh: 50, accuracyM: 8);
      expect(filter.accept(pValid), isTrue);
    });

    test('Duplicate chat messages & out-of-order socket frames deduped by ConvoyService', () async {
      final initialConvoy = ConvoyModel(
        groupId: 'GRP-JITTER',
        name: 'Western Ghats Ride',
        joinCode: '112233',
        createdByUserId: 'u_me',
        createdByUserName: 'My Rider',
        createdAtEpochMs: 1000,
        riders: {
          'u_me': RiderModel(userId: 'u_me', name: 'My Rider', lat: 12.9, lng: 77.5, lastSeenEpochMs: 1000),
          'u_friend': RiderModel(userId: 'u_friend', name: 'Friend', lat: 12.91, lng: 77.51, lastSeenEpochMs: 1000),
        },
      );

      final api = ApiClient(
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/convoys/active')) {
            return http.Response(jsonEncode({'convoy': initialConvoy.toJson()}), 200);
          }
          return http.Response('{}', 200);
        }),
        storage: const FlutterSecureStorage(),
      );
      final rt = _JitteryRt();
      final convoyService = ConvoyService(api, rt, TripStorageService(api));
      await convoyService.startSession(token: 'mock_token', userId: 'u_me');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Network jitter delivers same chat message 3 times in rapid succession
      final msgJson = {
        'messageId': 'MSG-XYZ-123',
        'groupId': 'GRP-JITTER',
        'userId': 'u_friend',
        'userName': 'Friend',
        'text': 'Caution: gravel on right hairpin bend!',
        'timestamp': 2000,
      };

      rt.emit({'type': 'MESSAGE', 'message': msgJson});
      rt.emit({'type': 'MESSAGE', 'message': msgJson});
      rt.emit({'type': 'MESSAGE', 'message': msgJson});
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final active = convoyService.activeConvoy!;
      expect(active.messages, hasLength(1), reason: 'Duplicate messages with same messageId are deduped');
      expect(active.messages.first.text, 'Caution: gravel on right hairpin bend!');

      convoyService.dispose();
      rt.dispose();
    });

    test('Emergency SOS broadcast survives connection drops, queues locally, and confirms idempotently', () async {
      final initialConvoy = ConvoyModel(
        groupId: 'GRP-SOS-JITTER',
        name: 'Monsoon Highway',
        joinCode: '998877',
        createdByUserId: 'u_me',
        createdByUserName: 'Solo Rider',
        createdAtEpochMs: 5000,
        riders: {
          'u_me': RiderModel(userId: 'u_me', name: 'Solo Rider', lat: 12.9, lng: 77.5, lastSeenEpochMs: 5000),
        },
      );

      final api = ApiClient(
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/convoys/active')) {
            return http.Response(jsonEncode({'convoy': initialConvoy.toJson()}), 200);
          }
          return http.Response('{}', 200);
        }),
        storage: const FlutterSecureStorage(),
      );

      final rt = _JitteryRt();
      final convoyService = ConvoyService(api, rt, TripStorageService(api));
      await convoyService.startSession(token: 'test_token', userId: 'u_me');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // 1. Connection drops completely (canyon network drop)
      rt.simulateDrop();
      expect(convoyService.isOnline, isFalse);

      // 2. Rider triggers manual SOS while disconnected
      final delivery = convoyService.triggerSosAlert(
        userId: 'u_me',
        userName: 'Solo Rider',
        lat: 12.920,
        lng: 77.580,
      );
      expect(delivery, SosDelivery.queued);
      expect(convoyService.pendingSos, isNotNull);
      final clientId = convoyService.pendingSos!.clientId;
      expect(clientId, startsWith('u_me-'));

      // 3. Automatic crash detector triggers during the blackout, upgrading the queued SOS
      convoyService.raiseSos(
        type: SosTypes.crash,
        lat: 12.9205,
        lng: 77.5805,
        auto: true,
        speedBeforeKmh: 62.0,
        impactG: 7.1,
        occurredAtMs: 1700000005000,
      );
      // Client ID must remain identical to preserve server deduplication
      expect(convoyService.pendingSos!.clientId, clientId);
      expect(convoyService.pendingSos!.auto, isTrue);
      expect(convoyService.pendingSos!.impactG, 7.1);

      // Verify SOS is persisted on disk across process crashes
      final stored = await PendingSosStore.load();
      expect(stored, isNotNull);
      expect(stored!.clientId, clientId);
      expect(stored.impactG, 7.1);

      // 4. Cellular reconnects, SNAPSHOT arrives -> triggers automatic send of pending SOS
      rt.simulateReconnect();
      rt.emit({
        'type': 'SNAPSHOT',
        'convoy': initialConvoy.toJson(),
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Verify SOS was dispatched over websocket with matching clientId
      expect(rt.sentMessages.any((m) => m['type'] == 'SOS' && m['clientId'] == clientId), isTrue);

      // 5. High-jitter delivers multiple duplicate ALERT echoes from gateway
      final alertJson = {
        'alertId': 'ALERT-SRV-999',
        'clientId': clientId,
        'userId': 'u_me',
        'userName': 'Solo Rider',
        'alertType': 'CRASH',
        'auto': true,
        'timestamp': 1700000006000,
        'resolved': false,
      };

      // Emit echo #1
      rt.emit({'type': 'ALERT', 'alert': alertJson});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(convoyService.pendingSos, isNull, reason: 'Pending SOS cleared after confirmation');
      expect(await PendingSosStore.load(), isNull, reason: 'Disk storage cleared');
      expect(convoyService.activeConvoy!.activeAlerts, hasLength(1));

      // Emit duplicate echo #2 (network jitter echo)
      rt.emit({'type': 'ALERT', 'alert': alertJson});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(convoyService.activeConvoy!.activeAlerts, hasLength(1), reason: 'Duplicate alert not inserted twice');

      convoyService.dispose();
      rt.dispose();
    });

    test('UI status fidelity: status text progresses strictly from waiting to sending to delivered', () {
      // 1. Offline, waiting for signal
      final waiting = EmergencySosSheet.statusFor(
        hasService: true,
        pending: true,
        online: false,
        hasOpenAlert: false,
      );
      expect(waiting, SosSheetStatus.waitingForSignal);
      final (waitingTitle, _) = EmergencySosSheet.textFor(waiting);
      expect(waitingTitle, 'No signal. SOS not sent yet');

      // 2. Connected, actively transmitting
      final sending = EmergencySosSheet.statusFor(
        hasService: true,
        pending: true,
        online: true,
        hasOpenAlert: false,
      );
      expect(sending, SosSheetStatus.sending);
      final (sendingTitle, _) = EmergencySosSheet.textFor(sending);
      expect(sendingTitle, 'Sending your SOS to the convoy...');

      // 3. Confirmed by server echo (pending is false, hasOpenAlert is true)
      final delivered = EmergencySosSheet.statusFor(
        hasService: true,
        pending: false,
        online: true,
        hasOpenAlert: true,
      );
      expect(delivered, SosSheetStatus.delivered);
      final (deliveredTitle, _) = EmergencySosSheet.textFor(delivered);
      expect(deliveredTitle, 'SOS delivered to your convoy');

      // 4. Connection banner top bar states
      const now = 1700000000000;
      expect(
        ConnectionBanner.status(state: RealtimeState.disconnected, nowMs: now, sosWaiting: true),
        'SOS waiting to send',
      );
      expect(
        ConnectionBanner.status(state: RealtimeState.connected, nowMs: now, sosWaiting: true),
        'Sending your SOS',
      );
    });
  });
}
