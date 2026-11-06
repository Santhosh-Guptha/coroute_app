import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/data/services/track_recorder.dart';
import 'package:coroute_app/data/services/track_uploader.dart';
import 'package:coroute_app/data/local/track_queue.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

/// Mock Realtime Service that simulates network drops, reconnects, and message captures.
class _MockNetworkRealtimeService extends RealtimeService {
  bool _mockConnected = true;
  final List<Map<String, dynamic>> sentMessages = [];
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  bool get isConnected => _mockConnected;

  @override
  RealtimeState get state =>
      _mockConnected ? RealtimeState.connected : RealtimeState.disconnected;

  @override
  bool supports(String feature) => true;

  @override
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  @override
  bool send(Map<String, dynamic> message) {
    if (!_mockConnected) return false;
    sentMessages.add(message);
    return true;
  }

  void simulateDisconnect() {
    _mockConnected = false;
    notifyListeners();
  }

  void simulateReconnect() {
    _mockConnected = true;
    notifyListeners();
  }

  @override
  void joinRoom(String groupId, {String? prevExit, int? prevAliveAt}) {
    super.joinRoom(groupId, prevExit: prevExit, prevAliveAt: prevAliveAt);
    if (isConnected) {
      emitEvent({'type': 'SNAPSHOT'});
    }
  }

  void emitEvent(Map<String, dynamic> event) {
    _eventController.add(event);
  }

  @override
  void dispose() {
    _eventController.close();
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockNetworkRealtimeService rt;
  late ApiClient api;
  late TripStorageService trips;
  late MemoryTrackQueue queue;
  late TrackRecorder recorder;
  late ConvoyService convoyService;

  const testGroupId = 'grp_integration_test';
  const myUserId = 'user_rider_agent7';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    rt = _MockNetworkRealtimeService();
    queue = MemoryTrackQueue();

    final client = MockClient((request) async {
      if (request.url.path.contains('/convoys/active') ||
          request.url.path.contains('/convoys/$testGroupId')) {
        return http.Response(
          jsonEncode({
            'convoy': {
              'groupId': testGroupId,
              'name': 'Western Ghats Expedition',
              'joinCode': '123456',
              'createdByUserId': 'lead_user',
              'createdByUserName': 'Vikram',
              'createdAtEpochMs': 1700000000000,
              'riders': {
                myUserId: {
                  'userId': myUserId,
                  'name': 'Agent 7 Rider',
                  'lat': 12.9716,
                  'lng': 77.5946,
                  'speedKmh': 35.0,
                  'heading': 90.0,
                  'lastSeenEpochMs': 1700000000000,
                  'batteryLevel': 85,
                  'isCharging': false,
                },
                'peer_user_1': {
                  'userId': 'peer_user_1',
                  'name': 'Rahul',
                  'lat': 12.9720,
                  'lng': 77.5950,
                  'speedKmh': 40.0,
                  'heading': 90.0,
                  'lastSeenEpochMs': 1700000005000,
                  'batteryLevel': 90,
                  'isCharging': false,
                },
              },
              'activeAlerts': [],
              'plannedStops': [],
            }
          }),
          200,
        );
      } else if (request.url.path.contains('/tracks')) {
        return http.Response(jsonEncode({'acked': [0, 1, 2], 'rejected': []}), 200);
      }
      return http.Response('{}', 200);
    });

    api = ApiClient(httpClient: client, storage: const FlutterSecureStorage());
    trips = TripStorageService(api);
    final uploader = TrackUploader(api, queue);
    recorder = TrackRecorder(queue, uploader);

    convoyService = ConvoyService(
      api,
      rt,
      trips,
      recorder: recorder,
    );
  });

  tearDown(() {
    convoyService.dispose();
  });

  group('ISSUE-6G: Network Recovery Integration Tests', () {
    test('Reconnect maintains active trip and does not interrupt tracking or regress location', () async {
      await convoyService.startSession(token: 'token_net_test', userId: myUserId);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(convoyService.activeGroupId, testGroupId);
      expect(convoyService.isOnline, isTrue);

      // 1. Simulate rider moving forward offline
      final offlineFix = TrackPoint(
        ts: 1700000050000,
        lat: 13.0500, // Newer position
        lng: 77.6500,
        speedKmh: 65.0,
      );
      recorder.onFix(offlineFix);

      // Update local rider model with new offline fix
      final current = convoyService.activeConvoy!.riders[myUserId]!;
      convoyService.updateRiderLocallyForTesting(
        current.copyWith(
          lat: 13.0500,
          lng: 77.6500,
          speedKmh: 65.0,
          lastSeenEpochMs: 1700000050000,
        ),
      );

      // 2. Network disconnects (enters cellular dead zone / mountain tunnel)
      rt.simulateDisconnect();
      expect(convoyService.isOnline, isFalse);
      expect(convoyService.activeGroupId, testGroupId, reason: 'Active trip must survive network drop');

      // 3. Network reconnects
      rt.simulateReconnect();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(convoyService.isOnline, isTrue);
      expect(convoyService.activeGroupId, testGroupId, reason: 'Trip must NOT be restarted on reconnect');

      // 4. Server sends SNAPSHOT with older coordinates (12.9716, 77.5946) for me, and newer (12.9780) for peer
      rt.emitEvent({
        'type': 'SNAPSHOT',
        'convoy': {
          'groupId': testGroupId,
          'name': 'Western Ghats Expedition',
          'joinCode': '123456',
          'createdByUserId': 'lead_user',
          'createdByUserName': 'Vikram',
          'createdAtEpochMs': 1700000000000,
          'riders': {
            myUserId: {
              'userId': myUserId,
              'name': 'Agent 7 Rider',
              'lat': 12.9716, // Old position from pre-disconnect
              'lng': 77.5946,
              'speedKmh': 35.0,
              'lastSeenEpochMs': 1700000000000,
            },
            'peer_user_1': {
              'userId': 'peer_user_1',
              'name': 'Rahul',
              'lat': 12.9780,
              'lng': 77.5990,
              'speedKmh': 42.0,
              'lastSeenEpochMs': 1700000060000,
            },
          },
          'activeAlerts': [],
          'plannedStops': [],
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Verify that local rider position was NOT regressed to stale server position
      final meAfterSnapshot = convoyService.activeConvoy!.riders[myUserId]!;
      expect(meAfterSnapshot.lat, 13.0500, reason: 'Local fresher coordinates must be preserved on SNAPSHOT');
      expect(meAfterSnapshot.lng, 77.6500);
      expect(meAfterSnapshot.lastSeenEpochMs, 1700000050000);

      // Peer coordinates should be updated from server snapshot
      final peer = convoyService.activeConvoy!.riders['peer_user_1']!;
      expect(peer.lat, 12.9780);
      expect(peer.speedKmh, 42.0);
    });

    test('Replay queued events safely without duplicate transactions', () async {
      await convoyService.startSession(token: 'token_outbox_test', userId: myUserId);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // 1. Disconnect and queue outbox events
      rt.simulateDisconnect();
      rt.sentMessages.clear();

      convoyService.sendGroupMessage(
        senderId: myUserId,
        senderName: 'Agent 7',
        text: 'Regroup at tea stall',
      );
      convoyService.requestWait('Agent 7');

      // Verify outbox queued items
      expect(convoyService.outboxCount, 2);
      expect(rt.sentMessages, isEmpty, reason: 'Must not transmit while offline');

      // 2. Reconnect: outbox flushes queued events with clientIds
      rt.simulateReconnect();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(rt.sentMessages.length, greaterThanOrEqualTo(2));
      final msgChat = rt.sentMessages.firstWhere((m) => m['type'] == 'CHAT');
      final msgWait = rt.sentMessages.firstWhere((m) => m['type'] == 'WAIT');

      expect(msgChat['clientId'], isNotNull);
      expect(msgWait['clientId'], isNotNull);

      // 3. Server sends duplicate ACK and duplicate echo frames
      final chatClientId = msgChat['clientId'];
      rt.emitEvent({'type': 'ACK', 'clientId': chatClientId, 'duplicate': true});
      rt.emitEvent({'type': 'ACK', 'clientId': chatClientId, 'duplicate': true}); // Duplicate ACK

      // Server broadcasts message back
      rt.emitEvent({
        'type': 'MESSAGE',
        'message': {
          'messageId': 'msg_001',
          'clientId': chatClientId,
          'senderId': myUserId,
          'senderName': 'Agent 7',
          'text': 'Regroup at tea stall',
          'timestamp': 1700000010000,
        }
      });
      // Duplicate message frame
      rt.emitEvent({
        'type': 'MESSAGE',
        'message': {
          'messageId': 'msg_001',
          'clientId': chatClientId,
          'senderId': myUserId,
          'senderName': 'Agent 7',
          'text': 'Regroup at tea stall',
          'timestamp': 1700000010000,
        }
      });

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Verify no duplicate messages in convoy
      final matchingMessages = convoyService.activeConvoy!.messages.where((m) => m.text == 'Regroup at tea stall');
      expect(matchingMessages.length, 1, reason: 'Duplicate event replay must be idempotently deduplicated');
    });

    test('Refresh group members and restore server state on recovery', () async {
      await convoyService.startSession(token: 'token_refresh_test', userId: myUserId);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Disconnect
      rt.simulateDisconnect();

      // Trigger restoreServerState upon network recovery
      rt.simulateReconnect();
      await convoyService.restoreServerState();

      expect(convoyService.activeConvoy, isNotNull);
      expect(convoyService.activeConvoy!.riders.containsKey('peer_user_1'), isTrue);

      // Test explicit refreshGroupMembers
      final refreshed = await convoyService.refreshGroupMembers();
      expect(refreshed, isTrue);
      expect(convoyService.activeConvoy!.riders.length, greaterThanOrEqualTo(2));
    });
  });
}

extension on ConvoyService {
  void updateRiderLocallyForTesting(RiderModel rider) {
    final gid = activeGroupId;
    if (gid == null) return;
    final convoy = activeConvoy;
    if (convoy == null) return;
    final riders = Map<String, RiderModel>.from(convoy.riders)..[rider.userId] = rider;
    setActiveConvoyForTesting(convoy.copyWith(riders: riders));
  }
}
