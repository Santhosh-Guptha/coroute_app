import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:coroute_app/core/constants/net_constants.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/widgets/connection_banner.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records joins and BYEs instead of using a socket.
class FakeRt extends RealtimeService {
  FakeRt({Set<String> features = const {}}) : features = {...features};

  Set<String> features;
  final List<Map<String, dynamic>> sent = [];
  final List<(String, String?, int?)> joins = [];
  final StreamController<Map<String, dynamic>> _ctrl = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _ctrl.stream;
  @override
  bool get isConnected => true;
  @override
  RealtimeState get state => RealtimeState.connected;
  @override
  bool supports(String feature) => features.contains(feature);
  @override
  bool send(Map<String, dynamic> message) {
    sent.add(message);
    return true;
  }

  @override
  void connect(String token, {bool adminMode = false}) {}
  @override
  void disconnect() {}
  @override
  void joinRoom(String groupId, {String? prevExit, int? prevAliveAt}) => joins.add((groupId, prevExit, prevAliveAt));
  @override
  void leaveRoom({bool leaveConvoy = false}) {}
  @override
  bool sendBye(String reason) {
    if (!supports(ProtocolFeatures.presence)) return false;
    sent.add({'type': 'BYE', 'reason': reason});
    return true;
  }

  void emit(Map<String, dynamic> m) => _ctrl.add(m);
}

Map<String, dynamic> hello(List<String> features) => {'type': 'HELLO', 'userId': 'usr_me', 'serverTime': 1, 'heartbeatSec': 30, 'protocol': 2, 'features': features};

/// A real RealtimeService wired to an in-memory sink.
(RealtimeService, List<Map<String, dynamic>>) wiredRt() {
  final rt = RealtimeService();
  final out = <Map<String, dynamic>>[];
  rt.debugSink = (json) => out.add(Map<String, dynamic>.from(jsonDecode(json) as Map));
  return (rt, out);
}

Future<ConvoyService> startService(FakeRt rt, Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  final convoy = ConvoyModel(
    groupId: 'GRP-1',
    name: 'Hill run',
    joinCode: '123456',
    createdByUserId: 'usr_me',
    createdByUserName: 'Me',
    createdAtEpochMs: 1,
    riders: {'usr_me': RiderModel(userId: 'usr_me', name: 'Me', lat: 12.9, lng: 77.5, lastSeenEpochMs: 1)},
  );
  final api = ApiClient(
    httpClient: MockClient((req) async {
      if (req.url.path.endsWith('/convoys/active')) return http.Response(jsonEncode({'convoy': convoy.toJson()}), 200);
      return http.Response('{}', 200);
    }),
    storage: const FlutterSecureStorage(),
  );
  final c = ConvoyService(api, rt, TripStorageService(api));
  await c.startSession(token: 't', userId: 'usr_me');
  await Future<void>.delayed(const Duration(milliseconds: 30));
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

  group('classify a failed connect', () {
    test('no network: host lookup, network unreachable, timeouts', () {
      expect(RealtimeService.classify(const SocketException("Failed host lookup: 'coroute.example'")), LinkProblem.noNetwork);
      expect(RealtimeService.classify(const SocketException('Network is unreachable', osError: OSError('Network is unreachable', 101))), LinkProblem.noNetwork);
      expect(RealtimeService.classify(TimeoutException('connect')), LinkProblem.noNetwork);
    });

    test('server unreachable: refused, or an HTTP answer that is not an upgrade (proxy 502)', () {
      expect(RealtimeService.classify(const SocketException('Connection refused', osError: OSError('Connection refused', 111))), LinkProblem.serverUnreachable);
      expect(RealtimeService.classify(const WebSocketException("Connection to 'https://coroute.example:0/ws#' was not upgraded to websocket, HTTP status code: 502")),
          LinkProblem.serverUnreachable);
    });
  });

  test('"server not reachable" only after 2 such failures in a row; HELLO resets it', () {
    final (rt, _) = wiredRt();
    const refused = SocketException('Connection refused', osError: OSError('Connection refused', 111));
    rt.debugConnectFailed(refused);
    expect(rt.serverUnreachable, isFalse);
    expect(rt.linkProblem, LinkProblem.none);
    rt.debugConnectFailed(refused);
    expect(NetConstants.serverUnreachableAfter, 2);
    expect(rt.serverUnreachable, isTrue);
    // A no-network failure in between starts the count again.
    rt.debugConnectFailed(const SocketException('Failed host lookup'));
    expect(rt.linkProblem, LinkProblem.noNetwork);
    rt.debugConnectFailed(refused);
    expect(rt.serverUnreachable, isFalse);
    rt.debugConnectFailed(refused);
    expect(rt.serverUnreachable, isTrue);
    rt.debugReceive(jsonEncode(hello(const [])));
    expect(rt.isConnected, isTrue);
    expect(rt.linkProblem, LinkProblem.none);
    rt.dispose();
  });

  test('banner text says the server, not the signal', () {
    const now = 1700000000000;
    expect(ConnectionBanner.status(state: RealtimeState.disconnected, lastUpdateMs: now - 60000, nowMs: now, serverUnreachable: true), 'CoRoute server not reachable');
    expect(ConnectionBanner.status(state: RealtimeState.connected, nowMs: now, serverUnreachable: true), isNull);
    expect(ConnectionBanner.status(state: RealtimeState.disconnected, nowMs: now, sosWaiting: true, serverUnreachable: true), 'SOS waiting to send');
    expect(ConnectionBanner.lines(connecting: true, pendingPoints: 0, sosWaiting: false, serverUnreachable: true).first, 'CoRoute server not reachable');
  });

  test('features come from HELLO; an older gateway has none', () {
    final (rt, _) = wiredRt();
    expect(rt.serverFeatures, isEmpty);
    rt.debugReceive(jsonEncode(hello(const ['ack', 'presence'])));
    expect(rt.supports(ProtocolFeatures.ack), isTrue);
    expect(rt.supports(ProtocolFeatures.roster), isFalse);
    rt.debugReceive(jsonEncode({'type': 'HELLO', 'userId': 'usr_me'}));
    expect(rt.serverFeatures, isEmpty);
    rt.dispose();
  });

  test('BYE only when the gateway supports presence', () {
    final (rt, out) = wiredRt();
    rt.debugReceive(jsonEncode(hello(const [])));
    expect(rt.sendBye('APP_CLOSED'), isFalse);
    expect(out.where((m) => m['type'] == 'BYE'), isEmpty);
    rt.debugReceive(jsonEncode(hello(const ['presence'])));
    expect(rt.sendBye('APP_CLOSED'), isTrue);
    expect(out.lastWhere((m) => m['type'] == 'BYE')['reason'], 'APP_CLOSED');
    rt.dispose();
  });

  test('the killed flag goes with the next JOIN only, and only to a presence gateway', () {
    final (rt, out) = wiredRt();
    rt.debugReceive(jsonEncode(hello(const ['presence'])));
    rt.joinRoom('GRP-1', prevExit: 'KILLED', prevAliveAt: 1234);
    final first = out.lastWhere((m) => m['type'] == 'JOIN');
    expect(first['prevExit'], 'KILLED');
    expect(first['prevAliveAt'], 1234);
    // Reconnect: a plain JOIN.
    rt.debugReceive(jsonEncode(hello(const ['presence'])));
    final again = out.lastWhere((m) => m['type'] == 'JOIN');
    expect(again.containsKey('prevExit'), isFalse);
    rt.dispose();

    final (old, oldOut) = wiredRt();
    old.debugReceive(jsonEncode(hello(const [])));
    old.joinRoom('GRP-1', prevExit: 'KILLED', prevAliveAt: 1234);
    expect(oldOut.lastWhere((m) => m['type'] == 'JOIN').containsKey('prevExit'), isFalse);
    old.dispose();
  });

  test('app killed during a ride: the next start joins with prevExit KILLED, once', () async {
    final rt = FakeRt(features: {ProtocolFeatures.presence});
    final c = await startService(rt, {NetConstants.keyRideAlive: true, NetConstants.keyLastAliveAt: 1700000000000});
    expect(rt.joins.single, ('GRP-1', 'KILLED', 1700000000000));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(NetConstants.keyRideAlive), isTrue, reason: 'the new ride run is marked alive again');
    // A later JOIN of the same session (rejoin after a membership check) carries nothing.
    c.dispose();
  });

  test('clean exit last time: a plain JOIN; sign-out says BYE and clears the alive flag', () async {
    final rt = FakeRt(features: {ProtocolFeatures.presence});
    final c = await startService(rt, {NetConstants.keyRideAlive: false});
    expect(rt.joins.single, ('GRP-1', null, null));
    await c.endSession();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(rt.sent.where((m) => m['type'] == 'BYE').single['reason'], 'SIGN_OUT');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(NetConstants.keyRideAlive), isFalse);
    c.dispose();
  });

  test('PRESENCE updates the rider', () async {
    final rt = FakeRt(features: {ProtocolFeatures.presence});
    final c = await startService(rt, {});
    rt.emit({'type': 'PRESENCE', 'userId': 'usr_me', 'presence': 'NO_SIGNAL', 'at': 99});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final r = c.activeConvoy!.riders['usr_me']!;
    expect(r.presenceState, RiderPresence.noSignal);
    expect(r.presenceAt, 99);
    expect(RiderModel.fromJson(r.toJson()).presence, 'NO_SIGNAL');
    c.dispose();
  });
}
