import 'dart:async';
import 'dart:convert';

import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/background_service.dart';
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
class Rt extends RealtimeService {
  Rt(Set<String> features) : features = {...features};

  Set<String> features;
  bool _connected = true;
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

  List<Map<String, dynamic>> sentOf(String type) => sent.where((m) => m['type'] == type).toList();
}

const gid = 'GRP-1';
const me = 'usr_me';
const kiran = 'usr_k';
const alertK = 'SOS-K';
const all316 = {ProtocolFeatures.ack, ProtocolFeatures.checkIn, ProtocolFeatures.safetyNet, ProtocolFeatures.ride316};
const old315 = {ProtocolFeatures.ack, ProtocolFeatures.checkIn, ProtocolFeatures.safetyNet};

ConvoyModel convoyModel({String lead = me}) => ConvoyModel(
      groupId: gid,
      name: 'Hill run',
      joinCode: '123456',
      createdByUserId: lead,
      createdByUserName: 'Lead',
      createdAtEpochMs: 1,
      riders: {
        me: RiderModel(userId: me, name: 'Me', lat: 12.9, lng: 77.5, heading: 91, speedKmh: 30, lastSeenEpochMs: 1),
        kiran: RiderModel(userId: kiran, name: 'Kiran', lat: 12.95, lng: 77.55, lastSeenEpochMs: 1),
      },
      activeAlerts: [SosAlertModel(alertId: alertK, userId: kiran, userName: 'Kiran', lat: 12.95, lng: 77.55, timestamp: 1)],
    );

Future<void> settle([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

/// Records every request; the live link endpoint answers like the gateway (409 on a second create).
class Api {
  final List<http.Request> requests = [];
  int creates = 0;
  int expiresAt = 0;

  late final ApiClient client = ApiClient(
    httpClient: MockClient((req) async {
      requests.add(req);
      if (req.url.path.endsWith('/convoys/active')) return http.Response(jsonEncode({'convoy': convoyModel().toJson()}), 200);
      if (req.url.path.endsWith('/live-link')) {
        if (req.method == 'DELETE') return http.Response(jsonEncode({'ok': true}), 200);
        creates++;
        if (creates > 1) return http.Response(jsonEncode({'error': 'A link is already active.', 'code': 'LINK_ACTIVE', 'expiresAt': expiresAt}), 409);
        return http.Response(jsonEncode({'token': 'a' * 32, 'url': 'https://coroute.test/e/${'a' * 32}', 'expiresAt': expiresAt}), 200);
      }
      return http.Response('{}', 200);
    }),
    storage: const FlutterSecureStorage(),
  );

  List<http.Request> of(String method, String suffix) => requests.where((r) => r.method == method && r.url.path.endsWith(suffix)).toList();
}

Future<(ConvoyService, Api)> start(Rt rt, {int Function()? clock}) async {
  final api = Api()..expiresAt = (clock?.call() ?? DateTime.now().millisecondsSinceEpoch) + 30 * 60000;
  final c = ConvoyService(api.client, rt, TripStorageService(api.client), clock: clock);
  await c.startSession(token: 't', userId: me);
  await settle();
  return (c, api);
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

  group('Leave from the notification (item 3)', () {
    test('the leave button only raises the flag; nothing leaves until the UI confirms', () async {
      final rt = Rt(all316);
      final (c, api) = await start(rt);
      var notified = 0;
      c.addListener(() => notified++);
      c.debugNotificationButton(BackgroundService.buttonLeave);
      expect(c.leaveRequestedFromNotification, isTrue);
      expect(notified, 1);
      await settle();
      expect(c.activeGroupId, gid, reason: 'still in the ride');
      expect(api.of('POST', '/leave'), isEmpty);
      final before = notified;
      c.clearLeaveRequest();
      expect(c.leaveRequestedFromNotification, isFalse);
      expect(notified, before + 1);
      c.clearLeaveRequest(); // no change: no extra notification
      expect(notified, before + 1);
      // Confirmed by the rider: the usual leave.
      await c.leaveActiveConvoy(me);
      await settle();
      expect(c.activeGroupId, isNull);
      expect(api.of('POST', '/leave').length, 1);
      c.dispose();
    });

    test('without a ride the button does nothing', () async {
      final rt = Rt(all316);
      final (c, _) = await start(rt);
      await c.leaveActiveConvoy(me);
      c.debugNotificationButton(BackgroundService.buttonLeave);
      expect(c.leaveRequestedFromNotification, isFalse);
      c.dispose();
    });
  });

  group('Sweeper (item 11)', () {
    test('ROLE_SET through the outbox with a clientId, only on a ride316 gateway, lead only', () async {
      final rt = Rt(all316);
      final (c, _) = await start(rt);
      expect(c.hasSweeper, isFalse);
      expect(c.setSweeper(kiran, on: true), isTrue);
      final m = rt.sentOf('ROLE_SET').single;
      expect(m['userId'], kiran);
      expect(m['role'], 'SWEEPER');
      expect((m['clientId'] as String).isNotEmpty, isTrue);
      // Not me, not the lead, not an unknown rider.
      expect(c.setSweeper(me, on: true), isFalse);
      expect(c.setSweeper('usr_nobody', on: true), isFalse);
      // The server answers with the rider's new role.
      rt.emit({'type': 'ACK', 'clientId': m['clientId']});
      rt.emit({'type': 'RIDER_UPDATE', 'rider': convoyModel().riders[kiran]!.copyWith(role: 'SWEEPER').toJson()});
      await settle();
      expect(c.sweeperId, kiran);
      expect(c.hasSweeper, isTrue);
      expect(c.activeConvoy!.riders[kiran]!.isSweeper, isTrue);
      expect(c.setSweeper(kiran, on: false), isTrue);
      expect(rt.sentOf('ROLE_SET').last['role'], 'PACK');
      c.dispose();
    });

    test('no ROLE_SET to a 3.15 gateway, and never by a pack rider', () async {
      final rt = Rt(old315);
      final (c, _) = await start(rt);
      expect(c.setSweeper(kiran, on: true), isFalse);
      expect(rt.sentOf('ROLE_SET'), isEmpty);
      c.dispose();
      final rt2 = Rt(all316);
      final api = Api();
      final pack = ConvoyService(api.client, rt2, TripStorageService(api.client));
      await pack.startSession(token: 't', userId: 'usr_pack');
      await settle();
      expect(pack.setSweeper(kiran, on: true), isFalse);
      expect(rt2.sentOf('ROLE_SET'), isEmpty);
      pack.dispose();
    });
  });

  group('CHECK_IN context and CONFIG townLimitKmh', () {
    test('follow-up context goes only to a ride316 gateway; NO_REPLY with a context is refused', () async {
      final rt = Rt(all316);
      final (c, _) = await start(rt);
      expect(c.sendCheckIn(CheckInResult.ok, context: CheckInContext.followUp), isTrue);
      final m = rt.sentOf('CHECK_IN').single;
      expect(m['result'], 'OK');
      expect(m['context'], 'FOLLOW_UP');
      expect(m['lat'], 12.9);
      expect(c.sendCheckIn(CheckInResult.noReply, context: CheckInContext.followUp), isFalse);
      expect(c.sendCheckIn(CheckInResult.ok), isTrue);
      expect(rt.sentOf('CHECK_IN').last.containsKey('context'), isFalse);
      c.dispose();

      final rt2 = Rt(old315);
      final (c2, _) = await start(rt2);
      expect(c2.sendCheckIn(CheckInResult.ok, context: CheckInContext.followUp), isTrue);
      expect(rt2.sentOf('CHECK_IN').single.containsKey('context'), isFalse, reason: 'older gateway: plain OK');
      c2.dispose();
    });

    test('townLimitKmh in CONFIG only with ride316; applied from CONFIG and SNAPSHOT', () async {
      final rt = Rt(all316);
      final (c, _) = await start(rt);
      c.updateGroupConfig(townLimitKmh: 40);
      expect(rt.sentOf('CONFIG').single['townLimitKmh'], 40);
      c.updateGroupConfig(speedLimitKmh: 80, townLimitKmh: 0);
      expect(rt.sentOf('CONFIG').last, {'type': 'CONFIG', 'speedLimitKmh': 80, 'townLimitKmh': 0});
      expect(c.activeConvoy!.townLimitKmh, 0);
      rt.emit({'type': 'CONFIG', 'townLimitKmh': 40, 'speedLimitKmh': 80});
      await settle();
      expect(c.activeConvoy!.townLimitKmh, 40);
      expect(c.activeConvoy!.speedLimitKmh, 80);
      rt.emit({'type': 'CONFIG', 'speedLimitKmh': 70});
      await settle();
      expect(c.activeConvoy!.townLimitKmh, 40, reason: 'kept when absent');
      final snap = convoyModel().toJson()..['townLimitKmh'] = 30;
      rt.emit({'type': 'SNAPSHOT', 'convoy': snap});
      await settle();
      expect(c.activeConvoy!.townLimitKmh, 30);
      expect(ConvoyModel.fromJson(c.activeConvoy!.toJson()).townLimitKmh, 30);
      c.dispose();

      final rt2 = Rt(old315);
      final (c2, _) = await start(rt2);
      c2.updateGroupConfig(townLimitKmh: 40);
      expect(rt2.sentOf('CONFIG'), isEmpty, reason: 'nothing supported to send');
      c2.updateGroupConfig(speedLimitKmh: 60, townLimitKmh: 40);
      expect(rt2.sentOf('CONFIG').single, {'type': 'CONFIG', 'speedLimitKmh': 60});
      c2.dispose();
    });
  });

  group('EMERGENCY_UPDATE and ALERT parsing (items 17, 18)', () {
    test('nearestHospital and liveLink are applied and kept when absent', () async {
      final rt = Rt(all316);
      final (c, _) = await start(rt);
      rt.emit({
        'type': 'EMERGENCY_UPDATE',
        'alertId': alertK,
        'status': 'ASSISTANCE_REQUESTED',
        'nearestHospital': {'name': 'Apollo Hospital', 'lat': 12.96, 'lng': 77.56, 'distanceM': 4200},
        'liveLink': {'expiresAt': 5000, 'revokedAt': 0},
      });
      await settle();
      var a = c.activeConvoy!.activeAlerts.single;
      expect(a.nearestHospital!.name, 'Apollo Hospital');
      expect(a.nearestHospital!.distanceM, 4200);
      expect(a.liveLinkExpiresAt, 5000);
      expect(a.liveLinkRevokedAt, 0);
      expect(a.liveLinkActiveAt(4000), isTrue);
      rt.emit({'type': 'EMERGENCY_UPDATE', 'alertId': alertK, 'status': 'RESPONDER_ASSIGNED'});
      await settle();
      a = c.activeConvoy!.activeAlerts.single;
      expect(a.nearestHospital!.name, 'Apollo Hospital', reason: 'kept when absent');
      expect(a.liveLinkExpiresAt, 5000);
      rt.emit({'type': 'EMERGENCY_UPDATE', 'alertId': alertK, 'liveLink': {'expiresAt': 5000, 'revokedAt': 4500}});
      await settle();
      a = c.activeConvoy!.activeAlerts.single;
      expect(a.liveLinkRevokedAt, 4500);
      expect(a.liveLinkActiveAt(4000), isFalse);
      // Round trip through JSON (snapshot form).
      final again = SosAlertModel.fromJson(a.toJson());
      expect(again.nearestHospital!.lat, 12.96);
      expect(again.liveLinkRevokedAt, 4500);
      c.dispose();
    });

    test('ALERT with hospital and report fields; a bad hospital is ignored', () async {
      final rt = Rt(all316);
      final (c, _) = await start(rt);
      rt.emit({
        'type': 'ALERT',
        'alert': {
          'alertId': 'SOS-R',
          'userId': kiran,
          'userName': 'Kiran',
          'lat': 12.95,
          'lng': 77.55,
          'alertType': 'RIDER_DOWN',
          'timestamp': 1,
          'source': 'MEMBER_REPORT',
          'reportedBy': 'usr_a',
          'reportedByName': 'Arjun',
          'nearestHospital': {'name': '', 'lat': 1, 'lng': 2},
        },
      });
      await settle();
      final a = c.activeConvoy!.activeAlerts.firstWhere((x) => x.alertId == 'SOS-R');
      expect(a.isReport, isTrue);
      expect(a.reportedByName, 'Arjun');
      expect(a.nearestHospital, isNull);
      c.dispose();
    });
  });

  group('Live link (item 17)', () {
    test('create, 409 keeps the known link, revoke drops it, cleared at ride end', () async {
      var now = 1800000000000;
      final rt = Rt(all316);
      final (c, api) = await start(rt, clock: () => now);
      final link = await c.createLiveLink(alertK);
      expect(link, isNotNull);
      expect(link!.token.length, 32);
      expect(link.url, endsWith('/e/${'a' * 32}'));
      expect(link.isValidAt(now), isTrue);
      expect(api.of('POST', '/live-link').single.url.path, contains('/convoys/$gid/alerts/$alertK/live-link'));
      expect(c.liveLinkFor(alertK), same(link));
      expect(c.liveLinkFor('other'), isNull);
      // A second create: the server says one is active; the one we know is returned.
      final again = await c.createLiveLink(alertK);
      expect(again, same(link));
      // Expired by the clock: gone.
      now += 31 * 60000;
      expect(c.liveLinkFor(alertK), isNull);
      // Revoked by the lead from another phone: gone.
      now -= 31 * 60000;
      final fresh = await c.createLiveLink(alertK);
      expect(fresh, isNull, reason: '409 and nothing known any more');
      api.creates = 0;
      expect(await c.createLiveLink(alertK), isNotNull);
      rt.emit({'type': 'EMERGENCY_UPDATE', 'alertId': alertK, 'liveLink': {'expiresAt': now + 100000, 'revokedAt': now}});
      await settle();
      expect(c.liveLinkFor(alertK), isNull);
      // Revoke from here.
      api.creates = 0;
      rt.emit({'type': 'EMERGENCY_UPDATE', 'alertId': alertK, 'liveLink': {'expiresAt': now + 100000, 'revokedAt': 0}});
      await settle();
      expect(await c.createLiveLink(alertK), isNotNull);
      expect(await c.revokeLiveLink(alertK), isTrue);
      expect(api.of('DELETE', '/live-link').length, 1);
      expect(c.liveLinkFor(alertK), isNull);
      // Cleared at ride end.
      api.creates = 0;
      expect(await c.createLiveLink(alertK), isNotNull);
      rt.emit({'type': 'TRIP_STATUS', 'tripStatus': 'ENDED'});
      await settle();
      expect(c.liveLinkFor(alertK), isNull);
      c.dispose();
    });

    test('resolving the alert drops the link; nothing without ride316', () async {
      final now = 1800000000000;
      final rt = Rt(all316);
      final (c, _) = await start(rt, clock: () => now);
      expect(await c.createLiveLink(alertK), isNotNull);
      c.resolveSosAlert(alertK);
      expect(c.liveLinkFor(alertK), isNull);
      c.dispose();
      final rt2 = Rt(old315);
      final (c2, api2) = await start(rt2, clock: () => now);
      expect(await c2.createLiveLink(alertK), isNull);
      expect(await c2.revokeLiveLink(alertK), isFalse);
      expect(api2.of('POST', '/live-link'), isEmpty);
      c2.dispose();
    });

    test('the token never appears in toString', () {
      const l = LiveLink(token: 'secret-token-value-0123456789abcd', url: 'https://x/e/t', expiresAt: 10);
      expect(l.toString(), isNot(contains('secret')));
    });
  });

  group('Models', () {
    test('RiderModel.lowBattery, isSweeper; ConvoyModel.sweeperId', () {
      final r = RiderModel(userId: 'u', name: 'U', lat: 1, lng: 2, lastSeenEpochMs: 1, batteryLevel: 20);
      expect(r.lowBattery, isTrue);
      expect(r.copyWith(isCharging: true).lowBattery, isFalse);
      expect(r.copyWith(batteryLevel: 21).lowBattery, isFalse);
      expect(r.isSweeper, isFalse);
      expect(r.copyWith(role: RiderRoles.sweeper).isSweeper, isTrue);
      final c = convoyModel();
      expect(c.sweeperId, isNull);
      expect(c.copyWith(riders: {...c.riders, kiran: c.riders[kiran]!.copyWith(role: 'SWEEPER')}).sweeperId, kiran);
    });

    test('wire names of the contract', () {
      expect(ProtocolFeatures.ride316, 'ride316');
      expect(SafetyEventTypes.staleUpdate, 'STALE_UPDATE');
      expect(SafetyEventTypes.lowBattery, 'LOW_BATTERY');
      expect(SafetyEventTypes.behindSweeper, 'BEHIND_SWEEPER');
      expect(SafetyEventTypes.roleChanged, 'ROLE_CHANGED');
      expect(SafetyEventTypes.followUp, 'FOLLOW_UP');
      expect(CheckInContext.followUp.wire, 'FOLLOW_UP');
      expect(CheckInContext.fromWire('follow_up'), CheckInContext.followUp);
      expect(RiderRoles.sweeper, 'SWEEPER');
    });
  });
}
