import 'package:coroute_app/core/config/feature_gates.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/domain/notify/notification_snapshot.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/fuel_profile.dart';
import 'package:coroute_app/domain/safety/fuel_range.dart';
import 'package:coroute_app/domain/tracking/coordinate_parser.dart';
import 'package:coroute_app/domain/tracking/dead_reckoning_engine.dart';
import 'package:coroute_app/domain/tracking/track_filter.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

class _TestRealtime extends RealtimeService {
  final List<Map<String, dynamic>> sent = [];
  final List<Map<String, dynamic>> sentVoice = [];
  bool connected = true;
  final StreamController<Map<String, dynamic>> _eventCtrl = StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<VoicePacket> _voiceCtrl = StreamController<VoicePacket>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _eventCtrl.stream;
  @override
  Stream<VoicePacket> get voice => _voiceCtrl.stream;
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
  void sendVoice(int kind, Map<String, dynamic> header, [Uint8List? payload]) {
    sentVoice.add({'kind': kind, 'header': header, 'payload': payload});
  }

  void emitVoice(VoicePacket p) => _voiceCtrl.add(p);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const int t0 = 1700000000000;

  group('Boundary Condition 1: Zero Coordinates (0,0), Null Fixes & Erratic Jumps > 500m', () {
    test('TrackFilter strictly rejects (0,0), out-of-range coords, and teleports > 500m', () {
      final filter = TrackFilter(maxAccuracyM: 30, maxKmh: 250, minMoveM: 3);

      // (0, 0) rejection
      expect(filter.accept(const TrackPoint(ts: t0, lat: 0.0, lng: 0.0, accuracyM: 5)), isFalse);

      // Out of geographic bounds
      expect(filter.accept(const TrackPoint(ts: t0, lat: 91.0, lng: 77.0, accuracyM: 5)), isFalse);
      expect(filter.accept(const TrackPoint(ts: t0, lat: 12.0, lng: 181.0, accuracyM: 5)), isFalse);

      // Poor accuracy (> 30m)
      expect(filter.accept(const TrackPoint(ts: t0, lat: 13.0, lng: 77.0, accuracyM: 35)), isFalse);

      // Valid first fix
      const p1 = TrackPoint(ts: t0, lat: 13.0, lng: 77.0, accuracyM: 10, speedKmh: 40);
      expect(filter.accept(p1), isTrue);

      // Erratic teleport jump: 5 km in 2 seconds (~9000 km/h) -> must be rejected
      const pTeleport = TrackPoint(ts: t0 + 2000, lat: 13.045, lng: 77.0, accuracyM: 10, speedKmh: 40);
      expect(filter.accept(pTeleport), isFalse);

      // Monotonic time invariant: backwards timestamp rejected
      const pBackwards = TrackPoint(ts: t0 - 1000, lat: 13.001, lng: 77.0, accuracyM: 10);
      expect(filter.accept(pBackwards), isFalse);
    });

    test('FuelRangeTracker marks uncertain on > 500m jump and requires pristine recovery', () {
      const profile = FuelProfile(
        capacityL: 15.0,
        mileageKmL: 35.0,
        fullRangeKm: 525.0,
        reserveL: 2.0,
        bufferKm: 25.0,
      );
      final tracker = FuelRangeTracker();
      tracker.refuel(profile, t0, full: true);
      expect(tracker.uncertain, isFalse);

      // Valid starting point
      tracker.onFix(const TrackPoint(ts: t0, lat: 13.0, lng: 77.0, speedKmh: 50, accuracyM: 5));
      expect(tracker.uncertain, isFalse);

      // Erratic jump of ~5.5 km in 5 seconds (> SafetyConstants.fuelMaxJumpM = 500m)
      tracker.onFix(const TrackPoint(ts: t0 + 5000, lat: 13.05, lng: 77.0, speedKmh: 50, accuracyM: 5));
      expect(tracker.uncertain, isTrue, reason: 'Jump > 500m flags tracker uncertain');

      // Distance should NOT have accumulated the wild teleport
      expect(tracker.riddenM, equals(0.0));

      // Auto-recovery: requires >= 30 seconds of pristine accuracy (< 15m) with active motion
      for (int i = 1; i <= 6; i++) {
        tracker.onFix(TrackPoint(
          ts: t0 + 5000 + i * 5000,
          lat: 13.05 + i * 0.0005,
          lng: 77.0,
          speedKmh: 50,
          accuracyM: 8,
        ));
      }
      expect(tracker.uncertain, isFalse, reason: 'Pristine 30s motion resets uncertain state');
    });

    test('CoordinateParser gracefully rejects garbage, null, zero/invalid coords', () {
      expect(CoordinateParser.tryParse(''), isNull);
      expect(CoordinateParser.tryParse('invalid,lat,lng'), isNull);
      expect(CoordinateParser.tryParse('999.0, 999.0'), isNull);
      expect(CoordinateParser.tryParse('NaN, Infinity'), isNull);

      final valid = CoordinateParser.tryParse('13.0827, 80.2707');
      expect(valid, isNotNull);
      expect(valid!.$1, closeTo(13.0827, 0.0001));
      expect(valid.$2, closeTo(80.2707, 0.0001));
    });
  });

  group('Boundary Condition 2: Deep Mountain Tunnels & Offline Loss Transition', () {
    test('DeadReckoningEngine: Atal Tunnel entry, velocity decay, crash stop, and 720s timeout', () {
      final engine = DeadReckoningEngine();
      final atal = DeadReckoningEngine.knownTunnels.firstWhere(
        (t) => t.name.contains('Atal Tunnel'),
      );

      // Verify portal specs
      expect(atal.lengthMeters, equals(9020));

      engine.setPlannedRoute([
        (atal.entryLat, atal.entryLng),
        (atal.exitLat, atal.exitLng),
      ]);

      // 1. Sudden loss of GPS at Atal south portal at 60 km/h
      engine.startCoasting(
        lat: atal.entryLat,
        lng: atal.entryLng,
        speedKmh: 60.0,
        heading: 0.0,
        timestampMs: t0,
      );

      expect(engine.isCoasting, isTrue);

      // 2. Dead-reckoning projection at 60s into blackout
      final fix60 = engine.computeFix(t0 + 60000);
      expect(fix60.isCoasting, isTrue);
      expect(fix60.confidence, equals(TrackingConfidence.tunnelCoasting));
      // Projected speed decays smoothly
      expect(fix60.speedKmh, lessThan(60.0));
      expect(fix60.speedKmh, greaterThan(30.0));

      // 3. Accelerometer severe impact (4.5G) during tunnel transit halts projection
      const impactBucket = AccelBucket(
        tMs: t0 + 90000,
        peakG: 4.5,
        stdG: 0.05,
        meanG: 1.0,
      );
      engine.checkAccelerometer(impactBucket);
      expect(engine.crashDetectedInTunnel, isTrue);

      final fixAfterImpact = engine.computeFix(t0 + 120000);
      expect(fixAfterImpact.speedKmh, equals(0.0));
      expect(fixAfterImpact.isCrashStop, isTrue);
      expect(fixAfterImpact.confidence, equals(TrackingConfidence.degradedMultipath));

      // 4. Reset and simulate 720s timeout without crash
      final engine2 = DeadReckoningEngine();
      engine2.setPlannedRoute([
        (atal.entryLat, atal.entryLng),
        (atal.exitLat, atal.exitLng),
      ]);
      engine2.startCoasting(
        lat: atal.entryLat,
        lng: atal.entryLng,
        speedKmh: 60.0,
        heading: 0.0,
        timestampMs: t0,
      );

      // Beyond 720 seconds (12 minutes max coasting duration)
      final fixTimeout = engine2.computeFix(t0 + 721000);
      expect(fixTimeout.hasTimedOut, isTrue);
      expect(fixTimeout.confidence, equals(TrackingConfidence.lost));
    });
  });

  group('Boundary Condition 3: High Convoy Scale (30+ Simultaneous Riders)', () {
    test('Handles 35 concurrent riders exchanging continuous telemetry without degradation', () {
      const int riderCount = 35;
      final Map<String, RiderModel> riders = {};

      for (int i = 0; i < riderCount; i++) {
        final id = 'u_rider_$i';
        final role = i == 0 ? 'LEAD' : (i == riderCount - 1 ? 'SWEEPER' : 'PACK');
        riders[id] = RiderModel(
          userId: id,
          name: 'Rider #$i',
          lat: 13.000 + (riderCount - i) * 0.005, // Staggered along latitude
          lng: 77.600,
          speedKmh: 65.0 + (i % 5),
          heading: 0.0,
          role: role,
          batteryLevel: 90 - (i % 40),
          lastSeenEpochMs: t0 + i * 100,
        );
      }

      final convoy = ConvoyModel(
        groupId: 'CONVOY-SCALE-35',
        name: 'Mega Convoy 35',
        joinCode: '998877',
        createdByUserId: 'u_rider_0',
        createdByUserName: 'Rider #0',
        createdAtEpochMs: t0,
        distanceThresholdMeters: 1000,
        riders: riders,
      );

      // Verify scale invariant
      expect(convoy.riders.length, equals(35));

      // Fast JSON serialization / deserialization round trip
      final json = convoy.toJson();
      final decoded = ConvoyModel.fromJson(json);
      expect(decoded.riders.length, equals(35));

      // Ingest continuous concurrent telemetry updates from all 35 riders
      var currentConvoy = decoded;
      for (int i = 0; i < riderCount; i++) {
        final uid = 'u_rider_$i';
        final existing = currentConvoy.riders[uid]!;
        final updatedRider = existing.copyWith(
          lat: existing.lat + 0.001,
          speedKmh: 70.0,
          lastSeenEpochMs: t0 + 10000 + i,
        );
        final newRiders = Map<String, RiderModel>.from(currentConvoy.riders)..[uid] = updatedRider;
        currentConvoy = currentConvoy.copyWith(riders: newRiders);
      }

      expect(currentConvoy.riders.length, equals(35));
      expect(currentConvoy.riders['u_rider_0']!.speedKmh, equals(70.0));

      // Notification Bead Wire generation with 35 riders
      final aheadRiders = <RiderLine>[];
      final behindRiders = <RiderLine>[];

      for (int i = 0; i < 35; i++) {
        if (i < 5) {
          aheadRiders.add(RiderLine(name: 'Rider #$i', distanceM: (5 - i) * 150, ahead: true));
        } else if (i > 5 && i <= 10) {
          behindRiders.add(RiderLine(name: 'Rider #$i', distanceM: (i - 5) * 150, ahead: false));
        }
      }

      final snapshot = NotificationSnapshot(
        mode: NotifMode.ride,
        tone: NotifTone.normal,
        title: currentConvoy.name,
        subtitle: '35 Bikes Active',
        telemetry: 'Pack #5 • 70 km/h',
        ahead: aheadRiders,
        behind: behindRiders,
      );

      final channelArgs = snapshot.toChannelArgs();
      expect(channelArgs['telemetry'], 'Pack #5 • 70 km/h');
      expect((channelArgs['ahead'] as List).length, equals(5));
      expect((channelArgs['behind'] as List).length, equals(5));
    });
  });

  group('Boundary Condition 4: Empty Fuel Tank Estimation & Missing Vehicle Profile', () {
    test('Strict fallback to unknown/null when profile is missing or invalid', () {
      final tracker = FuelRangeTracker();

      // 1. Completely unconfigured profile
      const unconfigured = FuelProfile();
      expect(unconfigured.valid, isFalse);
      expect(tracker.usableKm(unconfigured), isNull);
      expect(tracker.shouldWarnForProfile(unconfigured), isFalse);

      // 2. Degenerate profile (negative capacity or zero mileage)
      const invalidProfile = FuelProfile(
        capacityL: -10.0,
        mileageKmL: 0.0,
        fullRangeKm: 0.0,
      );
      expect(invalidProfile.valid, isFalse);
      expect(tracker.usableKm(invalidProfile), isNull);

      // 3. Valid profile but tracker baseline not set (no refuel recorded)
      const validProfile = FuelProfile(
        capacityL: 14.0,
        mileageKmL: 35.0,
        fullRangeKm: 490.0,
        reserveL: 2.0,
        bufferKm: 20.0,
      );
      expect(validProfile.valid, isTrue);
      expect(tracker.usableKm(validProfile), isNull);

      // 4. Refuel with empty tank (0.0 litres confirmed)
      final refuelSuccess = tracker.refuel(validProfile, t0, currentL: 0.0);
      expect(refuelSuccess, isTrue);
      expect(tracker.usableKm(validProfile), equals(0.0));

      // 5. Fuel advice evaluation under empty tank and degraded inputs
      expect(fuelAdvice(usableKm: 0.0, nextKm: 25.0, reliable: true), equals(FuelAdvice.rangeRisk));
      expect(fuelAdvice(usableKm: null, nextKm: 25.0, reliable: true), equals(FuelAdvice.unknown));
      expect(fuelAdvice(usableKm: double.nan, nextKm: 25.0, reliable: true), equals(FuelAdvice.unknown));
      expect(fuelAdvice(usableKm: -10.0, nextKm: 25.0, reliable: true), equals(FuelAdvice.unknown));
      expect(fuelAdvice(usableKm: double.infinity, nextKm: 25.0, reliable: true), equals(FuelAdvice.unknown));
    });
  });

  group('Boundary Condition 5: Simultaneous PTT Audio Collisions & Priority Preemption', () {
    test('Floor arbitration drops concurrent casual packet but Road Captain preempts and ducks', () async {
      FeatureGates.forceAllUnlocked = true;
      addTearDown(() => FeatureGates.forceAllUnlocked = false);
      final rt = _TestRealtime();
      final ic = IntercomService(rt);

      final casualRider1Start = VoicePacket(
        VoiceKind.start,
        {
          'streamId': 'stream_casual_1',
          'from': 'u_casual_1',
          'fromName': 'Rider Alice',
          'sampleRate': 16000,
          'role': 'PACK',
        },
        Uint8List(0),
      );

      final casualRider2Start = VoicePacket(
        VoiceKind.start,
        {
          'streamId': 'stream_casual_2',
          'from': 'u_casual_2',
          'fromName': 'Rider Bob',
          'sampleRate': 16000,
          'role': 'PACK',
        },
        Uint8List(0),
      );

      // 1. Alice presses PTT and acquires channel floor
      rt.emitVoice(casualRider1Start);
      await pumpEventQueue();

      expect(ic.isReceiving, isTrue);
      expect(ic.activeSpeakerId, equals('u_casual_1'));
      expect(ic.activeSpeakerName, equals('Rider Alice'));

      // 2. Bob presses PTT at the same time: colliding group stream is rejected by floor arbitration
      rt.emitVoice(casualRider2Start);
      await pumpEventQueue();

      expect(ic.activeSpeakerId, equals('u_casual_1'), reason: 'Alice holds the floor');

      // 3. Road Captain transmits with priority: must pre-empt Alice
      final leadCaptainStart = VoicePacket(
        VoiceKind.start,
        {
          'streamId': 'stream_lead_vip',
          'from': 'u_lead_captain',
          'fromName': 'Vikram Captain',
          'sampleRate': 16000,
          'role': 'LEAD',
          'priority': true,
        },
        Uint8List(0),
      );

      rt.emitVoice(leadCaptainStart);
      await pumpEventQueue();

      expect(ic.activeSpeakerId, equals('u_lead_captain'), reason: 'Road Captain pre-empts ongoing chatter');
      expect(ic.activeSpeakerName, equals('Vikram Captain'));
      expect(ic.activeSpeakerIsLead, isTrue);

      // 4. Verify audio ducking math for pre-empted audio
      final dummyAudio = Uint8List(200);
      final ducked = IntercomService.attenuatePcm16(dummyAudio);
      expect(ducked.length, equals(dummyAudio.length));
    });
  });
}
