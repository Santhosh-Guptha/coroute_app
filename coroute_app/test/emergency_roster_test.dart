import 'dart:async';
import 'dart:convert';

import 'package:coroute_app/core/constants/net_constants.dart';
import 'package:coroute_app/data/local/roster_store.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/emergency_roster.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/services/api_client.dart';
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

class FakeRt extends RealtimeService {
  FakeRt({Set<String> features = const {ProtocolFeatures.roster}}) : features = {...features};

  Set<String> features;
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
  bool send(Map<String, dynamic> message) => true;
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

  /// As if the socket reconnected (ConvoyService listens to connection changes).
  void reconnected() => notifyListeners();
}

const gid = 'GRP-1';
const now0 = 1700000000000;

Map<String, dynamic> rosterJson({String group = gid}) => {
      'groupId': group,
      'generatedAt': now0,
      'validUntil': now0 + 12 * 3600 * 1000,
      'cap': 10,
      'members': [
        {'userId': 'usr_lead', 'role': 'LEAD', 'phone': '+91 98765 43210'},
        {'userId': 'usr_k', 'role': 'PACK', 'phone': '+91 90000 00001'},
        {'userId': 'usr_dup', 'role': 'PACK', 'phone': '+91 90000 00001'},
      ],
      'emergencyContact': {'name': 'Brother', 'phone': '+91 91234 56780'},
    };

class Harness {
  Harness(this.convoys, this.rt, this.settings, this.hits);
  final ConvoyService convoys;
  final FakeRt rt;
  final SettingsService settings;
  final List<int> hits;
}

Future<Harness> start({
  bool smsOn = false,
  int rosterStatus = 200,
  Set<String> features = const {ProtocolFeatures.roster},
  Map<String, String> secure = const {},
  String tripStatus = 'STARTED',
  Duration debounce = const Duration(milliseconds: 80),
  int Function()? clock,
}) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues(Map<String, String>.from(secure));
  final settings = SettingsService();
  await settings.load();
  if (smsOn) await settings.setSmsFallback(true);
  final hits = <int>[];
  final convoy = ConvoyModel(
    groupId: gid,
    name: 'Hill run',
    joinCode: '123456',
    createdByUserId: 'usr_lead',
    createdByUserName: 'Lead',
    createdAtEpochMs: 1,
    tripStatus: tripStatus,
    riders: {'usr_me': RiderModel(userId: 'usr_me', name: 'Me', lat: 12.9, lng: 77.5, lastSeenEpochMs: 1)},
  );
  final api = ApiClient(
    httpClient: MockClient((req) async {
      if (req.url.path.endsWith('/convoys/active')) return http.Response(jsonEncode({'convoy': convoy.toJson()}), 200);
      if (req.url.path.endsWith('/emergency-roster')) {
        hits.add(rosterStatus);
        if (rosterStatus != 200) return http.Response(jsonEncode({'error': 'no', 'code': 'X'}), rosterStatus);
        return http.Response(jsonEncode(rosterJson()), 200);
      }
      return http.Response('{}', 200);
    }),
    storage: const FlutterSecureStorage(),
  );
  final rt = FakeRt(features: features);
  final c = ConvoyService(api, rt, TripStorageService(api), settings: settings, clock: clock ?? () => now0, rosterDebounce: debounce);
  await c.startSession(token: 't', userId: 'usr_me');
  await Future<void>.delayed(const Duration(milliseconds: 40));
  return Harness(c, rt, settings, hits);
}

Future<void> settle([int ms = 40]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/charging'),
      (call) async => null,
    );
  });

  test('model: phones deduped, validity on the phone clock, toString prints no phone', () {
    final r = EmergencyRoster.fromJson(rosterJson(), fetchedAt: now0 + 5000)!;
    expect(r.members.length, 2);
    expect(r.emergencyContact?.phone, '+91 91234 56780');
    expect(r.isValidFor(gid, now0 + 6000), isTrue);
    expect(r.isValidFor('GRP-2', now0 + 6000), isFalse);
    expect(r.isValidFor(gid, r.validUntil), isFalse);
    final text = '$r ${r.members.first} ${r.emergencyContact}';
    expect(text.contains('98765'), isFalse);
    expect(text.contains('91234'), isFalse);
    expect(text.contains('90000'), isFalse);
    final back = EmergencyRoster.decode(r.encode())!;
    expect(back.members.map((m) => m.phone), r.members.map((m) => m.phone));
    expect(back.validUntil, r.validUntil);
  });

  test('not fetched while the SMS fallback is off', () async {
    final h = await start();
    expect(h.hits, isEmpty);
    expect(h.convoys.emergencyRoster, isNull);
    h.convoys.dispose();
  });

  test('not fetched from an older gateway, nor before the ride starts', () async {
    final old = await start(smsOn: true, features: const {});
    expect(old.hits, isEmpty);
    old.convoys.dispose();
    final planning = await start(smsOn: true, tripStatus: 'PLANNING');
    expect(planning.hits, isEmpty);
    planning.rt.emit({'type': 'TRIP_STATUS', 'tripStatus': 'STARTED'});
    await settle();
    expect(planning.hits.length, 1);
    expect(planning.convoys.emergencyRoster, isNotNull);
    planning.convoys.dispose();
  });

  test('fetched on activate when opted in, kept encrypted, cleared when the setting goes off', () async {
    final h = await start(smsOn: true);
    expect(h.hits.length, 1);
    expect(h.convoys.emergencyRoster?.members.length, 2);
    expect(await RosterStore().load(), isNotNull);
    await h.settings.setSmsFallback(false);
    await settle();
    expect(h.convoys.emergencyRoster, isNull);
    expect(await RosterStore().load(), isNull);
    // Turning it on again fetches at once.
    await h.settings.setSmsFallback(true);
    await settle();
    expect(h.hits.length, 2);
    expect(h.convoys.emergencyRoster, isNotNull);
    h.convoys.dispose();
  });

  test('restored from the store after a restart only for the same ride and while valid', () async {
    final stored = EmergencyRoster.fromJson(rosterJson(), fetchedAt: now0)!;
    final same = await start(smsOn: true, rosterStatus: 500, secure: {NetConstants.keyRoster: stored.encode()});
    expect(same.convoys.emergencyRoster?.members.length, 2, reason: 'offline after a restart: the stored copy is used');
    same.convoys.dispose();

    final other = EmergencyRoster.fromJson(rosterJson(group: 'GRP-OLD'), fetchedAt: now0)!;
    final h = await start(smsOn: true, rosterStatus: 500, secure: {NetConstants.keyRoster: other.encode()});
    expect(h.convoys.emergencyRoster, isNull);
    expect(await RosterStore().load(), isNull);
    h.convoys.dispose();

    final expired = EmergencyRoster(groupId: gid, fetchedAt: now0 - 20 * 3600 * 1000, validUntil: now0 - 1);
    final e = await start(smsOn: true, rosterStatus: 500, secure: {NetConstants.keyRoster: expired.encode()});
    expect(e.convoys.emergencyRoster, isNull);
    e.convoys.dispose();
  });

  test('a refused fetch (not a member, ride not active) clears what is on the phone', () async {
    final stored = EmergencyRoster.fromJson(rosterJson(), fetchedAt: now0)!;
    final h = await start(smsOn: true, rosterStatus: 409, secure: {NetConstants.keyRoster: stored.encode()});
    expect(h.hits.length, 1);
    expect(await RosterStore().load(), isNull);
    h.convoys.dispose();
  });

  test('cleared when the ride ends', () async {
    final h = await start(smsOn: true);
    expect(h.convoys.emergencyRoster, isNotNull);
    h.rt.emit({'type': 'TRIP_STATUS', 'tripStatus': 'ENDED'});
    await settle();
    expect(h.convoys.emergencyRoster, isNull);
    expect(await RosterStore().load(), isNull);
    h.convoys.dispose();
  });

  test('cleared when the rider leaves', () async {
    final h = await start(smsOn: true);
    await h.convoys.leaveActiveConvoy('usr_me');
    await settle();
    expect(h.convoys.emergencyRoster, isNull);
    expect(await RosterStore().load(), isNull);
    h.convoys.dispose();
  });

  test('cleared on sign-out', () async {
    final h = await start(smsOn: true);
    await h.convoys.endSession();
    await settle();
    expect(h.convoys.emergencyRoster, isNull);
    expect(await RosterStore().load(), isNull);
    h.convoys.dispose();
  });

  // Regression (r314 behaviour test): a roster held for most of its 12 h was never renewed
  // (the reconnect fetch ran only when none was held), so on a long or multi-day ride it expired
  // and a dead-zone SOS texted only the emergency contact.
  test('an ageing roster is renewed on reconnect while there is signal; a fresh one is not', () async {
    var now = now0;
    final h = await start(smsOn: true, clock: () => now);
    expect(h.hits.length, 1);
    now += 2 * 3600 * 1000;
    h.rt.reconnected();
    await settle();
    expect(h.hits.length, 1, reason: 'still fresh: no fetch on every reconnect');
    now += 5 * 3600 * 1000; // 7 h old, more than half of 12 h
    h.rt.reconnected();
    await settle();
    expect(h.hits.length, 2);
    now += 2 * 3600 * 1000; // 2 h after the renewal: fresh again
    expect(h.convoys.emergencyRoster, isNotNull);
    h.rt.reconnected();
    await settle();
    expect(h.hits.length, 2);
    now += 13 * 3600 * 1000;
    h.rt.reconnected();
    await settle();
    expect(h.hits.length, 3, reason: 'expired: fetched again');
    expect(h.convoys.emergencyRoster, isNotNull);
    h.convoys.dispose();
  });

  test('ROSTER_CHANGED and riders joining or leaving refetch once per debounce window', () async {
    final h = await start(smsOn: true);
    expect(h.hits.length, 1);
    h.rt.emit({'type': 'ROSTER_CHANGED'});
    h.rt.emit({'type': 'RIDER_LEFT', 'userId': 'usr_k'});
    h.rt.emit({'type': 'ROSTER_CHANGED'});
    await settle(20);
    expect(h.hits.length, 1, reason: 'debounced');
    await settle(200);
    expect(h.hits.length, 2);
    h.convoys.dispose();
  });
}
