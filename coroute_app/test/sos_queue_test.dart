import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/medical_info.dart';
import 'package:coroute_app/data/models/pending_sos.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/widgets/connection_banner.dart';
import 'package:coroute_app/presentation/widgets/emergency_sos_sheet.dart';

/// A realtime link without a network (records what is sent).
class _FakeRt extends RealtimeService {
  final List<Map<String, dynamic>> sent = [];
  bool connected = true;
  final StreamController<Map<String, dynamic>> _ctrl = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _ctrl.stream;
  @override
  bool get isConnected => connected;
  @override
  RealtimeState get state => connected ? RealtimeState.connected : RealtimeState.disconnected;
  @override
  bool supports(String feature) => true;
  @override
  bool send(Map<String, dynamic> message) {
    if (!connected) return false;
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

  void emit(Map<String, dynamic> m) => _ctrl.add(m);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sos = PendingSos(clientId: 'usr_a-1700000000000', groupId: 'GRP-1', lat: 12.97, lng: 77.59, type: 'CRASH_OR_EMERGENCY', createdAt: 1700000000000);

  group('Pending SOS', () {
    test('round-trips through its stored form', () {
      final back = PendingSos.decode(sos.encode());
      expect(back, isNotNull);
      expect(back!.clientId, sos.clientId);
      expect(back.groupId, 'GRP-1');
      expect(back.lat, 12.97);
      expect(back.type, 'CRASH_OR_EMERGENCY');
      expect(back.toMessage()['clientId'], sos.clientId);
      expect(back.toMessage()['type'], 'SOS');
    });

    test('bad stored data is ignored', () {
      expect(PendingSos.decode(null), isNull);
      expect(PendingSos.decode('not json'), isNull);
      expect(PendingSos.decode('{"groupId":"GRP-1"}'), isNull);
    });

    test('only the echo with the same clientId confirms it', () {
      final echo = SosAlertModel.fromJson({'alertId': 'SOS-1', 'userId': 'usr_a', 'clientId': sos.clientId, 'timestamp': 1});
      final other = SosAlertModel.fromJson({'alertId': 'SOS-2', 'userId': 'usr_a', 'timestamp': 1});
      expect(sos.matches(echo.clientId), isTrue);
      expect(sos.matches(other.clientId), isFalse);
      expect(sos.matches(null), isFalse);
    });

    test('stored SOS from 3.13 (no crash fields) still decodes', () {
      final old = PendingSos.decode('{"clientId":"usr_a-1","groupId":"GRP-1","lat":1.5,"lng":2.5,"type":"EMERGENCY","createdAt":5}');
      expect(old, isNotNull);
      expect(old!.auto, isFalse);
      expect(old.speedBeforeKmh, isNull);
      final m = old.toMessage();
      expect(m['auto'], isFalse);
      expect(m['occurredAt'], 5);
      expect(m.containsKey('speedBeforeKmh'), isFalse);
      expect(m.containsKey('impactG'), isFalse);
    });

    test('crash fields round-trip and go on the wire', () {
      const crash = PendingSos(clientId: 'c-1', groupId: 'GRP-1', lat: 1, lng: 2, type: SosTypes.crash, createdAt: 77, auto: true, speedBeforeKmh: 55.5, impactG: 6.2);
      final back = PendingSos.decode(crash.encode())!;
      expect(back.auto, isTrue);
      expect(back.speedBeforeKmh, 55.5);
      expect(back.impactG, 6.2);
      final m = back.toMessage();
      expect(m['alertType'], 'CRASH');
      expect(m['auto'], isTrue);
      expect(m['speedBeforeKmh'], 55.5);
      expect(m['impactG'], 6.2);
      expect(m['occurredAt'], 77);
    });

    test('alerts: crash details, responders and medical info parse; old alerts keep defaults', () {
      final a = SosAlertModel.fromJson({
        'alertId': 'SOS-9',
        'userId': 'usr_k',
        'userName': 'Kiran',
        'alertType': 'CRASH',
        'timestamp': 100,
        'auto': true,
        'details': {'speedBeforeKmh': 55, 'impactG': 6.1},
        'occurredAt': 90,
        'responders': [
          {'userId': 'usr_a', 'name': 'Arjun', 'kind': 'GOING', 'at': 101},
          {'userId': 'usr_b', 'name': 'Bala', 'kind': 'WITH_THEM', 'at': 102},
        ],
        'medical': {'bloodGroup': 'O+', 'allergies': 'penicillin'},
      });
      expect(a.isCrash, isTrue);
      expect(a.auto, isTrue);
      expect(a.speedBeforeKmh, 55);
      expect(a.impactG, 6.1);
      expect(a.occurredAt, 90);
      expect(a.responders.map((r) => r.kind).toList(), [SosResponseKind.going, SosResponseKind.withThem]);
      expect(a.medical?.bloodGroup, 'O+');
      expect(a.medical?.allergies, 'penicillin');
      final again = SosAlertModel.fromJson(a.toJson());
      expect(again.responders.length, 2);
      expect(again.medical?.bloodGroup, 'O+');
      expect(again.speedBeforeKmh, 55);

      final old = SosAlertModel.fromJson({'alertId': 'SOS-1', 'userId': 'usr_a', 'timestamp': 7});
      expect(old.auto, isFalse);
      expect(old.occurredAt, 7);
      expect(old.responders, isEmpty);
      expect(old.medical, isNull);
      expect(MedicalInfo.fromJson({'bloodGroup': '', 'allergies': ' '}), isNull);
    });

    test('a newer position keeps the same clientId', () {
      final moved = sos.copyWith(lat: 13.0);
      expect(moved.clientId, sos.clientId);
      expect(moved.lat, 13.0);
    });

    test('the store saves, loads and clears it', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await PendingSosStore.load(), isNull);
      await PendingSosStore.save(sos);
      expect((await PendingSosStore.load())?.clientId, sos.clientId);
      await PendingSosStore.clear();
      expect(await PendingSosStore.load(), isNull);
    });
  });

  group('Connection banner lines', () {
    test('offline with points and an SOS waiting', () {
      final l = ConnectionBanner.lines(connecting: false, pendingPoints: 42, sosWaiting: true);
      expect(l.first, startsWith('Offline'));
      expect(l, contains('42 points waiting to upload'));
      expect(l, contains('SOS waiting to send'));
    });

    test('nothing waiting: only the state line', () {
      expect(ConnectionBanner.lines(connecting: true, pendingPoints: 0, sosWaiting: false).length, 1);
      expect(ConnectionBanner.lines(connecting: true, pendingPoints: 1, sosWaiting: false)[1], '1 point waiting to upload');
    });

    test('top bar status: nothing when live, last update when not, SOS first', () {
      const now = 1700000000000;
      expect(ConnectionBanner.status(state: RealtimeState.connected, lastUpdateMs: now, nowMs: now), isNull);
      expect(ConnectionBanner.status(state: RealtimeState.disconnected, lastUpdateMs: now - 120000, nowMs: now), 'Offline, last updated 2 min ago');
      expect(ConnectionBanner.status(state: RealtimeState.connecting, lastUpdateMs: now - 5000, nowMs: now), 'Reconnecting, last updated just now');
      expect(ConnectionBanner.status(state: RealtimeState.disconnected, lastUpdateMs: 0, nowMs: now), 'Offline');
      expect(ConnectionBanner.status(state: RealtimeState.disconnected, nowMs: now, sosWaiting: true), 'SOS waiting to send');
      expect(ConnectionBanner.status(state: RealtimeState.connected, nowMs: now, sosWaiting: true), 'Sending your SOS');
    });
  });

  group('SOS sheet status', () {
    test('never says delivered before the server confirmed it', () {
      expect(EmergencySosSheet.statusFor(hasService: true, pending: true, online: true, hasOpenAlert: false), SosSheetStatus.sending);
      expect(EmergencySosSheet.statusFor(hasService: true, pending: true, online: false, hasOpenAlert: false), SosSheetStatus.waitingForSignal);
      expect(EmergencySosSheet.statusFor(hasService: true, pending: true, online: true, hasOpenAlert: true), SosSheetStatus.sending);
      expect(EmergencySosSheet.statusFor(hasService: true, pending: false, online: true, hasOpenAlert: true), SosSheetStatus.delivered);
      expect(EmergencySosSheet.statusFor(hasService: false, pending: false, online: false, hasOpenAlert: true), SosSheetStatus.unknown);
    });
  });

  group('SOS kept across a restart', () {
    late ApiClient api;
    late AuthService auth;
    late RealtimeService rt;
    late ConvoyService convoys;

    Future<void> setUpServices(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({AppConstants.keyPendingSos: sos.encode()});
      FlutterSecureStorage.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/charging'),
        (call) async => null,
      );
      await tester.runAsync(() async {
        api = ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: const FlutterSecureStorage());
        auth = AuthService(api);
        rt = RealtimeService();
        convoys = ConvoyService(api, rt, TripStorageService(api));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
    }

    Future<void> tearDownServices(WidgetTester tester) async {
      await tester.runAsync(() async {
        convoys.dispose();
        rt.dispose();
      });
    }

    testWidgets('an SOS stored before the app closed is loaded again; offline, the sheet says it is waiting', (tester) async {
      await setUpServices(tester);
      expect(convoys.pendingSos?.clientId, sos.clientId);

      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthService>.value(value: auth),
          ChangeNotifierProvider<ConvoyService>.value(value: convoys),
        ],
        child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: EmergencySosSheet(lat: 12.97, lng: 77.59)))),
      ));
      await tester.pump();

      expect(find.text('No signal. SOS not sent yet'), findsOneWidget);
      expect(find.textContaining('sent as soon as the phone is back online'), findsOneWidget);
      expect(find.textContaining('Delivered'), findsNothing);
      expect(find.textContaining('delivered'), findsNothing);

      // "I am safe" drops the waiting SOS from the phone and from disk.
      await tester.runAsync(() async {
        convoys.cancelMySos();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      expect(convoys.pendingSos, isNull);
      await tester.runAsync(() async {
        expect(await PendingSosStore.load(), isNull);
      });
      await tearDownServices(tester);
    });
  });

  group('3.14 SOS through the convoy service', () {
    Future<(ConvoyService, _FakeRt)> start() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/charging'),
        (call) async => null,
      );
      final convoy = ConvoyModel(
        groupId: 'GRP-1',
        name: 'Hill run',
        joinCode: '123456',
        createdByUserId: 'usr_me',
        createdByUserName: 'Me',
        createdAtEpochMs: 1,
        riders: {
          'usr_me': RiderModel(userId: 'usr_me', name: 'Me', lat: 12.9, lng: 77.5, lastSeenEpochMs: 1),
          'usr_k': RiderModel(userId: 'usr_k', name: 'Kiran', lat: 12.95, lng: 77.55, lastSeenEpochMs: 1),
        },
        activeAlerts: [SosAlertModel(alertId: 'SOS-K', userId: 'usr_k', userName: 'Kiran', lat: 12.95, lng: 77.55, timestamp: 1)],
      );
      final api = ApiClient(
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/convoys/active')) return http.Response(jsonEncode({'convoy': convoy.toJson()}), 200);
          return http.Response('{}', 200);
        }),
        storage: const FlutterSecureStorage(),
      );
      final rt = _FakeRt();
      final c = ConvoyService(api, rt, TripStorageService(api));
      await c.startSession(token: 't', userId: 'usr_me');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return (c, rt);
    }

    test('raiseSos CRASH sends the automatic crash fields', () async {
      final (c, rt) = await start();
      final r = c.raiseSos(type: SosTypes.crash, lat: 12.9, lng: 77.5, auto: true, speedBeforeKmh: 55, impactG: 6.2, occurredAtMs: 1700000000000);
      expect(r, SosDelivery.sent);
      final m = rt.sent.lastWhere((x) => x['type'] == 'SOS');
      expect(m['alertType'], 'CRASH');
      expect(m['auto'], isTrue);
      expect(m['speedBeforeKmh'], 55);
      expect(m['impactG'], 6.2);
      expect(m['occurredAt'], 1700000000000);
      expect(m['clientId'], c.pendingSos!.clientId);
      c.dispose();
    });

    test('a crash raise upgrades a pending manual SOS and keeps its clientId', () async {
      final (c, rt) = await start();
      rt.connected = false;
      expect(c.triggerSosAlert(userId: 'usr_me', userName: 'Me', lat: 12.9, lng: 77.5, type: 'CRASH_OR_EMERGENCY'), SosDelivery.queued);
      final id = c.pendingSos!.clientId;
      c.raiseSos(type: SosTypes.crash, lat: 12.91, lng: 77.51, auto: true, speedBeforeKmh: 48, impactG: 5);
      expect(c.pendingSos!.clientId, id);
      expect(c.pendingSos!.type, 'CRASH');
      expect(c.pendingSos!.auto, isTrue);
      expect(c.pendingSos!.speedBeforeKmh, 48);
      expect(c.pendingSos!.lat, 12.91);
      // A later manual press never downgrades it.
      c.triggerSosAlert(userId: 'usr_me', userName: 'Me', lat: 12.92, lng: 77.52);
      expect(c.pendingSos!.type, 'CRASH');
      expect(c.pendingSos!.clientId, id);
      c.dispose();
    });

    test('SOS_RESPONSE updates the responders of the alert', () async {
      final (c, rt) = await start();
      rt.emit({
        'type': 'SOS_RESPONSE',
        'alertId': 'SOS-K',
        'userId': 'usr_me',
        'name': 'Me',
        'kind': 'GOING',
        'at': 5,
        'responders': [
          {'userId': 'usr_me', 'name': 'Me', 'kind': 'GOING', 'at': 5},
        ],
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final a = c.activeConvoy!.activeAlerts.single;
      expect(a.responders.single.name, 'Me');
      expect(c.myResponseTo('SOS-K'), SosResponseKind.going);
      rt.emit({'type': 'SOS_RESPONSE', 'alertId': 'SOS-K', 'userId': 'usr_me', 'kind': null, 'at': 6, 'responders': []});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.activeConvoy!.activeAlerts.single.responders, isEmpty);
      expect(c.myResponseTo('SOS-K'), isNull);
      c.dispose();
    });

    test('ALERT with medical info is kept with the alert', () async {
      final (c, rt) = await start();
      rt.emit({
        'type': 'ALERT',
        'alert': {'alertId': 'SOS-2', 'userId': 'usr_k', 'userName': 'Kiran', 'alertType': 'CRASH', 'auto': true, 'timestamp': 9, 'medical': {'bloodGroup': 'B+'}},
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final a = c.activeConvoy!.activeAlerts.firstWhere((x) => x.alertId == 'SOS-2');
      expect(a.medical?.bloodGroup, 'B+');
      expect(a.isCrash, isTrue);
      c.dispose();
    });
  });
}
