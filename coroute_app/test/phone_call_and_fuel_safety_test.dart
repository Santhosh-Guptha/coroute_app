import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/route_essential.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/phone_call_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/route_essentials_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/voice_service.dart';
import 'package:coroute_app/domain/route/route_guide.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeVoiceEngine implements VoiceEngine, VoiceEngineLanguage {
  final List<String> spokenTexts = [];
  bool initialized = false;

  @override
  String get language => 'en-IN';

  @override
  Future<bool> init() async {
    initialized = true;
    return true;
  }

  @override
  Future<bool> speak(
    String text, {
    required bool interrupt,
    required String id,
    bool isEmergency = false,
    bool pauseOthers = false,
  }) async {
    spokenTexts.add(text);
    return true;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> release() async {
    initialized = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PhoneCallService Tests', () {
    test('Initial state is idle and inactive', () {
      final service = PhoneCallService(autoStart: false);
      expect(service.status, equals(PhoneCallStatus.idle));
      expect(service.isCallActive, isFalse);
      expect(service.isRinging, isFalse);
    });

    test('Simulating ringing and offhook sets call active and notifies listeners', () {
      final service = PhoneCallService(autoStart: false);
      int notifyCount = 0;
      service.addListener(() => notifyCount++);

      service.simulateCallState(PhoneCallStatus.ringing);
      expect(service.status, equals(PhoneCallStatus.ringing));
      expect(service.isCallActive, isTrue);
      expect(service.isRinging, isTrue);
      expect(notifyCount, equals(1));

      service.simulateCallState(PhoneCallStatus.offhook);
      expect(service.status, equals(PhoneCallStatus.offhook));
      expect(service.isCallActive, isTrue);
      expect(service.isRinging, isFalse);
      expect(notifyCount, equals(2));

      service.simulateCallState(PhoneCallStatus.idle);
      expect(service.status, equals(PhoneCallStatus.idle));
      expect(service.isCallActive, isFalse);
      expect(notifyCount, equals(3));
    });

    test('Critical alerts are queued during call and flushed on call end', () {
      final service = PhoneCallService(autoStart: false);
      service.simulateCallState(PhoneCallStatus.offhook);

      service.queuePostCallAlert('SOS from Rahul');
      service.queuePostCallAlert('Crash detected');
      expect(service.pendingPostCallAlerts.length, equals(2));

      final flushed = service.flushPostCallAlerts();
      expect(flushed, equals(['SOS from Rahul', 'Crash detected']));
      expect(service.pendingPostCallAlerts, isEmpty);
    });
  });

  group('VoiceService & Phone Call Interruption Tests', () {
    test('Voice guidance remains enabled by default during active call, with critical alerts spoken and queued', () async {
      final settings = SettingsService();
      final engine = FakeVoiceEngine();
      final voice = VoiceService(settings, engine: engine);
      final phone = PhoneCallService(autoStart: false);
      voice.attachPhoneCallService(phone);

      // Normal speech outside call
      final ok = await voice.speak('Turn right in 200m');
      expect(ok, isTrue);
      expect(engine.spokenTexts, contains('Turn right in 200m'));

      // Call starts
      phone.simulateCallState(PhoneCallStatus.offhook);

      // Voice guidance remains enabled by default during call
      final inCallGuidance = await voice.speak('Turn left onto Outer Ring Rd');
      expect(inCallGuidance, isTrue);
      expect(engine.spokenTexts, contains('Turn left onto Outer Ring Rd'));

      // Critical emergency is spoken immediately AND queued as post-call safety fallback
      final crit = await voice.speak('Rahul SOS Emergency', priority: VoicePriority.critical);
      expect(crit, isTrue);
      expect(phone.pendingPostCallAlerts, contains('Rahul SOS Emergency'));
      expect(engine.spokenTexts, contains('Rahul SOS Emergency'));

      // Call ends -> post-call critical alert replay
      phone.simulateCallState(PhoneCallStatus.idle);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(engine.spokenTexts.any((t) => t.contains('Rahul SOS Emergency')), isTrue);
    });

    test('Spoken alerts off silences ordinary voice but NEVER silences critical emergencies', () async {
      final settings = SettingsService();
      final engine = FakeVoiceEngine();
      final voice = VoiceService(settings, engine: engine);
      final phone = PhoneCallService(autoStart: false);
      voice.attachPhoneCallService(phone);

      // Rider turns spoken alerts off (the one voice switch in Settings)
      await settings.setVoiceWarnings(false);

      // Call active
      phone.simulateCallState(PhoneCallStatus.offhook);

      // Ordinary navigation is suppressed
      final nav = await voice.speak('Turn left onto Highway', priority: VoicePriority.warning);
      expect(nav, isFalse);

      // Critical emergency alert ALWAYS bypasses manual voice disable
      final crit = await voice.speak('CRITICAL: Crash detected', priority: VoicePriority.critical);
      expect(crit, isTrue);
      expect(engine.spokenTexts, contains('CRITICAL: Crash detected'));
    });
  });

  group('IntercomService & Phone Call Mute Tests', () {
    test('Intercom transmission is blocked while phone call is active', () async {
      final rt = RealtimeService();
      final intercom = IntercomService(rt);

      intercom.setPhoneCallActive(true);
      expect(intercom.isPausedByPhoneCall, isTrue);

      final canBegin = await intercom.beginTransmission();
      expect(canBegin, isFalse);

      intercom.setPhoneCallActive(false);
      expect(intercom.isPausedByPhoneCall, isFalse);
    });
  });

  group('On-Route Fuel Ahead Filtering Tests', () {
    test('Strictly excludes backward stations (7km behind) and includes forward on-route stations (1.3km ahead)', () {
      final client = MockClient((r) async => http.Response('{}', 200));
      final api = ApiClient(httpClient: client);
      final essentials = RouteEssentialsService(api);

      // Route heading North along longitude 78.378:
      // Start: 17.4000, 78.3780
      // Rider currently at: 17.4329, 78.3780 (approx progressM = 3650m)
      // Destination: 17.5000, 78.3780 (total ~11km)
      final routeLine = <(double, double)>[
        (17.4000, 78.3780),
        (17.4300, 78.3780),
        (17.4329, 78.3780), // Current rider location (~3650m along)
        (17.4440, 78.3780), // 1.3 km ahead along route (~4950m along)
        (17.5000, 78.3780),
      ];

      final currentAlongM = GeoMath.alongRoute(17.4329, 78.3780, routeLine)!.along;
      essentials.progressM = currentAlongM;

      // 1. Station 1.3 km AHEAD on route (Indian Oil)
      final stationAhead = RouteEssential(
        placeId: 'st_ahead',
        visitId: 'v_ahead',
        name: 'Indian Oil Petrol Bunk',
        category: 'FUEL',
        source: 'OSM',
        lat: 17.4440,
        lng: 78.3781, // 10m off route
        routePositionM: 4950,
        entryM: 4900,
        exitM: 5000,
        accessDistanceM: 10,
        detourDistanceM: 20,
        detourDurationS: 10,
      );

      // 2. Station 7 km BACKWARDS (behind rider at start of trip)
      final stationBehind = RouteEssential(
        placeId: 'st_behind',
        visitId: 'v_behind',
        name: 'Backwards Petrol Pump',
        category: 'FUEL',
        source: 'OSM',
        lat: 17.3700,
        lng: 78.3780, // Far behind rider's start
        routePositionM: 0,
        entryM: 0,
        exitM: 0,
        accessDistanceM: 7000,
        detourDistanceM: 0,
        detourDurationS: 0,
      );

      // 3. Station 3 km OFF-ROUTE on a perpendicular highway (> 2km off route)
      final stationOffRoute = RouteEssential(
        placeId: 'st_off',
        visitId: 'v_off',
        name: 'Off Route Pump',
        category: 'FUEL',
        source: 'OSM',
        lat: 17.4440,
        lng: 78.4300, // ~5.5 km lateral distance
        routePositionM: 4950,
        entryM: 4900,
        exitM: 5000,
        accessDistanceM: 5500,
        detourDistanceM: 11000,
        detourDurationS: 600,
      );

      essentials.nearbyFuelStations = [stationBehind, stationAhead, stationOffRoute];
      essentials.setRiderTelemetry(
        routeLine: routeLine,
        headingDeg: 0, // heading North
        lat: 17.4329,
        lng: 78.3780,
      );

      final aheadList = essentials.onRouteFuelAhead;

      // Must find ONLY the station ahead on route!
      expect(aheadList.length, equals(1));
      expect(aheadList.first.name, equals('Indian Oil Petrol Bunk'));
      expect(aheadList.any((s) => s.name == 'Backwards Petrol Pump'), isFalse);
      expect(aheadList.any((s) => s.name == 'Off Route Pump'), isFalse);
    });
  });

  group('RouteGuide Personal Fuel Detour Tests', () {
    test('addPersonalFuelStop creates personal route without modifying group convoy plan', () async {
      final me = RiderModel(
        userId: 'user_1',
        name: 'Santhosh',
        lat: 17.4329,
        lng: 78.3780,
        lastSeenEpochMs: 1000,
      );

      final groupRoute = RouteModel(
        distanceM: 10000,
        durationS: 600,
        polyline: GeoMath.encodePolyline([(17.4329, 78.3780), (17.5000, 78.3780)]),
      );

      final convoy = ConvoyModel(
        groupId: 'grp_1',
        name: 'Hyderabad Riders',
        joinCode: 'HYD01',
        createdByUserId: 'lead_1',
        createdByUserName: 'Lead',
        createdAtEpochMs: 1000,
        route: groupRoute,
        destinationLat: 17.5000,
        destinationLng: 78.3780,
        riders: {'user_1': me},
      );

      final personalRoute = RouteModel(
        distanceM: 10300,
        durationS: 650,
        polyline: GeoMath.encodePolyline([(17.4329, 78.3780), (17.4440, 78.3780), (17.5000, 78.3780)]),
      );

      final guide = RouteGuide(fetchRoute: (wp) async => personalRoute);
      guide.setConvoy(convoy, 'user_1');
      guide.onFix(lat: 17.4329, lng: 78.3780, speedKmh: 45, nowMs: DateTime.now().millisecondsSinceEpoch, online: true, lowData: false);

      expect(guide.hasPersonalRoute, isFalse);
      expect(guide.activeRoute?.polyline, equals(groupRoute.polyline));

      // Add hands-free personal fuel detour stop
      final ok = await guide.addPersonalFuelStop(
        lat: 17.4440,
        lng: 78.3780,
        name: 'Indian Oil 1.3km ahead',
      );

      expect(ok, isTrue);
      expect(guide.hasPersonalRoute, isTrue);
      expect(guide.activeRoute?.polyline, equals(personalRoute.polyline));
      expect(guide.personalFuelStop?.name, equals('Indian Oil 1.3km ahead'));

      // Group plan remains untouched
      expect(convoy.route?.polyline, equals(groupRoute.polyline));

      // Clear personal fuel stop when done refueling
      guide.clearPersonalFuelStop();
      expect(guide.hasPersonalRoute, isFalse);
      expect(guide.personalFuelStop, isNull);
    });
  });
}
