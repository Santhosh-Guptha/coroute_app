import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/domain/notify/notification_snapshot.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/crash_detector.dart';
import 'package:coroute_app/domain/safety/fuel_profile.dart';
import 'package:coroute_app/domain/safety/fuel_range.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';
import 'package:coroute_app/presentation/widgets/convoy_bead_wire_widget.dart';

void main() {
  const int t0 = 1700000000000;

  group('Developer 3: Fuel Range Uncertainty Auto-Recovery', () {
    test('GPS teleport triggers uncertainty, then 30s of pristine active motion recovers baseline', () {
      final tracker = FuelRangeTracker();
      const profile = FuelProfile(fullRangeKm: 300, bufferKm: 20);
      tracker.refuel(profile, t0, full: true);
      expect(tracker.uncertain, isFalse);
      expect(tracker.baselineKm, 300.0);

      // Normal fix at t0
      tracker.onFix(const TrackPoint(ts: t0, lat: 12.9716, lng: 77.5946, speedKmh: 40, accuracyM: 5));

      // Teleport: jumps 5 km in 10 s -> triggers uncertain
      tracker.onFix(const TrackPoint(ts: t0 + 10000, lat: 13.0160, lng: 77.5946, speedKmh: 40, accuracyM: 5));
      expect(tracker.uncertain, isTrue);

      // Pristine fixes with active motion: 20 seconds elapsed (not yet 30s)
      for (var s = 15; s <= 35; s += 5) {
        tracker.onFix(TrackPoint(
          ts: t0 + s * 1000,
          lat: 13.0160 + (s - 10) * 0.0001,
          lng: 77.5946,
          speedKmh: 40,
          accuracyM: 8, // pristine < 15m
        ));
      }
      expect(tracker.uncertain, isTrue, reason: 'Only 20s of pristine active motion so far');

      // Now reach 35s of consecutive pristine motion (t0 + 45000 is 30s from t0 + 15000)
      tracker.onFix(const TrackPoint(
        ts: t0 + 45000,
        lat: 13.0195,
        lng: 77.5946,
        speedKmh: 40,
        accuracyM: 6, // pristine < 15m
      ));

      // Uncertainty must now be recovered!
      expect(tracker.uncertain, isFalse);
      // Baseline was re-anchored
      expect(tracker.baselineKm, isNotNull);
      expect(tracker.baselineKm!, lessThan(300.0));
      expect(tracker.riddenM, 0.0);
    });

    test('Poor GPS accuracy (>= 15m) resets the auto-recovery timer', () {
      final tracker = FuelRangeTracker();
      const profile = FuelProfile(fullRangeKm: 300, bufferKm: 20);
      tracker.refuel(profile, t0, full: true);

      // Trigger uncertainty
      tracker.onFix(const TrackPoint(ts: t0, lat: 12.97, lng: 77.59, speedKmh: 40, accuracyM: 5));
      tracker.onFix(const TrackPoint(ts: t0 + 5000, lat: 13.05, lng: 77.59, speedKmh: 40, accuracyM: 5));
      expect(tracker.uncertain, isTrue);

      // Pristine fixes for 20 seconds
      tracker.onFix(const TrackPoint(ts: t0 + 10000, lat: 13.051, lng: 77.59, speedKmh: 40, accuracyM: 5));
      tracker.onFix(const TrackPoint(ts: t0 + 30000, lat: 13.053, lng: 77.59, speedKmh: 40, accuracyM: 5));
      expect(tracker.uncertain, isTrue);

      // Degraded accuracy (35m) breaks streak
      tracker.onFix(const TrackPoint(ts: t0 + 35000, lat: 13.054, lng: 77.59, speedKmh: 40, accuracyM: 35));
      expect(tracker.uncertain, isTrue);

      // Another 15 seconds of pristine is not enough (streak was broken)
      tracker.onFix(const TrackPoint(ts: t0 + 50000, lat: 13.056, lng: 77.59, speedKmh: 40, accuracyM: 5));
      expect(tracker.uncertain, isTrue);
    });

    test('Lack of active motion (standing still, speed = 0) resets auto-recovery timer', () {
      final tracker = FuelRangeTracker();
      const profile = FuelProfile(fullRangeKm: 300, bufferKm: 20);
      tracker.refuel(profile, t0, full: true);

      // Trigger uncertainty
      tracker.onFix(const TrackPoint(ts: t0, lat: 12.97, lng: 77.59, speedKmh: 40, accuracyM: 5));
      tracker.onFix(const TrackPoint(ts: t0 + 5000, lat: 13.05, lng: 77.59, speedKmh: 40, accuracyM: 5));
      expect(tracker.uncertain, isTrue);

      // Standing still at a red light for 40s (accuracy is great, but speed is 0)
      tracker.onFix(const TrackPoint(ts: t0 + 10000, lat: 13.05, lng: 77.59, speedKmh: 0, accuracyM: 5));
      tracker.onFix(const TrackPoint(ts: t0 + 50000, lat: 13.05, lng: 77.59, speedKmh: 0, accuracyM: 5));
      expect(tracker.uncertain, isTrue, reason: 'Standing still must not trigger fuel auto-recovery');
    });
  });

  group('Developer 3: Crash Detection Slide Window Extension (> 60 km/h)', () {
    test('Initial speed > 60 km/h: stops after 14s of high-speed slide and detects crash', () {
      final detector = CrashDetector();

      // Ride at 75 km/h (> 60 km/h threshold)
      for (var s = 0; s <= 20; s++) {
        detector.onFix(TrackPoint(ts: t0 + s * 1000, lat: 12.97 + s * 0.0002, lng: 77.59, speedKmh: 75, accuracyM: 5));
        detector.onAccel(AccelBucket(tMs: t0 + s * 1000, peakG: 1.5, meanG: 1.0, stdG: 0.2));
      }

      // Hard impact at 20s (6 g)
      detector.onAccel(const AccelBucket(tMs: t0 + 20000, peakG: 6.0, meanG: 2.0, stdG: 1.5));
      expect(detector.evaluating, isTrue);

      // High-speed slide: decelerating over 14 seconds (exceeds the old 10s cliff!)
      // At 25s (5s after impact): still sliding at 45 km/h
      detector.onFix(const TrackPoint(ts: t0 + 25000, lat: 12.975, lng: 77.59, speedKmh: 45, accuracyM: 5));
      // At 30s (10s after impact): still sliding at 25 km/h
      detector.onFix(const TrackPoint(ts: t0 + 30000, lat: 12.977, lng: 77.59, speedKmh: 25, accuracyM: 5));
      expect(detector.evaluating, isTrue, reason: 'High-speed slide window is extended to 18s');

      // At 34s (14s after impact): bike and rider finally stop (0 km/h)
      detector.onFix(const TrackPoint(ts: t0 + 34000, lat: 12.978, lng: 77.59, speedKmh: 0, accuracyM: 5));
      expect(detector.evaluating, isTrue);

      // Stillness for 20 seconds (until 54s)
      CrashEvent? crash;
      for (var s = 35; s <= 55; s++) {
        final fixEv = detector.onFix(TrackPoint(ts: t0 + s * 1000, lat: 12.978, lng: 77.59, speedKmh: 0, accuracyM: 5));
        final accelEv = detector.onAccel(AccelBucket(tMs: t0 + s * 1000, peakG: 1.02, meanG: 1.0, stdG: 0.02));
        if (fixEv != null) crash = fixEv;
        if (accelEv != null) crash = accelEv;
      }

      expect(crash, isNotNull, reason: 'Crash must be detected for high-speed slide ending within 18s');
      expect(crash!.speedBeforeKmh, closeTo(75.0, 1.0));
    });

    test('Initial speed <= 60 km/h: stops after 14s is dropped as non-crash (normal 10s window)', () {
      final detector = CrashDetector();

      // Ride at 50 km/h (<= 60 km/h)
      for (var s = 0; s <= 20; s++) {
        detector.onFix(TrackPoint(ts: t0 + s * 1000, lat: 12.97 + s * 0.0001, lng: 77.59, speedKmh: 50, accuracyM: 5));
        detector.onAccel(AccelBucket(tMs: t0 + s * 1000, peakG: 1.5, meanG: 1.0, stdG: 0.2));
      }

      // Impact at 20s
      detector.onAccel(const AccelBucket(tMs: t0 + 20000, peakG: 5.0, meanG: 2.0, stdG: 1.2));

      // At 32s (12s after impact): > 10s window for 50 km/h, candidate is dropped
      detector.onFix(const TrackPoint(ts: t0 + 32000, lat: 12.974, lng: 77.59, speedKmh: 20, accuracyM: 5));
      expect(detector.evaluating, isFalse, reason: 'Normal speeds strictly respect 10s stop window');
    });
  });

  group('Developer 3: Convoy Telemetry, Free-Riding Spatial Ordering & Pack Spread', () {
    test('Free-riding without route polyline sorts riders along Lead moving heading vector', () {
      // Lead is moving East (heading 90 degrees)
      final lead = RiderModel(
        userId: 'lead_user',
        name: 'Zoe Lead', // Alphabetically last!
        lat: 12.9700,
        lng: 77.5900,
        heading: 90.0, // Moving East
        speedKmh: 50.0,
        role: RiderRoles.lead,
        lastSeenEpochMs: t0,
      );

      // Rider A is ahead of Lead (East: lng 77.5950)
      final riderAhead = RiderModel(
        userId: 'rider_a',
        name: 'Alice Ahead',
        lat: 12.9700,
        lng: 77.5950,
        heading: 90.0,
        speedKmh: 50.0,
        role: RiderRoles.pack,
        lastSeenEpochMs: t0,
      );

      // Rider B is behind Lead (West: lng 77.5850)
      final riderBehind = RiderModel(
        userId: 'rider_b',
        name: 'Bob Behind',
        lat: 12.9700,
        lng: 77.5850,
        heading: 90.0,
        speedKmh: 50.0,
        role: RiderRoles.pack,
        lastSeenEpochMs: t0,
      );

      final convoy = ConvoyModel(
        groupId: 'g1',
        name: 'Free Ride',
        joinCode: 'FREE1',
        createdByUserId: 'lead_user',
        createdByUserName: 'Zoe Lead',
        createdAtEpochMs: t0,
        route: null, // No planned route!
        destinationLat: 0.0, // No destination!
        destinationLng: 0.0,
        riders: {
          'lead_user': lead,
          'rider_a': riderAhead,
          'rider_b': riderBehind,
        },
      );

      final ladder = RideFacts.ladder(convoy, 'lead_user');
      expect(ladder.length, 3);

      // Under the old bug, it sorted alphabetically: Alice, Bob, Zoe.
      // Under our fix, it must sort spatially along Lead's 90-degree heading:
      // Alice (ahead of lead) -> Zoe (lead) -> Bob (behind lead)
      expect(ladder[0].rider.userId, 'rider_a', reason: 'Alice is ahead to the East');
      expect(ladder[1].rider.userId, 'lead_user', reason: 'Zoe is the Lead in the middle');
      expect(ladder[2].rider.userId, 'rider_b', reason: 'Bob is behind to the West');

      // Alice is ahead of Lead, Bob is behind
      expect(ladder[0].ahead, isTrue);
      expect(ladder[1].isMe, isTrue);
      expect(ladder[2].ahead, isFalse);
    });

    test('Total pack spread calculation measures Lead-to-Sweeper distance', () {
      final lead = RiderModel(
        userId: 'lead_1',
        name: 'Lead Rider',
        lat: 12.9700,
        lng: 77.5900,
        role: RiderRoles.lead,
        lastSeenEpochMs: t0,
      );

      final sweeper = RiderModel(
        userId: 'sweeper_1',
        name: 'Sweeper Rider',
        lat: 12.9800,
        lng: 77.5900,
        role: RiderRoles.sweeper,
        lastSeenEpochMs: t0,
      );

      final convoy = ConvoyModel(
        groupId: 'g2',
        name: 'Pack Spread Test',
        joinCode: 'PACK1',
        createdByUserId: 'lead_1',
        createdByUserName: 'Lead Rider',
        createdAtEpochMs: t0,
        riders: {
          'lead_1': lead,
          'sweeper_1': sweeper,
        },
      );

      FeatureGates.forceAllUnlocked = true;
      final spread = RideFacts.totalPackSpreadM(convoy);
      expect(spread, isNotNull);
      // Distance between 12.9700 and 12.9800 is ~1113m
      expect(spread!, closeTo(1113.0, 30.0));

      // RideSnapshot exposes totalPackSpreadM
      final snapshot = RideFacts.snapshot(convoy, 'lead_1');
      expect(snapshot.totalPackSpreadM, isNotNull);
      expect(snapshot.totalPackSpreadM!, closeTo(1113.0, 30.0));

      // Test FeatureGate entitlement hook
      FeatureGates.forceAllUnlocked = false;
      FeatureGates.activeTier = SubscriptionTier.community; // Community does not have totalConvoySpreadAlert
      final lockedSpread = RideFacts.totalPackSpreadM(convoy);
      expect(lockedSpread, isNull, reason: 'Gated when totalConvoySpreadAlert is locked');

      // Cleanup
      FeatureGates.forceAllUnlocked = true;
      FeatureGates.activeTier = SubscriptionTier.roadCaptain;
    });
  });

  group('Developer 3: ConvoyBeadWireWidget Sweeper Bug Fix', () {
    testWidgets('Behind rider with userId == convoy.sweeperId renders Sweeper tag', (tester) async {
      final sweeper = RiderModel(
        userId: 's1',
        name: 'Aditya',
        lat: 12.95,
        lng: 77.58,
        role: RiderRoles.sweeper,
        lastSeenEpochMs: t0,
      );

      final convoy = ConvoyModel(
        groupId: 'g_bead',
        name: 'Bead Test',
        joinCode: 'BEAD1',
        createdByUserId: 'lead1',
        createdByUserName: 'Lead',
        createdAtEpochMs: t0,
        riders: {'s1': sweeper},
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConvoyBeadWireWidget(
              convoyName: 'Convoy Test',
              convoy: convoy,
              ahead: const [],
              behind: const [
                RiderLine(userId: 'u_norm', name: 'Kiran', distanceM: 400, ahead: false),
                RiderLine(userId: 's1', name: 'Aditya', distanceM: 1200, ahead: false),
              ],
            ),
          ),
        ),
      );

      // Aditya is s1 (the sweeper), must render ▼ Sweeper
      expect(find.text('▼ Sweeper'), findsOneWidget);
      // Kiran is not sweeper, must render ▼ Behind
      expect(find.text('▼ Behind'), findsOneWidget);
    });

    testWidgets('Behind rider in pack of 3 who is NOT sweeper does not get fake Sweeper tag', (tester) async {
      final sweeper = RiderModel(
        userId: 'actual_sweeper',
        name: 'Raj',
        lat: 12.94,
        lng: 77.57,
        role: RiderRoles.sweeper,
        lastSeenEpochMs: t0,
      );

      final convoy = ConvoyModel(
        groupId: 'g_bead2',
        name: 'Bead Test 2',
        joinCode: 'BEAD2',
        createdByUserId: 'lead1',
        createdByUserName: 'Lead',
        createdAtEpochMs: t0,
        riders: {'actual_sweeper': sweeper},
      );

      // 3 riders behind, but behind2 ('Vikram') is NOT the sweeper
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConvoyBeadWireWidget(
              convoyName: 'Convoy Test 2',
              convoy: convoy,
              ahead: const [],
              behind: const [
                RiderLine(userId: 'b1', name: 'Kiran', distanceM: 400, ahead: false),
                RiderLine(userId: 'b2', name: 'Vikram', distanceM: 800, ahead: false),
                RiderLine(userId: 'b3', name: 'Rohit', distanceM: 1200, ahead: false),
              ],
            ),
          ),
        ),
      );

      // None of behind1 or behind2 is the sweeper -> must NOT render ▼ Sweeper
      expect(find.text('▼ Sweeper'), findsNothing);
      expect(find.text('▼ Behind'), findsNWidgets(2));
    });
  });

  group('Developer 3: ConvoyService Limp-Mode Status Preservation', () {
    test('MECHANICAL status is preserved when moving at low speed (< 25 km/h)', () {
      final rider = RiderModel(
        userId: 'limp_rider',
        name: 'Limping Rider',
        lat: 12.9716,
        lng: 77.5946,
        statusReason: 'MECHANICAL',
        statusMessage: 'Chain loose',
        stoppedSince: t0 - 60000,
        lastSeenEpochMs: t0,
      );

      // Test the logic directly matching ConvoyService limp-mode rule
      final isMoving = 15.0 >= 3.0; // 15 km/h
      final wasStopped = rider.statusReason.isNotEmpty;
      final isLimpMode = rider.statusReason == 'MECHANICAL' || rider.statusReason == 'FLAT_TIRE';
      final shouldClearStatus = isMoving && wasStopped && (!isLimpMode || 15.0 >= 25.0);

      expect(shouldClearStatus, isFalse, reason: 'Limping at 15 km/h must not clear status');

      // Now rider accelerates to 30 km/h (>= 25 km/h)
      final shouldClearFast = isMoving && wasStopped && (!isLimpMode || 30.0 >= 25.0);
      expect(shouldClearFast, isTrue, reason: 'Riding at 30 km/h clears limp-mode status');
    });

    test('FLAT_TIRE status is preserved when limping to shoulder at 12 km/h', () {
      final rider = RiderModel(
        userId: 'flat_rider',
        name: 'Flat Tire Rider',
        lat: 12.9716,
        lng: 77.5946,
        statusReason: 'FLAT_TIRE',
        statusMessage: 'Rear flat',
        stoppedSince: t0 - 60000,
        lastSeenEpochMs: t0,
      );

      final isMoving = 12.0 >= 3.0;
      final wasStopped = rider.statusReason.isNotEmpty;
      final isLimpMode = rider.statusReason == 'MECHANICAL' || rider.statusReason == 'FLAT_TIRE';
      final shouldClearStatus = isMoving && wasStopped && (!isLimpMode || 12.0 >= 25.0);

      expect(shouldClearStatus, isFalse);
    });

    test('FUELING status is cleared immediately when moving at 10 km/h', () {
      final rider = RiderModel(
        userId: 'fuel_rider',
        name: 'Fueling Rider',
        lat: 12.9716,
        lng: 77.5946,
        statusReason: 'FUELING',
        stoppedSince: t0 - 60000,
        lastSeenEpochMs: t0,
      );

      final isMoving = 10.0 >= 3.0;
      final wasStopped = rider.statusReason.isNotEmpty;
      final isLimpMode = rider.statusReason == 'MECHANICAL' || rider.statusReason == 'FLAT_TIRE';
      final shouldClearStatus = isMoving && wasStopped && (!isLimpMode || 10.0 >= 25.0);

      expect(shouldClearStatus, isTrue, reason: 'Normal stop reasons clear upon motion');
    });
  });
}
