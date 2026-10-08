import 'dart:async';
import 'dart:convert';

import 'package:coroute_app/core/constants/network_constants.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/background_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
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

  void setConnected(bool v) {
    _connected = v;
    notifyListeners();
  }

  List<Map<String, dynamic>> sentOf(String type) => sent.where((m) => m['type'] == type).toList();
}

const gid = 'GRP-1';
const me = 'usr_me';
const inc = 'NET-0123456789AB';
const enc = 'ENC-0123456789AB';
const allNet = {ProtocolFeatures.ack, ProtocolFeatures.respond, ProtocolFeatures.safetyNet, ProtocolFeatures.discovery};

ConvoyModel convoyModel({String lead = me}) => ConvoyModel(
      groupId: gid,
      name: 'Hill run',
      joinCode: '123456',
      createdByUserId: lead,
      createdByUserName: 'Lead',
      createdAtEpochMs: 1,
      riders: {
        me: RiderModel(userId: me, name: 'Me', lat: 12.9, lng: 77.5, heading: 91, speedKmh: 30, lastSeenEpochMs: 1),
        'usr_k': RiderModel(userId: 'usr_k', name: 'Kiran', lat: 12.95, lng: 77.55, lastSeenEpochMs: 1),
      },
      activeAlerts: [SosAlertModel(alertId: 'SOS-K', userId: 'usr_k', userName: 'Kiran', lat: 12.95, lng: 77.55, timestamp: 1)],
    );

Future<void> settle([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

Future<ConvoyService> start(Rt rt, {String lead = me, int Function()? clock, SettingsService? settings}) async {
  final api = ApiClient(
    httpClient: MockClient((req) async {
      if (req.url.path.endsWith('/convoys/active')) return http.Response(jsonEncode({'convoy': convoyModel(lead: lead).toJson()}), 200);
      return http.Response('{}', 200);
    }),
    storage: const FlutterSecureStorage(),
  );
  final c = ConvoyService(api, rt, TripStorageService(api), clock: clock, settings: settings);
  await c.startSession(token: 't', userId: me);
  await settle();
  return c;
}

Map<String, dynamic> request({String id = inc}) => {
      'type': 'ASSIST_REQUEST',
      'incidentId': id,
      'lat': 12.96,
      'lng': 77.5,
      'distanceM': 6700,
      'aheadOnRoute': true,
      'etaS': 540,
      'fasterThanGroup': true,
      'severity': 'CRITICAL',
      'kind': 'ACCIDENT',
      'reportedAt': 1,
      'lastUpdateAt': 1,
    };

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

  group('JOIN caps and room scope (RealtimeService)', () {
    Map<String, dynamic> hello(List<String> f) => {'type': 'HELLO', 'userId': me, 'features': f};

    test('caps on every JOIN, only to a net1 gateway', () {
      final rt = RealtimeService();
      final out = <Map<String, dynamic>>[];
      rt.debugSink = (json) => out.add(Map<String, dynamic>.from(jsonDecode(json) as Map));
      rt.debugReceive(jsonEncode(hello(const ['ack', 'net1'])));
      rt.joinRoom(gid);
      expect(out.lastWhere((m) => m['type'] == 'JOIN')['caps'], ['net1']);
      // Reconnect: the JOIN sent after HELLO carries them again.
      rt.debugReceive(jsonEncode(hello(const ['ack', 'net1'])));
      expect(out.where((m) => m['type'] == 'JOIN').length, 2);
      expect(out.lastWhere((m) => m['type'] == 'JOIN')['caps'], ['net1']);
      // A 3.14 gateway never gets them.
      rt.debugReceive(jsonEncode(hello(const ['ack'])));
      expect(out.lastWhere((m) => m['type'] == 'JOIN').containsKey('caps'), isFalse);
      rt.dispose();
    });

    test('network events are dropped after leaving the room', () async {
      final rt = RealtimeService();
      rt.debugSink = (_) {};
      final got = <String>[];
      final sub = rt.events.listen((m) => got.add(m['type'].toString()));
      rt.debugReceive(jsonEncode(hello(const ['net1'])));
      rt.joinRoom(gid);
      for (final t in ['EMERGENCY_UPDATE', 'ASSIST_REQUEST', 'ASSIST_UPDATE', 'ASSIST_CLOSED', 'HAZARD', 'HAZARD_CLEAR', 'DISCOVERY', 'WAVED']) {
        rt.debugReceive(jsonEncode({'type': t}));
      }
      rt.leaveRoom();
      rt.debugReceive(jsonEncode({'type': 'ASSIST_REQUEST'}));
      rt.debugReceive(jsonEncode({'type': 'HAZARD'}));
      await settle(10);
      expect(got.length, 8);
      await sub.cancel();
      rt.dispose();
    });
  });

  group('Assistance requests', () {
    test('request, accept through the outbox, update, close wipes everything', () async {
      final rt = Rt(allNet);
      final c = await start(rt);
      rt.emit(request());
      await settle();
      expect(c.assistRequests.single.incidentId, inc);
      expect(c.assistRequests.single.myStatus, ResponderStatus.requested);
      expect(c.activeAssist, isNull);
      final rev = c.networkRevision;

      expect(c.answerAssist(inc, AssistAnswer.accept), isTrue);
      final m = rt.sentOf('ASSIST_ANSWER').single;
      expect(m['incidentId'], inc);
      expect(m['answer'], 'ACCEPT');
      expect((m['clientId'] as String).isNotEmpty, isTrue);
      expect(c.activeAssist!.myStatus, ResponderStatus.accepted, reason: 'optimistic');
      expect(c.networkRevision, greaterThan(rev));

      // An update while my answer is not acknowledged keeps my status; the rest merges.
      rt.emit({
        'type': 'ASSIST_UPDATE',
        'incidentId': inc,
        'incidentStatus': 'RESPONDER_ASSIGNED',
        'myStatus': 'REQUESTED',
        'lat': 12.961,
        'lng': 77.5,
        'subject': {'firstName': 'Rahul', 'vehicleType': 'Motorcycle', 'vehicleColor': 'Red'},
        'medical': {'bloodGroup': 'O+'},
      });
      await settle();
      expect(c.activeAssist!.myStatus, ResponderStatus.accepted);
      expect(c.activeAssist!.subject!.firstName, 'Rahul');
      expect(c.activeAssist!.lat, 12.961);
      rt.emit({'type': 'ACK', 'clientId': m['clientId']});
      rt.emit({'type': 'ASSIST_UPDATE', 'incidentId': inc, 'myStatus': 'ARRIVING', 'arrivalCheck': true, 'etaS': 30});
      await settle();
      expect(c.activeAssist!.myStatus, ResponderStatus.arriving);
      expect(c.activeAssist!.arrivalCheck, isTrue);

      expect(c.answerAssist(inc, AssistAnswer.arrived), isTrue);
      expect(c.activeAssist!.myStatus, ResponderStatus.arrived);
      expect(c.activeAssist!.arrivalCheck, isFalse);

      rt.emit({'type': 'ASSIST_CLOSED', 'incidentId': inc, 'reason': 'RESOLVED'});
      await settle();
      expect(c.assistRequests, isEmpty);
      expect(c.activeAssist, isNull);
      expect(c.assistNotices, isEmpty, reason: 'only TAKEN leaves a notice');
      expect(c.answerAssist(inc, AssistAnswer.cancel), isFalse, reason: 'unknown (closed) id');
      c.dispose();
    });

    test('taken: removed, notice for 2 min; a resent request keeps my answer; declined requests are hidden', () async {
      var now = 1800000000000;
      final rt = Rt(allNet);
      final c = await start(rt, clock: () => now);
      rt.emit(request());
      rt.emit(request(id: 'NET-0000000000BB'));
      await settle();
      expect(c.assistRequests.length, 2);
      c.answerAssist('NET-0000000000BB', AssistAnswer.decline);
      expect(c.assistRequests.map((r) => r.incidentId), [inc]);
      rt.emit(request(id: 'NET-0000000000BB')); // sent again (reconnect)
      await settle();
      expect(c.assistRequests.map((r) => r.incidentId), [inc], reason: 'still declined');

      rt.emit({'type': 'ASSIST_CLOSED', 'incidentId': inc, 'reason': 'TAKEN'});
      await settle();
      expect(c.assistNotices.single.reason, AssistClosedReason.taken);
      now += 3 * 60000;
      expect(c.assistNotices, isEmpty);
      c.dispose();
    });

    test('ERROR 409 (taken) and 404 (closed) end the request', () async {
      final rt = Rt(allNet);
      final c = await start(rt);
      rt.emit(request());
      rt.emit(request(id: 'NET-0000000000BB'));
      await settle();
      c.answerAssist(inc, AssistAnswer.accept);
      c.answerAssist('NET-0000000000BB', AssistAnswer.accept);
      final ids = rt.sentOf('ASSIST_ANSWER').map((m) => m['clientId']).toList();
      rt.emit({'type': 'ERROR', 'code': 409, 'message': 'TAKEN', 'clientId': ids[0]});
      rt.emit({'type': 'ERROR', 'code': 404, 'message': 'INCIDENT_CLOSED', 'clientId': ids[1]});
      await settle();
      expect(c.assistRequests, isEmpty);
      expect(c.assistNotices.single.incidentId, inc);
      c.dispose();
    });

    test('report false alert once; rider down through the outbox', () async {
      final rt = Rt(allNet);
      final c = await start(rt);
      expect(c.reportFalseAlert(inc), isFalse, reason: 'unknown id');
      rt.emit(request());
      await settle();
      expect(c.reportFalseAlert(inc), isTrue);
      expect(c.reportFalseAlert(inc), isFalse);
      expect(rt.sentOf('NET_REPORT_FALSE').single['incidentId'], inc);

      expect(c.reportRiderDown(lat: 12.95, lng: 77.55, subjectUserId: 'usr_k'), isTrue);
      final r = rt.sentOf('REPORT_DOWN').single;
      expect(r['subjectUserId'], 'usr_k');
      expect(r['heading'], 91);
      expect(r['clientId'], isNotNull);
      expect(c.reportRiderDown(lat: 12.95, lng: 77.55), isTrue);
      expect(rt.sentOf('REPORT_DOWN').last.containsKey('subjectUserId'), isFalse);
      expect(c.reportRiderDown(lat: 0, lng: 0), isFalse);
      expect(c.reportRiderDown(lat: 12.9, lng: 77.5, subjectUserId: me), isFalse);
      c.dispose();
    });

    test('an older gateway: nothing is shown and nothing is sent', () async {
      final rt = Rt({ProtocolFeatures.ack});
      final c = await start(rt);
      rt.emit(request());
      rt.emit({'type': 'HAZARD', 'hazardId': inc, 'lat': 12.96, 'lng': 77.5});
      rt.emit({'type': 'DISCOVERY', 'state': 'NEW', 'encounterId': enc, 'type_': 'x'});
      await settle();
      expect(c.assistRequests, isEmpty);
      expect(c.hazards, isEmpty);
      expect(c.encounters, isEmpty);
      expect(c.answerAssist(inc, AssistAnswer.accept), isFalse);
      expect(c.reportFalseAlert(inc), isFalse);
      expect(c.reportRiderDown(lat: 12.95, lng: 77.55), isFalse);
      expect(c.wave(enc), isFalse);
      expect(c.setGroupVisibility(visibility: GroupVisibility.public, assistDefault: false), isFalse);
      for (final t in ['ASSIST_ANSWER', 'NET_REPORT_FALSE', 'REPORT_DOWN', 'WAVE', 'CONFIG']) {
        expect(rt.sentOf(t), isEmpty, reason: t);
      }
      c.dispose();
    });
  });

  group('Hazards and discovery', () {
    test('HAZARD upserts, HAZARD_CLEAR removes, stale ones drop, the setting hides them', () async {
      var now = 1800000000000;
      final settings = SettingsService();
      await settings.load();
      final rt = Rt(allNet);
      final c = await start(rt, clock: () => now, settings: settings);
      rt.emit({'type': 'HAZARD', 'hazardId': inc, 'lat': 12.96, 'lng': 77.5, 'level': 'ACTIVE', 'aheadM': 2000, 'onRoute': true, 'reportedAt': 1});
      await settle();
      expect(c.hazards.single.level, HazardLevel.active);
      rt.emit({'type': 'HAZARD', 'hazardId': inc, 'lat': 12.96, 'lng': 77.5, 'level': 'ON_SCENE'});
      await settle();
      expect(c.hazards.single.level, HazardLevel.onScene);
      await settings.setHazardAlerts(false);
      expect(c.hazards, isEmpty);
      await settings.setHazardAlerts(true);
      expect(c.hazards.length, 1, reason: 'kept while hidden');
      now += const Duration(hours: 3, minutes: 1).inMilliseconds;
      expect(c.hazards, isEmpty);
      now -= const Duration(hours: 3, minutes: 1).inMilliseconds;
      rt.emit({'type': 'HAZARD_CLEAR', 'hazardId': inc});
      await settle();
      expect(c.hazards, isEmpty);
      c.dispose();
    });

    test('DISCOVERY new, update, end; ignore until the type changes; wave once; waved', () async {
      final rt = Rt(allNet);
      final c = await start(rt);
      rt.emit({'type': 'DISCOVERY', 'state': 'NEW', 'encounterId': enc, 'groupName': 'Weekend Riders'});
      await settle();
      expect(c.encounters, isEmpty, reason: 'no encounter type: ignored');
      rt.emit(_discovery('NEW', 'SAME_DIRECTION'));
      await settle();
      expect(c.encounters.single.groupName, 'Weekend Riders');
      expect(c.wave(enc), isTrue);
      expect(c.wave(enc), isFalse);
      expect(rt.sentOf('WAVE').single['encounterId'], enc);
      expect(c.encounters.single.iWaved, isTrue);
      rt.emit({'type': 'WAVED', 'encounterId': enc, 'groupName': 'Royal Riders', 'at': 5});
      await settle();
      expect(c.encounters.single.theyWavedAt, isNotNull);
      c.ignoreEncounter(enc);
      expect(c.encounters, isEmpty);
      rt.emit(_discovery('UPDATE', 'SAME_DIRECTION'));
      await settle();
      expect(c.encounters, isEmpty, reason: 'still ignored');
      rt.emit(_discovery('UPDATE', 'CONVERGING'));
      await settle();
      expect(c.encounters.single.type, EncounterType.converging);
      expect(c.encounters.single.iWaved, isTrue, reason: 'kept across updates');
      rt.emit(_discovery('END', 'CONVERGING'));
      await settle();
      expect(c.encounters, isEmpty);
      c.dispose();
    });
  });

  group('Clearing', () {
    Future<(ConvoyService, Rt)> filled() async {
      final rt = Rt(allNet);
      final c = await start(rt);
      rt.emit(request());
      rt.emit({'type': 'HAZARD', 'hazardId': inc, 'lat': 12.96, 'lng': 77.5});
      rt.emit(_discovery('NEW', 'OPPOSITE_DIRECTION'));
      await settle();
      expect(c.assistRequests, isNotEmpty);
      expect(c.hazards, isNotEmpty);
      expect(c.encounters, isNotEmpty);
      return (c, rt);
    }

    void expectEmpty(ConvoyService c) {
      expect(c.assistRequests, isEmpty);
      expect(c.activeAssist, isNull);
      expect(c.hazards, isEmpty);
      expect(c.encounters, isEmpty);
    }

    test('trip end', () async {
      final (c, rt) = await filled();
      rt.emit({'type': 'TRIP_STATUS', 'tripStatus': 'ENDED'});
      await settle();
      expectEmpty(c);
      c.dispose();
    });

    test('leave', () async {
      final (c, _) = await filled();
      await c.leaveActiveConvoy(me);
      expectEmpty(c);
      c.dispose();
    });

    test('sign-out', () async {
      final (c, _) = await filled();
      await c.endSession();
      expectEmpty(c);
      c.dispose();
    });

    test('reconnect: kept until the server sends it again; dropped after the grace when it does not', () async {
      var now = 1800000000000;
      final rt = Rt(allNet);
      final c = await start(rt, clock: () => now);
      rt.emit(request());
      rt.emit(request(id: 'NET-0000000000CC'));
      rt.emit({'type': 'HAZARD', 'hazardId': inc, 'lat': 12.96, 'lng': 77.5});
      rt.emit(_discovery('NEW', 'OPPOSITE_DIRECTION'));
      await settle();
      expect(c.answerAssist(inc, AssistAnswer.accept), isTrue);
      rt.setConnected(false);
      expect(c.activeAssist?.incidentId, inc, reason: 'kept in a dead zone');
      rt.setConnected(true);
      // Navigation to the emergency must not stop on the way out of a dead zone.
      expect(c.activeAssist?.incidentId, inc);
      expect(c.hazards, isNotEmpty);
      expect(c.encounters, isEmpty, reason: 'discovery starts over');
      // The server sends again what is still open (inc and the hazard), not the other request.
      rt.emit({'type': 'ASSIST_UPDATE', 'incidentId': inc, 'incidentStatus': 'RESPONDER_ASSIGNED', 'myStatus': 'EN_ROUTE', 'lat': 12.96, 'lng': 77.5, 'lastUpdateAt': 2});
      rt.emit({'type': 'HAZARD', 'hazardId': inc, 'lat': 12.96, 'lng': 77.5});
      await settle();
      expect(c.assistRequests.map((r) => r.incidentId).toSet(), {inc, 'NET-0000000000CC'}, reason: 'within the grace');
      now += NetworkConstants.resendGrace.inMilliseconds + 1000;
      expect(c.assistRequests.map((r) => r.incidentId).toList(), [inc], reason: 'not sent again: closed meanwhile');
      expect(c.activeAssist?.incidentId, inc);
      expect(c.hazards.single.hazardId, inc);
      c.dispose();
    });

    test('asked again after "another rider is responding": the notice goes', () async {
      final rt = Rt(allNet);
      final c = await start(rt);
      rt.emit(request());
      rt.emit({'type': 'ASSIST_CLOSED', 'incidentId': inc, 'reason': 'TAKEN'});
      await settle();
      expect(c.assistNotices, isNotEmpty);
      rt.emit(request());
      await settle();
      expect(c.assistNotices, isEmpty);
      expect(c.assistRequests.single.incidentId, inc);
      c.dispose();
    });
  });

  group('Outbox rules for the new actions', () {
    test('ACCEPT is never dropped for age; a WAVE older than 2 min is', () async {
      var now = 1800000000000;
      final rt = Rt(allNet);
      final c = await start(rt, clock: () => now);
      rt.emit(request());
      rt.emit(_discovery('NEW', 'SAME_DIRECTION'));
      await settle();
      rt.setConnected(false);
      // Lists are kept offline; answers wait for signal.
      expect(c.answerAssist(inc, AssistAnswer.accept), isTrue);
      expect(c.wave(enc), isTrue);
      expect(c.outbox.map((i) => i.type).toList(), ['ASSIST_ANSWER', 'WAVE']);
      now += const Duration(hours: 7).inMilliseconds;
      rt.setConnected(true);
      rt.emit({'type': 'SNAPSHOT'});
      await settle();
      expect(rt.sentOf('ASSIST_ANSWER').single['answer'], 'ACCEPT');
      expect(rt.sentOf('WAVE'), isEmpty);
      c.dispose();
    });
  });

  group('SOS', () {
    test('notification SOS opens the hold screen and never sends', () async {
      final rt = Rt(allNet);
      final c = await start(rt);
      c.debugNotificationButton(BackgroundService.buttonSos);
      expect(c.sosRequestedFromNotification, isTrue);
      c.clearSosRequest();
      c.openSosFromNotification();
      expect(c.sosRequestedFromNotification, isTrue);
      await settle();
      expect(rt.sentOf('SOS'), isEmpty);
      expect(c.pendingSos, isNull);
      c.dispose();
    });

    test('wait for me from the notification goes through the outbox', () async {
      final rt = Rt(allNet);
      final c = await start(rt);
      c.requestWaitFromNotification();
      expect(rt.sentOf('WAIT').length, 1);
      c.dispose();
    });

    test('raiseSos sends source, heading and speed from my last fix', () async {
      final rt = Rt(allNet);
      final c = await start(rt);
      c.raiseSos(type: SosTypes.crash, lat: 12.9, lng: 77.5, auto: true, source: EmergencySource.crashAuto);
      final m = rt.sentOf('SOS').last;
      expect(m['source'], 'CRASH_AUTO');
      expect(m['heading'], 91);
      expect(m['speedKmh'], 30.0);
      expect(m.containsKey('accuracyM'), isFalse, reason: 'no GPS fix in a unit test');
      expect(c.pendingSos!.source, EmergencySource.crashAuto);
      // A manual press later never downgrades it.
      c.triggerSosAlert(userId: me, userName: 'Me', lat: 12.9, lng: 77.5);
      expect(c.pendingSos!.source, EmergencySource.crashAuto);
      expect(rt.sentOf('SOS').last['source'], 'CRASH_AUTO');
      c.dispose();
    });

    test('resolve reason only to a net1 gateway; cancel defaults to false alarm', () async {
      final rt = Rt(allNet);
      final c = await start(rt);
      c.resolveSosAlert('SOS-K', reason: ResolveReason.resolved);
      expect(rt.sentOf('SOS_RESOLVE').last['reason'], 'RESOLVED');
      rt.emit({
        'type': 'ALERT',
        'alert': {'alertId': 'SOS-ME', 'userId': me, 'userName': 'Me', 'timestamp': 2},
      });
      await settle();
      c.cancelMySos();
      expect(rt.sentOf('SOS_RESOLVE').last['alertId'], 'SOS-ME');
      expect(rt.sentOf('SOS_RESOLVE').last['reason'], 'FALSE_ALARM');
      c.dispose();

      final old = Rt({ProtocolFeatures.ack});
      final c2 = await start(old);
      c2.resolveSosAlert('SOS-K', reason: ResolveReason.falseAlarm);
      expect(old.sentOf('SOS_RESOLVE').single.containsKey('reason'), isFalse);
      c2.dispose();
    });

    test('EMERGENCY_UPDATE patches the alert: status, position, network, own nearest', () async {
      final rt = Rt(allNet);
      final c = await start(rt);
      rt.emit({
        'type': 'EMERGENCY_UPDATE',
        'alertId': 'SOS-K',
        'status': 'RESPONDER_ASSIGNED',
        'lastUpdateAt': 99,
        'lat': 12.951,
        'lng': 77.551,
        'network': {
          'state': 'ASSIGNED',
          'stage': 1,
          'notified': 1,
          'responders': [
            {'rid': 'abcabcabcabc', 'name': 'Arjun', 'status': 'EN_ROUTE', 'etaS': 180, 'distanceM': 1500},
          ],
        },
        'ownNearest': {'userId': me, 'name': 'Me', 'etaS': 600, 'distanceM': 5000, 'routeBased': true},
      });
      await settle();
      final a = c.activeConvoy!.activeAlerts.single;
      expect(a.status, EmergencyStatus.responderAssigned);
      expect(a.lat, 12.951);
      expect(a.lastKnownAt, 99);
      expect(a.network!.activeResponder!.name, 'Arjun');
      expect(a.ownNearest!.etaS, 600);
      // No signal from the rider: no position in the update, the last one stays.
      rt.emit({'type': 'EMERGENCY_UPDATE', 'alertId': 'SOS-K', 'status': 'RESPONDER_ASSIGNED', 'ownNearest': null});
      await settle();
      expect(c.activeConvoy!.activeAlerts.single.lat, 12.951);
      expect(c.activeConvoy!.activeAlerts.single.ownNearest, isNull);
      c.dispose();
    });
  });

  group('Group visibility (lead only)', () {
    test('lead sends CONFIG with the supported fields; CONFIG echo applies', () async {
      final rt = Rt(allNet);
      final c = await start(rt);
      expect(c.activeConvoy!.visibility, GroupVisibility.private);
      expect(c.setGroupVisibility(visibility: GroupVisibility.public, discovery: true, assistDefault: false), isTrue);
      final m = rt.sentOf('CONFIG').single;
      expect(m['visibility'], 'PUBLIC');
      expect(m['discovery'], isTrue);
      expect(m['assistDefault'], isFalse);
      expect(c.activeConvoy!.visibility, GroupVisibility.public);
      rt.emit({'type': 'CONFIG', 'visibility': 'PRIVATE', 'discovery': false, 'assistDefault': true});
      await settle();
      expect(c.activeConvoy!.visibility, GroupVisibility.private);
      expect(c.activeConvoy!.discovery, isFalse);
      expect(c.activeConvoy!.assistDefault, isTrue);
      c.dispose();
    });

    test('not the lead: refused', () async {
      final rt = Rt(allNet);
      final c = await start(rt, lead: 'usr_lead');
      expect(c.setGroupVisibility(visibility: GroupVisibility.public), isFalse);
      expect(rt.sentOf('CONFIG'), isEmpty);
      c.dispose();
    });
  });
}

/// A DISCOVERY message. The encounter type travels as `encounterType` (the message's own
/// `type` is DISCOVERY; see DEV_NET deviations).
Map<String, dynamic> _discovery(String state, String type) => {
      'type': 'DISCOVERY',
      'encounterType': type,
      'state': state,
      'encounterId': enc,
      'groupName': 'Weekend Riders',
      'riders': 6,
      'distanceM': 4500,
      'sameRoute': true,
    };
