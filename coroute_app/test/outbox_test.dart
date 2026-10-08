import 'dart:async';
import 'dart:convert';

import 'package:coroute_app/core/constants/net_constants.dart';
import 'package:coroute_app/data/local/outbox_store.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/outbox_item.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A realtime link without a network: records what is sent, features can be switched.
class FakeRt extends RealtimeService {
  FakeRt({Set<String> features = const {}, this._connected = true})
      : features = {...features};

  Set<String> features;
  bool _connected;
  final List<Map<String, dynamic>> sent = [];
  final StreamController<Map<String, dynamic>> _ctrl = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _ctrl.stream;
  @override
  bool get isConnected => _connected;
  @override
  RealtimeState get state => _connected ? RealtimeState.connected : RealtimeState.disconnected;
  @override
  Set<String> get serverFeatures => features;
  @override
  bool supports(String feature) => features.contains(feature);
  @override
  bool send(Map<String, dynamic> message) {
    if (!_connected) return false;
    sent.add(message);
    return true;
  }

  @override
  void connect(String token, {bool adminMode = false}) {}
  @override
  void disconnect() {}
  @override
  void joinRoom(String groupId, {String? prevExit, int? prevAliveAt}) {}
  @override
  void leaveRoom({bool leaveConvoy = false}) {}
  @override
  bool sendBye(String reason) => false;

  void emit(Map<String, dynamic> m) => _ctrl.add(m);

  void setConnected(bool v) {
    _connected = v;
    notifyListeners();
  }

  List<Map<String, dynamic>> sentOf(String type) => sent.where((m) => m['type'] == type).toList();
}

const gid = 'GRP-1';
const me = 'usr_me';

ConvoyModel convoyJsonModel() => ConvoyModel(
      groupId: gid,
      name: 'Hill run',
      joinCode: '123456',
      createdByUserId: 'usr_lead',
      createdByUserName: 'Lead',
      createdAtEpochMs: 1,
      riders: {
        me: RiderModel(userId: me, name: 'Me', lat: 12.9, lng: 77.5, lastSeenEpochMs: 1),
        'usr_k': RiderModel(userId: 'usr_k', name: 'Kiran', lat: 12.95, lng: 77.55, lastSeenEpochMs: 1),
      },
      activeAlerts: [
        SosAlertModel(alertId: 'SOS-K', userId: 'usr_k', userName: 'Kiran', lat: 12.95, lng: 77.55, timestamp: 1),
        SosAlertModel(alertId: 'SOS-ME', userId: me, userName: 'Me', lat: 12.9, lng: 77.5, timestamp: 1),
      ],
    );

Future<void> settle([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

Future<ConvoyService> startService(FakeRt rt, {bool resetPrefs = true, int Function()? clock}) async {
  if (resetPrefs) SharedPreferences.setMockInitialValues({});
  final api = ApiClient(
    httpClient: MockClient((req) async {
      if (req.url.path.endsWith('/convoys/active')) return http.Response(jsonEncode({'convoy': convoyJsonModel().toJson()}), 200);
      return http.Response('{}', 200);
    }),
    storage: const FlutterSecureStorage(),
  );
  final c = ConvoyService(api, rt, TripStorageService(api), clock: clock);
  await c.startSession(token: 't', userId: me);
  await settle();
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/charging'),
      (call) async => null,
    );
  });

  test('items go out in order with client ids and leave the outbox on ACK', () async {
    final rt = FakeRt(features: {ProtocolFeatures.ack});
    final c = await startService(rt);
    c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'one');
    c.requestWait('Me');
    c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'two');
    final types = rt.sent.map((m) => m['type']).where((t) => t == 'CHAT' || t == 'WAIT').toList();
    expect(types, ['CHAT', 'WAIT', 'CHAT']);
    final chats = rt.sentOf('CHAT');
    expect(chats.first['text'], 'one');
    expect(chats.first['clientId'], isNotEmpty);
    expect(RegExp(r'^[A-Za-z0-9_.:-]{1,64}$').hasMatch(chats.first['clientId'] as String), isTrue);
    expect(chats.first['sentAt'], isA<int>());
    expect(c.outboxCount, 3);
    expect(c.outbox.every((i) => i.state == OutboxState.sending), isTrue);
    expect(c.isQueued(chats.first['clientId'] as String), isTrue);

    rt.emit({'type': 'ACK', 'clientId': chats.first['clientId'], 'duplicate': false, 'ts': 1});
    await settle();
    expect(c.outboxCount, 2);
    expect(c.isQueued(chats.first['clientId'] as String), isFalse);
    expect(c.outbox.first.type, 'WAIT');
    c.dispose();
  });

  test('older gateway (no ack feature): done once sent, no client id on the wire', () async {
    final rt = FakeRt();
    final c = await startService(rt);
    c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'hello');
    c.toggleStopVisited('s1', true);
    expect(rt.sentOf('CHAT').single.containsKey('clientId'), isFalse);
    expect(rt.sentOf('CHAT').single.containsKey('sentAt'), isFalse);
    expect(rt.sentOf('STOP_VISITED').single['stopId'], 's1');
    expect(c.outboxCount, 0);
    // No SOS replies or check-ins against an older gateway.
    expect(c.respondToSos('SOS-K', SosResponseKind.going), isFalse);
    expect(c.sendCheckIn(CheckInResult.ok), isFalse);
    c.dispose();
  });

  test('offline: kept as waiting, sent in order after the SNAPSHOT that follows a reconnect', () async {
    final rt = FakeRt(features: {ProtocolFeatures.ack}, connected: false);
    final c = await startService(rt);
    c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'a');
    c.toggleStopVisited('s1', true);
    c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'b');
    expect(rt.sent, isEmpty);
    expect(c.outbox.map((i) => i.state).toSet(), {OutboxState.waiting});
    expect(c.outbox.map((i) => i.type).toList(), ['CHAT', 'STOP_VISITED', 'CHAT']);

    rt.setConnected(true);
    expect(rt.sent, isEmpty, reason: 'nothing before the room is joined again');
    rt.emit({'type': 'SNAPSHOT'});
    await settle();
    expect(rt.sent.map((m) => m['type']).toList(), ['CHAT', 'STOP_VISITED', 'CHAT']);
    expect(rt.sent.first['text'], 'a');

    // Link drops before the ACK: back to waiting, sent again with the same ids.
    final ids = rt.sent.map((m) => m['clientId']).toList();
    rt.setConnected(false);
    expect(c.outbox.every((i) => i.state == OutboxState.waiting), isTrue);
    rt.setConnected(true);
    rt.emit({'type': 'SNAPSHOT'});
    await settle(1200); // the drip allows 4 per second
    expect(rt.sent.skip(3).map((m) => m['clientId']).toList(), ids);
    c.dispose();
  });

  test('a newer status replaces an older one still waiting', () async {
    final rt = FakeRt(features: {ProtocolFeatures.ack}, connected: false);
    final c = await startService(rt);
    c.updateStatusReason(userId: me, reason: 'FUELING');
    c.updateStatusReason(userId: me, reason: 'REST_BREAK', message: 'tea');
    final status = c.outbox.where((i) => i.type == 'STATUS').toList();
    expect(status.length, 1);
    expect(status.single.payload['statusReason'], 'REST_BREAK');
    expect(status.single.payload['statusMessage'], 'tea');
    c.dispose();
  });

  test('a WAIT older than 3 min is dropped at send time; chat still goes', () async {
    var now = 1700000000000;
    final rt = FakeRt(features: {ProtocolFeatures.ack}, connected: false);
    final c = await startService(rt, clock: () => now);
    c.requestWait('Me');
    c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'late');
    now += NetConstants.outboxWaitMaxAge.inMilliseconds + 1000;
    rt.setConnected(true);
    rt.emit({'type': 'SNAPSHOT'});
    await settle();
    expect(rt.sentOf('WAIT'), isEmpty);
    expect(rt.sentOf('CHAT').single['text'], 'late');
    expect(c.outbox.where((i) => i.type == 'WAIT'), isEmpty);
    c.dispose();
  });

  test('cap: at most 100 items, the oldest chat goes first', () async {
    final rt = FakeRt(features: {ProtocolFeatures.ack}, connected: false);
    final c = await startService(rt);
    c.requestWait('Me');
    for (var i = 0; i < NetConstants.outboxMaxItems; i++) {
      c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'm$i');
    }
    expect(c.outboxCount, NetConstants.outboxMaxItems);
    expect(c.outbox.first.type, 'WAIT');
    expect(c.outbox[1].payload['text'], 'm1');
    expect(c.outbox.last.payload['text'], 'm${NetConstants.outboxMaxItems - 1}');
    c.dispose();
  });

  test('survives an app restart (disk), then is sent', () async {
    final rt = FakeRt(features: {ProtocolFeatures.ack}, connected: false);
    final c = await startService(rt);
    c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'kept');
    c.toggleStopVisited('s2', true);
    await settle(50);
    c.dispose();
    expect((await OutboxStore().load()).length, 2);

    final rt2 = FakeRt(features: {ProtocolFeatures.ack});
    final c2 = await startService(rt2, resetPrefs: false);
    // Loaded at start and sent once the ride is active again (still listed until the ACK).
    expect(c2.outbox.map((i) => i.type).toList(), ['CHAT', 'STOP_VISITED']);
    expect(rt2.sentOf('CHAT').first['text'], 'kept');
    expect(rt2.sentOf('STOP_VISITED').first['stopId'], 's2');
    c2.dispose();
  });

  test('cleared when the ride ends (memory and disk)', () async {
    final rt = FakeRt(features: {ProtocolFeatures.ack}, connected: false);
    final c = await startService(rt);
    c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'x');
    await settle();
    rt.emit({'type': 'TRIP_STATUS', 'tripStatus': 'ENDED'});
    await settle(50);
    expect(c.outboxCount, 0);
    expect(await OutboxStore().load(), isEmpty);
    c.dispose();
  });

  test('drip: at most 4 per second after a reconnect', () async {
    final rt = FakeRt(features: {ProtocolFeatures.ack}, connected: false);
    final c = await startService(rt);
    for (var i = 0; i < 10; i++) {
      c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'd$i');
    }
    rt.setConnected(true);
    rt.emit({'type': 'SNAPSHOT'});
    await settle(100);
    expect(rt.sentOf('CHAT').length, 4);
    await settle(1100);
    expect(rt.sentOf('CHAT').length, 8);
    await settle(1100);
    expect(rt.sentOf('CHAT').length, 10);
    expect(rt.sentOf('CHAT').map((m) => m['text']).toList(), [for (var i = 0; i < 10; i++) 'd$i']);
    c.dispose();
  });

  test('ERROR with a client id: 4xx shows Not sent, 429 keeps it', () async {
    final rt = FakeRt(features: {ProtocolFeatures.ack});
    final c = await startService(rt);
    c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'bad');
    c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'busy');
    final ids = rt.sentOf('CHAT').map((m) => m['clientId'] as String).toList();
    rt.emit({'type': 'ERROR', 'code': 422, 'message': 'Message too long', 'clientId': ids[0]});
    rt.emit({'type': 'ERROR', 'code': 429, 'message': 'Slow down', 'clientId': ids[1]});
    await settle();
    final failed = c.outbox.firstWhere((i) => i.clientId == ids[0]);
    expect(failed.state, OutboxState.failed);
    expect(c.isQueued(ids[0]), isFalse);
    expect(c.isQueued(ids[1]), isTrue);
    c.dispose();
  });

  test('SOS replies: through the outbox, never for my own alert, my answer is known at once', () async {
    final rt = FakeRt(features: {ProtocolFeatures.ack, ProtocolFeatures.respond, ProtocolFeatures.checkIn}, connected: false);
    final c = await startService(rt);
    expect(c.respondToSos('SOS-ME', SosResponseKind.going), isFalse);
    expect(c.respondToSos('SOS-K', SosResponseKind.going), isTrue);
    expect(c.myResponseTo('SOS-K'), SosResponseKind.going);
    expect(c.respondToSos('SOS-K', SosResponseKind.withThem), isTrue);
    expect(c.outbox.where((i) => i.type == 'SOS_RESPOND').length, 1, reason: 'newer answer replaces the waiting one');
    expect(c.myResponseTo('SOS-K'), SosResponseKind.withThem);
    expect(c.respondToSos('SOS-K', SosResponseKind.cancel), isTrue);
    expect(c.myResponseTo('SOS-K'), isNull);

    expect(c.sendCheckIn(CheckInResult.noReply, awayM: 2400.4), isTrue);
    final check = c.outbox.lastWhere((i) => i.type == 'CHECK_IN');
    expect(check.payload['result'], 'NO_REPLY');
    expect(check.payload['awayM'], 2400);

    rt.setConnected(true);
    rt.emit({'type': 'SNAPSHOT'});
    await settle();
    expect(rt.sentOf('SOS_RESPOND').single['kind'], 'CANCEL');
    expect(rt.sentOf('CHECK_IN').single['clientId'], isNotEmpty);
    c.dispose();
  });
}
