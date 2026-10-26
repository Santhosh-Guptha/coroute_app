import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/emergency_roster.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/pending_sos.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/services/accel_source.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/safety_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/sms_sender.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/domain/route/route_guide.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/tracking/dead_reckoning_engine.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';
import 'package:coroute_app/presentation/rider/widgets/minimal_cockpit_overlay.dart';

class FakeAccelSource implements AccelSource {
  final StreamController<AccelBucket> controller = StreamController<AccelBucket>.broadcast();

  @override
  Stream<AccelBucket> buckets({int samplingUs = 20000, int maxLatencyUs = 1000000}) => controller.stream;

  void emit(AccelBucket bucket) => controller.add(bucket);
  void dispose() => controller.close();
}

class FakeSmsSender implements SmsSender {
  final List<(String, String)> sent = [];
  SmsCapability cap = const SmsCapability(hasTelephony: true, permission: true, simReady: true);
  SmsStatus status = SmsStatus.sent;

  @override
  Future<SmsCapability> capability() async => cap;

  @override
  Future<SmsStatus> send(String to, String body) async {
    sent.add((to, body));
    return status;
  }
}

class FakeSafetyPort extends ChangeNotifier implements SafetyPort, SafetySourcePort, SafetyCheckInPort {
  FakeSafetyPort(this.clock);
  final int Function() clock;

  final StreamController<TrackPoint> fixes = StreamController<TrackPoint>.broadcast();
  ConvoyModel? convoy;
  final List<Map<String, Object?>> raised = [];
  final List<CheckInResult> checkIns = [];

  @override
  Stream<TrackPoint> get myFixes => fixes.stream;
  @override
  ConvoyModel? get activeConvoy => convoy;
  @override
  String? get myUserId => 'user_me';
  @override
  String get myName => 'Rider Me';
  @override
  String? get myPhone => '+91 98765 43210';
  @override
  bool get rideActive => true;
  @override
  bool get hasOpenSos => false;
  @override
  PendingSos? get pendingSos => null;
  @override
  EmergencyRoster? get emergencyRoster => null;
  @override
  RosterContact? get myEmergencyContact => null;
  @override
  String? get myBloodGroup => 'O+';

  @override
  SosDelivery raiseSos({
    required String type,
    required double lat,
    required double lng,
    bool auto = false,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAtMs,
  }) {
    raised.add({
      'type': type,
      'lat': lat,
      'lng': lng,
      'auto': auto,
      'speedBeforeKmh': speedBeforeKmh,
      'impactG': impactG,
      'occurredAtMs': occurredAtMs,
    });
    return SosDelivery.sent;
  }

  @override
  SosDelivery raiseSosFrom(
    EmergencySource source, {
    required String type,
    required double lat,
    required double lng,
    bool auto = false,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAtMs,
    Map<String, dynamic>? biometrics,
    String? traumaLevel,
  }) {
    raiseSos(
      type: type,
      lat: lat,
      lng: lng,
      auto: auto,
      speedBeforeKmh: speedBeforeKmh,
      impactG: impactG,
      occurredAtMs: occurredAtMs,
    );
    return SosDelivery.sent;
  }

  @override
  bool sendCheckIn(CheckInResult result, {double? awayM}) {
    checkIns.add(result);
    return true;
  }

  @override
  bool sendCheckInWith(CheckInResult result, {double? awayM, CheckInContext? context}) {
    return sendCheckIn(result, awayM: awayM);
  }

  @override
  void dispose() {
    fixes.close();
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Atal Tunnel Rohtang Coordinates
  const double atalEntryLat = 32.3639;
  const double atalEntryLng = 77.1462;
  const double atalExitLat = 32.4411;
  const double atalExitLng = 77.1594;

  final routePolyline = [
    (atalEntryLat, atalEntryLng),
    (32.3800, 77.1500),
    (32.4000, 77.1550),
    (32.4200, 77.1580),
    (atalExitLat, atalExitLng),
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('FEAT-09: Tunnel Entry Detection Tests', () {
    test('Initiates coasting when accuracy degrades > 50m while moving near portal', () {
      final shouldCoast = DeadReckoningEngine.shouldInitiateCoasting(
        fixAgeSec: 1.0,
        accuracyM: 85.0, // > 50m
        lat: atalEntryLat,
        lng: atalEntryLng,
        speedKmh: 45.0, // > 15 km/h
        hasActiveRoute: true,
      );
      expect(shouldCoast, isTrue);
    });

    test('Initiates coasting when no GPS fix is received for > 3s while moving on active route', () {
      final shouldCoast = DeadReckoningEngine.shouldInitiateCoasting(
        fixAgeSec: 3.5, // > 3.0s
        accuracyM: 10.0,
        lat: 32.3800,
        lng: 77.1500,
        speedKmh: 55.0, // > 15 km/h
        hasActiveRoute: true,
      );
      expect(shouldCoast, isTrue);
    });

    test('Does not initiate coasting when GPS fix is accurate and fresh', () {
      final shouldCoast = DeadReckoningEngine.shouldInitiateCoasting(
        fixAgeSec: 1.0,
        accuracyM: 8.0,
        lat: atalEntryLat,
        lng: atalEntryLng,
        speedKmh: 50.0,
        hasActiveRoute: true,
      );
      expect(shouldCoast, isFalse);
    });

    test('Does not initiate coasting when stationary (speed <= 15 km/h)', () {
      final shouldCoast = DeadReckoningEngine.shouldInitiateCoasting(
        fixAgeSec: 4.0,
        accuracyM: 60.0,
        lat: atalEntryLat,
        lng: atalEntryLng,
        speedKmh: 8.0, // Low speed / stopped
        hasActiveRoute: true,
      );
      expect(shouldCoast, isFalse);
    });
  });

  group('FEAT-09: Along-Route IMU Projection Tests', () {
    test('Projects coordinates along route polyline with speed decay v(t)', () {
      final engine = DeadReckoningEngine(plannedRoute: routePolyline);
      const startMs = 1700000000000;

      engine.startCoasting(
        lat: atalEntryLat,
        lng: atalEntryLng,
        speedKmh: 60.0,
        heading: 10.0,
        timestampMs: startMs,
      );

      expect(engine.isCoasting, isTrue);

      // Compute projection at 30 seconds
      final fix30 = engine.computeFix(startMs + 30000);
      expect(fix30.isCoasting, isTrue);
      expect(fix30.confidence, equals(TrackingConfidence.tunnelCoasting));
      expect(fix30.speedKmh, lessThanOrEqualTo(60.0));
      expect(fix30.speedKmh, greaterThan(50.0)); // realistic cruising
      expect(fix30.alongRouteM, greaterThan(0.0));
      expect(fix30.lat, greaterThan(atalEntryLat)); // progressed northward into tunnel

      // Compute projection at 90 seconds
      final fix90 = engine.computeFix(startMs + 90000);
      expect(fix90.alongRouteM, greaterThan(fix30.alongRouteM));
      expect(fix90.speedKmh, lessThan(fix30.speedKmh));
      expect(fix90.statusDescription, contains('Tunnel Coasting (90s)'));
    });

    test('Adjusts deceleration on heavy braking event (peakG >= 1.8)', () {
      final engine = DeadReckoningEngine(plannedRoute: routePolyline);
      const startMs = 1700000000000;

      engine.startCoasting(
        lat: atalEntryLat,
        lng: atalEntryLng,
        speedKmh: 60.0,
        heading: 10.0,
        timestampMs: startMs,
      );

      // Normal fix at 5s
      final normalFix = engine.computeFix(startMs + 5000);

      // Ingest heavy braking event: peakG 2.2
      engine.checkAccelerometer(const AccelBucket(
        tMs: startMs + 6000,
        peakG: 2.2,
        meanG: 1.1,
        stdG: 0.25,
      ));

      final brakedFix = engine.computeFix(startMs + 7000);
      // Braking adjusted the entry speed downwards
      expect(brakedFix.speedKmh, lessThan(normalFix.speedKmh * 0.95));
    });
  });

  group('FEAT-09: False Alarm Suppression in SafetyService Tests', () {
    test('Suppresses Rider Stopped and Rider Separated alarms while coasting', () {
      final fakePort = FakeSafetyPort(() => 1700000000000);
      final fakeSettings = SettingsService();
      final fakeAccel = FakeAccelSource();
      final fakeSms = FakeSmsSender();

      final coastingRider = RiderModel(
        userId: 'user_me',
        name: 'Rider Me',
        lat: atalEntryLat,
        lng: atalEntryLng,
        speedKmh: 55.0,
        trackingConfidence: TrackingConfidence.tunnelCoasting,
        lastSeenEpochMs: 1700000000000,
      );

      fakePort.convoy = ConvoyModel(
        groupId: 'g_atal',
        name: 'Manali-Leh Convoy',
        joinCode: 'ATAL1',
        createdByUserId: 'user_lead',
        createdByUserName: 'Lead Rider',
        createdAtEpochMs: 1700000000000,
        riders: {'user_me': coastingRider},
      );

      final safety = SafetyService.forTest(
        fakePort,
        fakeSettings,
        accel: fakeAccel,
        sms: fakeSms,
        clock: () => 1700000000000,
      );

      // Check method suppression
      expect(safety.shouldSuppressFalseAlarm('STOPPED'), isTrue);
      expect(safety.shouldSuppressFalseAlarm('RIDER_STOPPED'), isTrue);
      expect(safety.shouldSuppressFalseAlarm('SEPARATED'), isTrue);
      expect(safety.shouldSuppressFalseAlarm('RIDER_SEPARATED'), isTrue);
      // SOS is never suppressed
      expect(safety.shouldSuppressFalseAlarm('SOS'), isFalse);

      // awayFromGroup returns null during tunnel coasting
      final away = SafetyService.awayFromGroup(fakePort.convoy!, 'user_me', 1700000000000);
      expect(away, isNull);

      safety.dispose();
      fakeAccel.dispose();
      fakePort.dispose();
    });

    test('RouteGuide suppresses off-route alarms when isTunnelCoasting is true', () {
      final guide = RouteGuide(fetchRoute: (waypoints) async => null);
      final convoy = ConvoyModel(
        groupId: 'g_atal',
        name: 'Atal Ride',
        joinCode: 'ATAL2',
        createdByUserId: 'user_lead',
        createdByUserName: 'Lead Rider',
        createdAtEpochMs: 1700000000000,
        routeBreadcrumbs: [for (final pt in routePolyline) {'lat': pt.$1, 'lng': pt.$2}],
        destinationLat: atalExitLat,
        destinationLng: atalExitLng,
      );

      guide.setConvoy(convoy, 'user_me');

      // Rider enters tunnel and has isTunnelCoasting: true
      guide.onFix(
        lat: atalEntryLat,
        lng: atalEntryLng,
        speedKmh: 60.0,
        nowMs: 1700000000000,
        online: false,
        lowData: false,
        isTunnelCoasting: true,
      );

      // Guide does not flag off route even without online connection
      expect(guide.hasPersonalRoute, isFalse);
      guide.dispose();
    });
  });

  group('FEAT-09: Crash-Stop Detection Inside Tunnel Tests', () {
    test('Detects severe tunnel impact (> 4.0G) and freezes coordinates at crash site', () {
      final engine = DeadReckoningEngine(plannedRoute: routePolyline);
      const startMs = 1700000000000;

      engine.startCoasting(
        lat: atalEntryLat,
        lng: atalEntryLng,
        speedKmh: 65.0,
        heading: 10.0,
        timestampMs: startMs,
      );

      // Progress for 20 seconds inside tunnel
      final fix20 = engine.computeFix(startMs + 20000);
      expect(fix20.speedKmh, greaterThan(50.0));
      expect(engine.isVehicularMoving(startMs + 20000), isTrue);

      // Severe crash impact occurs inside tunnel
      engine.checkAccelerometer(const AccelBucket(
        tMs: startMs + 22000,
        peakG: 4.6, // severe impact
        meanG: 1.0,
        stdG: 0.03, // bike stopped / resting on road
      ));

      expect(engine.crashDetectedInTunnel, isTrue);
      expect(engine.isVehicularMoving(startMs + 25000), isFalse);

      final crashFix = engine.computeFix(startMs + 25000);
      expect(crashFix.isCrashStop, isTrue);
      expect(crashFix.speedKmh, equals(0.0));
      expect(crashFix.lat, equals(fix20.lat));
      expect(crashFix.lng, equals(fix20.lng));
      expect(crashFix.confidence, equals(TrackingConfidence.degradedMultipath));
      expect(crashFix.statusDescription, contains('Impact Stop Detected'));
    });
  });

  group('FEAT-09: Smooth GPS Re-Convergence Upon Tunnel Exit Tests', () {
    test('Smoothly interpolates from coasted position to recovered GPS fix over 4s without jumps', () {
      final engine = DeadReckoningEngine(plannedRoute: routePolyline);
      const startMs = 1700000000000;

      engine.startCoasting(
        lat: atalEntryLat,
        lng: atalEntryLng,
        speedKmh: 60.0,
        heading: 10.0,
        timestampMs: startMs,
      );

      // Coast for 120s
      final coastedFix = engine.computeFix(startMs + 120000);
      final coastedLat = coastedFix.lat;
      final coastedLng = coastedFix.lng;

      // GPS re-acquires at tunnel exit
      const gpsLat = atalExitLat;
      const gpsLng = atalExitLng;
      const convStartMs = startMs + 120000;

      engine.startConvergence(
        gpsLat: gpsLat,
        gpsLng: gpsLng,
        gpsSpeedKmh: 58.0,
        gpsHeading: 12.0,
        nowMs: convStartMs,
        durationMs: 4000,
      );

      expect(engine.isCoasting, isFalse);
      expect(engine.isConverging, isTrue);

      // At 2 seconds (50% blend)
      final midPoint = engine.computeConvergence(convStartMs + 2000);
      expect(midPoint.isCompleted, isFalse);
      expect(midPoint.lat, closeTo((coastedLat + gpsLat) / 2.0, 0.001));
      expect(midPoint.lng, closeTo((coastedLng + gpsLng) / 2.0, 0.001));

      // At 4 seconds (100% completed)
      final endPoint = engine.computeConvergence(convStartMs + 4000);
      expect(endPoint.isCompleted, isTrue);
      expect(endPoint.lat, equals(gpsLat));
      expect(endPoint.lng, equals(gpsLng));
      expect(engine.isConverging, isFalse);
    });
  });

  group('FEAT-09: ConvoyService Live Tracking Integration Tests', () {
    late ConvoyService convoyService;
    late FakeAccelSource fakeAccel;
    late ConvoyModel testConvoy;

    setUp(() {
      final client = MockClient((request) async => http.Response('{}', 200));
      final api = ApiClient(httpClient: client);
      fakeAccel = FakeAccelSource();

      convoyService = ConvoyService(
        api,
        RealtimeService(),
        TripStorageService(api),
        accel: fakeAccel,
      );
      convoyService.setMyUserIdForTesting('user_me');

      testConvoy = ConvoyModel(
        groupId: 'g_atal',
        name: 'Atal Expedition',
        joinCode: 'ATAL3',
        createdByUserId: 'user_lead',
        createdByUserName: 'Lead Rider',
        createdAtEpochMs: 1700000000000,
        routeBreadcrumbs: [for (final pt in routePolyline) {'lat': pt.$1, 'lng': pt.$2}],
        riders: {
          'user_me': RiderModel(
            userId: 'user_me',
            name: 'Rider Me',
            lat: atalEntryLat,
            lng: atalEntryLng,
            speedKmh: 60.0,
            heading: 10.0,
            lastSeenEpochMs: 1700000000000,
          ),
        },
      );
      convoyService.setActiveConvoyForTesting(testConvoy);
    });

    tearDown(() {
      convoyService.dispose();
      fakeAccel.dispose();
    });

    test('ConvoyService initiates coasting and emits synthetic positions along route', () async {
      final fixEmitted = Completer<TrackPoint>();
      final sub = convoyService.myFixes.listen((fix) {
        if (!fixEmitted.isCompleted) fixEmitted.complete(fix);
      });

      // Trigger dead-reckoning coasting
      convoyService.triggerCoasting(
        lat: atalEntryLat,
        lng: atalEntryLng,
        speedKmh: 65.0,
        heading: 10.0,
        timestampMs: 1700000000000,
      );

      expect(convoyService.isTunnelCoasting, isTrue);
      final myRider = convoyService.activeConvoy?.riders['user_me'];
      expect(myRider?.isTunnelCoasting, isTrue);
      expect(myRider?.isCoasting, isTrue);
      expect(myRider?.trackingConfidence, equals(TrackingConfidence.tunnelCoasting));

      // Advance dead reckoning tick by 10 seconds
      convoyService.tickDeadReckoning(1700000010000);

      final coastedRider = convoyService.activeConvoy?.riders['user_me'];
      expect(coastedRider?.lat, greaterThan(atalEntryLat));
      expect(coastedRider?.stoppedSince, equals(0));

      final fix = await fixEmitted.future;
      expect(fix.speedKmh, greaterThan(50.0));
      await sub.cancel();
    });

    test('ConvoyService smoothly converges to recovered GPS fix and exits coasting mode', () {
      convoyService.triggerCoasting(
        lat: atalEntryLat,
        lng: atalEntryLng,
        speedKmh: 60.0,
        heading: 10.0,
        timestampMs: 1700000000000,
      );

      expect(convoyService.isTunnelCoasting, isTrue);

      // Tunnel exit: GPS fix re-acquired
      convoyService.triggerConvergence(
        gpsLat: atalExitLat,
        gpsLng: atalExitLng,
        speedKmh: 55.0,
        heading: 15.0,
        nowMs: 1700000010000,
      );

      expect(convoyService.isTunnelCoasting, isFalse);
      final convergingRider = convoyService.activeConvoy?.riders['user_me'];
      expect(convergingRider?.trackingConfidence, equals(TrackingConfidence.gpsFix));
    });
  });

  group('FEAT-09: Cockpit HUD Integration Widget Tests', () {
    testWidgets('MinimalCockpitTopBar displays Tunnel Mode banner when coasting', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MinimalCockpitTopBar(
              title: 'Atal Tunnel (Rohtang)',
              connection: null,
              gps: GpsState.accurate,
              isTunnelCoasting: true,
              speedKmh: 58.0,
            ),
          ),
        ),
      );

      expect(find.textContaining('Tunnel Mode'), findsOneWidget);
    });
  });
}
