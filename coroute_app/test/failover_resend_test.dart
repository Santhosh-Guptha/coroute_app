import 'dart:async';
import 'dart:convert';

import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/outbox_item.dart';
import 'package:coroute_app/data/models/pending_sos.dart';
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

/// Two gateways behind one address: when the primary fails the socket drops and the phone
/// reconnects to the backup, which already has the ride. Nothing the rider sent may be lost.

class _Rt extends RealtimeService {
  _Rt({Set<String> features = const {ProtocolFeatures.ack}, bool connected = true})
      : _features = {...features},
        _up = connected;

  final Set<String> _features;
  bool _up;
  final List<Map<String, dynamic>> sent = [];
  final List<String> joins = [];
  final StreamController<Map<String, dynamic>> _ctrl = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _ctrl.stream;
  @override
  bool get isConnected => _up;
  @override
  RealtimeState get state => _up ? RealtimeState.connected : RealtimeState.disconnected;
  @override
  Set<String> get serverFeatures => _features;
  @override
  bool supports(String feature) => _features.contains(feature);
  @override
  bool send(Map<String, dynamic> message) {
    if (!_up) return false;
    sent.add(message);
    return true;
  }

  @override
  void connect(String token, {bool adminMode = false}) {}
  @override
  void disconnect() {}
  @override
  void joinRoom(String groupId, {String? prevExit, int? prevAliveAt}) => joins.add(groupId);
  @override
  void leaveRoom({bool leaveConvoy = false}) {}
  @override
  bool sendBye(String reason) => false;

  void emit(Map<String, dynamic> m) => _ctrl.add(m);
  void setUp(bool v) {
    _up = v;
    notifyListeners();
  }

  List<Map<String, dynamic>> sentOf(String type) => sent.where((m) => m['type'] == type).toList();
}

const gid = 'GRP-F';
const me = 'usr_me';

ConvoyModel _convoy() => ConvoyModel(
      groupId: gid,
      name: 'Failover run',
      joinCode: '654321',
      createdByUserId: 'usr_lead',
      createdByUserName: 'Lead',
      createdAtEpochMs: 1,
      riders: {
        me: RiderModel(userId: me, name: 'Me', lat: 12.9, lng: 77.5, lastSeenEpochMs: 1),
        'usr_k': RiderModel(userId: 'usr_k', name: 'Kiran', lat: 12.95, lng: 77.55, lastSeenEpochMs: 1),
      },
      activeAlerts: [
        SosAlertModel(alertId: 'SOS-ME', userId: me, userName: 'Me', lat: 12.9, lng: 77.5, timestamp: 1),
      ],
    );

Future<void> _settle([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

ApiClient _api({http.Response Function(http.Request req)? other}) => ApiClient(
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/convoys/active')) return http.Response(jsonEncode({'convoy': _convoy().toJson()}), 200);
        return other?.call(req) ?? http.Response('{}', 200);
      }),
      storage: const FlutterSecureStorage(),
    );

Future<ConvoyService> _start(RealtimeService rt, {int Function()? clock, ApiClient? api}) async {
  final a = api ?? _api();
  final c = ConvoyService(a, rt, TripStorageService(a), clock: clock);
  await c.startSession(token: 't', userId: me);
  await _settle();
  return c;
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

  test('after the failover reconnect: SOS, "I\'m safe" and the outbox go again with the same clientIds', () async {
    final rt = _Rt();
    final c = await _start(rt);
    rt.emit({'type': 'SNAPSHOT', 'convoy': _convoy().toJson()});
    await _settle();

    // Sent to the primary, which died before saving it (no ACK).
    c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'fuel stop in 5');
    final chatId = rt.sentOf('CHAT').single['clientId'] as String;

    // The socket drops; the rider raises an SOS and presses "I'm safe" on an older alert.
    rt.setUp(false);
    expect(c.outbox.single.state, OutboxState.waiting);
    final delivery = c.triggerSosAlert(userId: me, userName: 'Me', lat: 12.9, lng: 77.5);
    expect(delivery, SosDelivery.queued);
    final sosId = c.pendingSos!.clientId;
    c.resolveSosAlert('SOS-ME', reason: ResolveReason.falseAlarm);
    expect(c.activeConvoy, isNotNull, reason: 'the ride stays while the link is down');

    // Reconnected to the backup: nothing before the re-JOIN's SNAPSHOT, then all of it.
    rt.sent.clear();
    rt.setUp(true);
    expect(rt.sentOf('SOS'), isEmpty);
    rt.emit({'type': 'SNAPSHOT', 'convoy': _convoy().toJson()});
    await _settle();
    expect(rt.sentOf('SOS').single['clientId'], sosId);
    expect(rt.sentOf('SOS_RESOLVE').single['alertId'], 'SOS-ME');
    expect(rt.sentOf('CHAT').single['clientId'], chatId);
    final types = rt.sent.map((m) => m['type']).toList();
    expect(types.indexOf('SOS'), lessThan(types.indexOf('CHAT')), reason: 'the SOS goes first');

    // Confirmed only by the durable-save echoes.
    rt.emit({'type': 'ACK', 'clientId': chatId});
    rt.emit({
      'type': 'ALERT',
      'alert': SosAlertModel(alertId: 'SOS-NEW', userId: me, userName: 'Me', lat: 12.9, lng: 77.5, timestamp: 2, clientId: sosId).toJson(),
    });
    rt.emit({'type': 'ALERT_RESOLVED', 'alertId': 'SOS-ME', 'by': me});
    await _settle();
    expect(c.outboxCount, 0);
    expect(c.pendingSos, isNull);
    c.dispose();
  });

  test('socket still up but no confirmation: sent again after 20 s with the same clientId', () async {
    var now = 1700000000000;
    final rt = _Rt();
    final c = await _start(rt, clock: () => now);
    rt.emit({'type': 'SNAPSHOT', 'convoy': _convoy().toJson()});
    await _settle();

    c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'regroup at the dhaba');
    c.triggerSosAlert(userId: me, userName: 'Me', lat: 12.9, lng: 77.5);
    final chatId = rt.sentOf('CHAT').single['clientId'];
    final sosId = rt.sentOf('SOS').single['clientId'];
    rt.sent.clear();

    now += 5000;
    c.debugResendUnconfirmed();
    expect(rt.sent, isEmpty, reason: 'not before the resend interval');

    now += 16000;
    c.debugResendUnconfirmed();
    await _settle();
    expect(rt.sentOf('CHAT').single['clientId'], chatId);
    expect(rt.sentOf('SOS').single['clientId'], sosId);

    // Once confirmed, nothing more goes out.
    rt.emit({'type': 'ACK', 'clientId': chatId});
    rt.emit({
      'type': 'ALERT',
      'alert': SosAlertModel(alertId: 'SOS-2', userId: me, userName: 'Me', lat: 12.9, lng: 77.5, timestamp: 2, clientId: sosId as String).toJson(),
    });
    await _settle();
    rt.sent.clear();
    now += 30000;
    c.debugResendUnconfirmed();
    expect(rt.sentOf('CHAT'), isEmpty);
    expect(rt.sentOf('SOS'), isEmpty);
    c.dispose();
  });

  test('an item sent before the re-JOIN answered ("Join a convoy first.") waits, then goes with the same clientId', () async {
    final rt = _Rt();
    final c = await _start(rt);
    c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'right after the failover');
    final chatId = rt.sentOf('CHAT').single['clientId'];
    rt.emit({'type': 'ERROR', 'code': 409, 'message': 'Join a convoy first.', 'clientId': chatId});
    await _settle();
    expect(c.outbox.single.isFailed, isFalse, reason: 'not "Not sent"');
    expect(c.outbox.single.state, OutboxState.waiting);
    rt.sent.clear();
    rt.emit({'type': 'SNAPSHOT', 'convoy': _convoy().toJson()});
    await _settle();
    expect(rt.sentOf('CHAT').single['clientId'], chatId);

    // A real refusal still shows "Not sent".
    rt.emit({'type': 'ERROR', 'code': 422, 'message': 'Message too long', 'clientId': chatId});
    await _settle();
    expect(c.outbox.single.isFailed, isTrue);
    c.dispose();
  });

  test('SERVER_BUSY on the socket JOIN: plain message, ride and outbox kept, JOIN tried again', () async {
    var now = 1700000000000;
    final rt = _Rt();
    final c = await _start(rt, clock: () => now);
    c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'hi');
    final joinsBefore = rt.joins.length;

    rt.emit({'type': 'ERROR', 'code': 'SERVER_BUSY', 'message': 'Server busy, try in a few minutes'});
    await _settle();
    expect(c.activeConvoy?.groupId, gid, reason: 'never a removal from the ride');
    expect(c.serverBusy, isTrue);
    expect(c.lastError, ApiException.serverBusyMessage);
    expect(c.lastErrorIsServerBusy, isTrue);
    expect(c.outboxCount, 1);
    expect(c.outbox.single.isFailed, isFalse);

    c.retryAfterServerBusy();
    expect(rt.joins.length, joinsBefore + 1);
    expect(rt.joins.last, gid);

    // And by itself, after 45-75 s.
    now += 76000;
    c.debugResendUnconfirmed();
    expect(rt.joins.length, joinsBefore + 2);

    rt.emit({'type': 'SNAPSHOT', 'convoy': _convoy().toJson()});
    await _settle();
    expect(c.serverBusy, isFalse);
    expect(c.lastError, isNull);
    c.dispose();
  });

  test('HTTP 503 SERVER_BUSY on join: the plain message, nothing else changes', () async {
    final api = ApiClient(
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/convoys/join')) {
          return http.Response(jsonEncode({'code': 'SERVER_BUSY', 'error': 'Server busy, try in a few minutes'}), 503);
        }
        if (req.url.path.endsWith('/convoys/active')) return http.Response(jsonEncode({'convoy': null}), 200);
        return http.Response('{}', 200);
      }),
      storage: const FlutterSecureStorage(),
    );
    final rt = _Rt();
    final c = await _start(rt, api: api);
    expect(c.activeConvoy, isNull);
    final joined = await c.joinConvoyByCode(
      code: 'abc123',
      rider: RiderModel(userId: me, name: 'Me', lat: 12.9, lng: 77.5, lastSeenEpochMs: 1),
    );
    expect(joined, isNull);
    expect(c.lastError, 'Server busy. Try again in a few minutes.');
    expect(c.lastErrorIsServerBusy, isTrue);
    c.dispose();
  });

  test('RECONNECT from the server: ride, outbox and screen kept; re-JOIN and resend with the same clientId', () async {
    final rt = RealtimeService();
    final wire = <Map<String, dynamic>>[];
    var opens = 0;
    rt.debugOnOpen = () => opens++;
    rt.debugSink = (j) => wire.add(Map<String, dynamic>.from(jsonDecode(j) as Map));
    final c = await _start(rt);
    expect(opens, 1);
    rt.debugReceive(jsonEncode({'type': 'HELLO', 'features': [ProtocolFeatures.ack]}));
    await _settle();
    rt.debugReceive(jsonEncode({'type': 'SNAPSHOT', 'convoy': _convoy().toJson()}));
    await _settle();

    c.sendGroupMessage(senderId: me, senderName: 'Me', text: 'moving soon');
    final chatId = wire.lastWhere((m) => m['type'] == 'CHAT')['clientId'];
    expect(chatId, isNotNull);

    rt.debugReceive(jsonEncode({'type': 'RECONNECT', 'delayMs': 100, 'reason': 'handback'}));
    await _settle();
    expect(rt.state, RealtimeState.connecting);
    expect(c.activeConvoy?.groupId, gid);
    expect(c.lastError, isNull, reason: 'no error shown');
    expect(c.serverUnreachable, isFalse);
    expect(c.outboxCount, 1);
    expect(rt.debugFailures, 0, reason: 'a server move is not a failure');

    await _settle(700); // delay 100 ms + jitter <= 500 ms
    expect(opens, 2);
    wire.clear();
    rt.debugReceive(jsonEncode({'type': 'HELLO', 'features': [ProtocolFeatures.ack]}));
    await _settle();
    expect(wire.where((m) => m['type'] == 'JOIN').map((m) => m['groupId']), contains(gid));
    rt.debugReceive(jsonEncode({'type': 'SNAPSHOT', 'convoy': _convoy().toJson()}));
    await _settle();
    expect(wire.where((m) => m['type'] == 'CHAT').map((m) => m['clientId']), [chatId]);
    c.dispose();
    rt.dispose();
  });
}
