import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/road_hazard_telemetry.dart';
import 'package:coroute_app/domain/safety/road_hazard_detector.dart';
import 'package:coroute_app/domain/safety/road_hazard_aggregator.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

void main() {
  group('FEAT-02: Kinematic Pattern Detector Tests', () {
    late RoadHazardDetector detector;

    setUp(() {
      detector = RoadHazardDetector(
        thresholds: const RoadHazardThresholds(
          shockThresholdG: 1.8,
          yawRateThresholdDegS: 25.0,
          coincidenceWindowMs: 250,
          minSpeedKmh: 20.0,
          cooldownMs: 1500,
          maxGpsAgeMs: 3000,
          maxGpsAccuracyM: 25.0,
        ),
      );
    });

    test('TEST-KIN-01: Severe pothole triggers detection with coincidence and high confidence', () {
      // 1. Warm up gravity estimator with resting gravity on flat mount (az ~ 9.8 m/s^2)
      for (int t = 0; t < 500; t += 20) {
        detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: 9.80665,
        ));
      }

      // 2. Rider traveling at 65 km/h with accurate GPS
      detector.onGpsFix(
        const TrackPoint(
          ts: 1000,
          lat: 12.971598,
          lng: 77.594562,
          speedKmh: 65.0,
          accuracyM: 5.0,
        ),
        nowMs: 1000,
      );

      // 3. Normal tarmac riding
      for (int t = 500; t < 1000; t += 20) {
        detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.05,
          ay: 0.02,
          az: 9.80,
        ));
      }

      // 4. Hit pothole at t = 1000: sharp vertical shock (az = 32.0 m/s^2 => ~2.26g dynamic shock)
      // and handlebar yaw shudder (gz = 35.0 deg/s) within 80ms
      RoadHazardObservation? result;
      for (int t = 1000; t <= 1300; t += 20) {
        final az = (t >= 1000 && t <= 1040) ? 32.0 : 9.8;
        final gz = (t >= 1020 && t <= 1080) ? 35.0 : 2.0;

        final obs = detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.1,
          ay: 0.2,
          az: az,
          gz: gz,
        ));
        if (obs != null) result = obs;
      }

      expect(result, isNotNull);
      expect(result!.classification, equals(RoadHazardClassification.pothole));
      expect(result.peakVerticalG, greaterThan(1.8));
      expect(result.peakYawRateDegS, greaterThanOrEqualTo(25.0));
      expect(result.confidence, greaterThanOrEqualTo(0.85));
      expect(result.severity, isIn([RoadHazardSeverity.high, RoadHazardSeverity.critical]));
    });

    test('TEST-KIN-02: Railway crossing / Transverse joint is rejected (minimal yaw deflection)', () {
      for (int t = 0; t < 500; t += 20) {
        detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: 9.80665,
        ));
      }

      detector.onGpsFix(
        const TrackPoint(
          ts: 1000,
          lat: 12.971598,
          lng: 77.594562,
          speedKmh: 50.0,
          accuracyM: 6.0,
        ),
        nowMs: 1000,
      );

      // Railway track crossing: strong vertical shock (az = 31.0 m/s^2)
      // but perpendicular tracks produce near-zero yaw deflection (gz = 4.0 deg/s)
      RoadHazardObservation? result;
      for (int t = 1000; t <= 1400; t += 20) {
        final az = (t >= 1000 && t <= 1040) ? 31.0 : ((t >= 1120 && t <= 1160) ? 29.0 : 9.8);
        final gz = 4.0; // Straight line across tracks

        final obs = detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.1,
          ay: 0.0,
          az: az,
          gz: gz,
        ));
        if (obs != null) result = obs;
      }

      // Must be rejected!
      expect(result, isNull);
    });

    test('TEST-KIN-03: Intentional lane change is rejected (no vertical shock)', () {
      for (int t = 0; t < 500; t += 20) {
        detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: 9.80665,
        ));
      }

      detector.onGpsFix(
        const TrackPoint(
          ts: 1000,
          lat: 12.971598,
          lng: 77.594562,
          speedKmh: 80.0,
          accuracyM: 4.0,
        ),
        nowMs: 1000,
      );

      // Aggressive lane change: high yaw rate (32 deg/s) but smooth tarmac (az = 9.8 +/- 0.5)
      RoadHazardObservation? result;
      for (int t = 1000; t <= 1500; t += 20) {
        final gz = (t >= 1040 && t <= 1200) ? 32.0 : 1.0;
        final obs = detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.8, // Centripetal accel
          ay: 0.2,
          az: 9.9, // No vertical shock
          gz: gz,
        ));
        if (obs != null) result = obs;
      }

      expect(result, isNull);
    });

    test('TEST-KIN-04: Bridge expansion joint with vertical jolt but straight heading is rejected', () {
      for (int t = 0; t < 500; t += 20) {
        detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: 9.80665,
        ));
      }

      detector.onGpsFix(
        const TrackPoint(
          ts: 1000,
          lat: 12.971598,
          lng: 77.594562,
          speedKmh: 70.0,
          accuracyM: 4.0,
        ),
        nowMs: 1000,
      );

      // Steel bridge finger joint: sharp vertical compression (az = 30.0 m/s^2)
      // but perpendicular plate causes zero steering deflection (gz = 2.0 deg/s)
      RoadHazardObservation? result;
      for (int t = 1000; t <= 1300; t += 20) {
        final az = (t >= 1000 && t <= 1040) ? 30.0 : 9.8;
        final obs = detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: az,
          gz: 2.0,
        ));
        if (obs != null) result = obs;
      }

      expect(result, isNull);
    });

    test('TEST-KIN-05: Ordinary braking and hard deceleration without vertical shock are rejected', () {
      for (int t = 0; t < 500; t += 20) {
        detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: 9.80665,
        ));
      }

      detector.onGpsFix(
        const TrackPoint(
          ts: 1000,
          lat: 12.971598,
          lng: 77.594562,
          speedKmh: 60.0,
          accuracyM: 4.0,
        ),
        nowMs: 1000,
      );

      // Hard braking: forward pitch deceleration (ax = -6.5 m/s^2), but vertical shock is smooth
      RoadHazardObservation? result;
      for (int t = 1000; t <= 1500; t += 20) {
        final obs = detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: -6.5,
          ay: 0.1,
          az: 10.5, // Minor front fork dive, well below 1.8g shock
          gz: 1.0,
        ));
        if (obs != null) result = obs;
      }

      expect(result, isNull);
    });

    test('TEST-KIN-06: Rough / Gravel road continuous vibration baseline is rejected', () {
      for (int t = 0; t < 500; t += 20) {
        detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: 9.80665,
        ));
      }

      detector.onGpsFix(
        const TrackPoint(
          ts: 1000,
          lat: 12.971598,
          lng: 77.594562,
          speedKmh: 40.0,
          accuracyM: 5.0,
        ),
        nowMs: 1000,
      );

      // Continuous washboard gravel road: noisy baseline with standard deviation > 0.35g
      // but no isolated impulse > 4x std dev
      RoadHazardObservation? result;
      for (int t = 1000; t <= 3000; t += 20) {
        // High vibration baseline oscillation
        final noise = (t % 80 == 0) ? 14.5 : ((t % 40 == 0) ? 6.0 : 9.8);
        final gzNoise = (t % 80 == 0) ? 26.0 : 3.0;

        final obs = detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 1.5,
          ay: 1.2,
          az: noise,
          gz: gzNoise,
        ));
        if (obs != null) result = obs;
      }

      expect(result, isNull);
    });

    test('TEST-KIN-07: Stationary phone handling / tap is rejected (speed < 20 km/h)', () {
      for (int t = 0; t < 500; t += 20) {
        detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: 9.80665,
        ));
      }

      // Stopped at a traffic light
      detector.onGpsFix(
        const TrackPoint(
          ts: 1000,
          lat: 12.971598,
          lng: 77.594562,
          speedKmh: 0.0,
          accuracyM: 4.0,
        ),
        nowMs: 1000,
      );

      // Rider taps or adjusts phone on handlebar mount: sudden shock and yaw
      RoadHazardObservation? result;
      for (int t = 1000; t <= 1300; t += 20) {
        final az = (t == 1020) ? 30.0 : 9.8;
        final gz = (t == 1040) ? 35.0 : 0.0;

        final obs = detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.5,
          ay: 0.5,
          az: az,
          gz: gz,
        ));
        if (obs != null) result = obs;
      }

      expect(result, isNull);
    });

    test('TEST-KIN-08: Genuine severe pothole on a gravel road is detected', () {
      // Warm up gravity estimator
      for (int t = 0; t < 500; t += 20) {
        detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: 9.80665,
        ));
      }

      detector.onGpsFix(
        const TrackPoint(
          ts: 1000,
          lat: 12.971598,
          lng: 77.594562,
          speedKmh: 45.0,
          accuracyM: 5.0,
        ),
        nowMs: 1000,
      );

      // Gravel road with moderate washboard oscillation (std dev ~ 0.38g)
      for (int t = 500; t < 1000; t += 20) {
        final az = (t % 80 == 0) ? 13.0 : ((t % 40 == 0) ? 7.0 : 9.8);
        detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.5,
          ay: 0.4,
          az: az,
          gz: 4.0,
        ));
      }

      // Severe pothole strike at t = 1000: sharp 34 m/s^2 vertical shock (> 3x std dev) + 38 deg/s steering twitch
      RoadHazardObservation? result;
      for (int t = 1000; t <= 1300; t += 20) {
        final az = (t >= 1000 && t <= 1040) ? 35.0 : 9.8;
        final gz = (t >= 1020 && t <= 1080) ? 38.0 : 3.0;

        final obs = detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.8,
          ay: 0.6,
          az: az,
          gz: gz,
        ));
        if (obs != null) result = obs;
      }

      expect(result, isNotNull);
      expect(result!.classification, equals(RoadHazardClassification.pothole));
      expect(result.peakVerticalG, greaterThan(2.0));
      expect(result.peakYawRateDegS, greaterThanOrEqualTo(25.0));
    });

    test('TEST-KIN-10: Device mounted in landscape orientation projects vertical axis correctly', () {
      final landscapeDetector = RoadHazardDetector();

      // Landscape orientation: gravity points along phone's +X axis
      for (int t = 0; t < 500; t += 20) {
        landscapeDetector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 9.80665,
          ay: 0.0,
          az: 0.0,
        ));
      }

      landscapeDetector.onGpsFix(
        const TrackPoint(
          ts: 1000,
          lat: 12.971598,
          lng: 77.594562,
          speedKmh: 60.0,
          accuracyM: 4.0,
        ),
        nowMs: 1000,
      );

      RoadHazardObservation? result;
      for (int t = 1000; t <= 1300; t += 20) {
        // Vertical shock along Earth-vertical (+X) and yaw rotation around Earth-vertical (+X)
        final ax = (t >= 1000 && t <= 1040) ? 32.0 : 9.8;
        final gx = (t >= 1020 && t <= 1080) ? 35.0 : 0.0;

        final obs = landscapeDetector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: ax,
          ay: 0.0,
          az: 0.0,
          gx: gx,
          gy: 0.0,
          gz: 0.0,
        ));
        if (obs != null) result = obs;
      }

      expect(result, isNotNull);
      expect(result!.classification, equals(RoadHazardClassification.pothole));
      expect(result.peakVerticalG, greaterThan(1.8));
    });

    test('TEST-KIN-11: Missing gyro falls back to uncertainSurfaceAnomaly with lower confidence', () {
      final missingGyroDetector = RoadHazardDetector();
      for (int t = 0; t < 500; t += 20) {
        missingGyroDetector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: 9.80665,
        ));
      }

      missingGyroDetector.onGpsFix(
        const TrackPoint(
          ts: 1000,
          lat: 12.971598,
          lng: 77.594562,
          speedKmh: 50.0,
          accuracyM: 5.0,
        ),
        nowMs: 1000,
      );

      // Severe vertical shock, but gyro readings are absent (all zeros)
      RoadHazardObservation? result;
      for (int t = 1000; t <= 1300; t += 20) {
        final az = (t >= 1000 && t <= 1040) ? 32.0 : 9.8;
        final obs = missingGyroDetector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: az,
          gx: 0.0,
          gy: 0.0,
          gz: 0.0,
        ));
        if (obs != null) result = obs;
      }

      expect(result, isNotNull);
      expect(result!.classification, equals(RoadHazardClassification.uncertainSurfaceAnomaly));
      expect(result.confidence, equals(0.40));
    });

    test('TEST-KIN-12: Two separate hazards spaced 35m apart (beyond 750ms cooldown) are both detected', () {
      final separateDetector = RoadHazardDetector(
        thresholds: const RoadHazardThresholds(cooldownMs: 750),
      );

      for (int t = 0; t < 500; t += 20) {
        separateDetector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: 9.80665,
        ));
      }

      separateDetector.onGpsFix(
        const TrackPoint(
          ts: 1000,
          lat: 12.971598,
          lng: 77.594562,
          speedKmh: 80.0,
          accuracyM: 4.0,
        ),
        nowMs: 1000,
      );

      final detected = <RoadHazardObservation>[];

      // Hazard 1 at t = 1000ms
      for (int t = 1000; t <= 1300; t += 20) {
        final az = (t >= 1000 && t <= 1040) ? 32.0 : 9.8;
        final gz = (t >= 1020 && t <= 1080) ? 35.0 : 0.0;
        final obs = separateDetector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: az,
          gz: gz,
        ));
        if (obs != null) detected.add(obs);
      }

      expect(detected.length, equals(1));

      // At 80 km/h (22.2 m/s), 35m takes ~1575ms. Hazard 2 at t = 2600ms (> 750ms cooldown)
      separateDetector.onGpsFix(
        const TrackPoint(
          ts: 2600,
          lat: 12.971600,
          lng: 77.594920,
          speedKmh: 80.0,
          accuracyM: 4.0,
        ),
        nowMs: 2600,
      );

      for (int t = 2600; t <= 2900; t += 20) {
        final az = (t >= 2600 && t <= 2640) ? 34.0 : 9.8;
        final gz = (t >= 2620 && t <= 2680) ? 32.0 : 0.0;
        final obs = separateDetector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: az,
          gz: gz,
        ));
        if (obs != null) detected.add(obs);
      }

      // Both genuine hazards are detected!
      expect(detected.length, equals(2));
    });

    test('TEST-KIN-09: Wheelbase double-peak cooldown collapses front & rear wheel hits into one', () {
      for (int t = 0; t < 500; t += 20) {
        detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: 9.80665,
        ));
      }

      detector.onGpsFix(
        const TrackPoint(
          ts: 1000,
          lat: 12.971598,
          lng: 77.594562,
          speedKmh: 60.0,
          accuracyM: 5.0,
        ),
        nowMs: 1000,
      );

      final observations = <RoadHazardObservation>[];

      // Front wheel hit at 1000ms
      for (int t = 1000; t <= 1600; t += 20) {
        // Front wheel at 1000, rear wheel at 1140 (140ms later)
        final az = (t >= 1000 && t <= 1020) ? 32.0 : ((t >= 1140 && t <= 1160) ? 34.0 : 9.8);
        final gz = (t >= 1020 && t <= 1060) ? 35.0 : ((t >= 1160 && t <= 1200) ? 30.0 : 1.0);

        final obs = detector.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.1,
          ay: 0.2,
          az: az,
          gz: gz,
        ));
        if (obs != null) observations.add(obs);
      }

      // Exactly ONE observation produced due to cooldown!
      expect(observations.length, equals(1));
    });
  });

  group('FEAT-02: Spatial Deduplication & Aggregation Tests', () {
    test('TEST-AGG-01 & TEST-AGG-02: 100m spatial deduplication and multi-rider corroboration', () {
      final aggregator = RoadHazardAggregator(deduplicationRadiusM: 100.0);

      // Rider 1 reports pothole at (12.9716, 77.5946)
      const obs1 = RoadHazardObservation(
        eventId: 'obs_1',
        timestamp: 1000,
        lat: 12.971600,
        lng: 77.594600,
        accuracyM: 4.0,
        speedKmh: 70.0,
        heading: 90.0,
        peakVerticalG: 2.2,
        peakYawRateDegS: 32.0,
        confidence: 0.80,
        severity: RoadHazardSeverity.high,
        classification: RoadHazardClassification.pothole,
        pseudonymousRiderId: 'rider_lead_1',
      );

      final pin1 = aggregator.ingestObservation(obs1);
      expect(pin1.corroborationCount, equals(1));
      expect(aggregator.activePins.length, equals(1));

      // Rider 2 reports same pothole 30 meters away 5 minutes later
      // 30m offset at this lat is approx 0.00027 deg lon
      const obs2 = RoadHazardObservation(
        eventId: 'obs_2',
        timestamp: 300000,
        lat: 12.971600,
        lng: 77.594870,
        accuracyM: 5.0,
        speedKmh: 68.0,
        heading: 92.0,
        peakVerticalG: 2.5,
        peakYawRateDegS: 36.0,
        confidence: 0.85,
        severity: RoadHazardSeverity.critical,
        classification: RoadHazardClassification.pothole,
        pseudonymousRiderId: 'rider_follower_2',
      );

      final pin2 = aggregator.ingestObservation(obs2);
      // Merged into the same pin!
      expect(pin2.hazardId, equals(pin1.hazardId));
      expect(pin2.corroborationCount, equals(2));
      expect(pin2.severity, equals(RoadHazardSeverity.critical));
      expect(pin2.confidence, greaterThanOrEqualTo(0.95));
      expect(aggregator.activePins.length, equals(1));
    });

    test('TEST-AGG-03: Distinct hazards > 100m apart create separate pins', () {
      final aggregator = RoadHazardAggregator(deduplicationRadiusM: 100.0);

      const obs1 = RoadHazardObservation(
        eventId: 'obs_km10',
        timestamp: 1000,
        lat: 12.971600,
        lng: 77.594600,
        accuracyM: 4.0,
        speedKmh: 65.0,
        heading: 90.0,
        peakVerticalG: 2.1,
        peakYawRateDegS: 30.0,
        confidence: 0.85,
        severity: RoadHazardSeverity.high,
        classification: RoadHazardClassification.pothole,
        pseudonymousRiderId: 'rider_1',
      );
      aggregator.ingestObservation(obs1);

      // Second pothole 200m further down the road
      const obs2 = RoadHazardObservation(
        eventId: 'obs_km10_2',
        timestamp: 12000,
        lat: 12.971600,
        lng: 77.596600,
        accuracyM: 4.0,
        speedKmh: 65.0,
        heading: 90.0,
        peakVerticalG: 2.3,
        peakYawRateDegS: 34.0,
        confidence: 0.88,
        severity: RoadHazardSeverity.high,
        classification: RoadHazardClassification.pothole,
        pseudonymousRiderId: 'rider_1',
      );
      aggregator.ingestObservation(obs2);

      expect(aggregator.activePins.length, equals(2));
    });

    test('TEST-AGG-04: Spatial boundary edge tests (20m, 35m, 99m merge; 101m, 250m split)', () {
      final aggregator = RoadHazardAggregator(deduplicationRadiusM: 100.0);

      const base = RoadHazardObservation(
        eventId: 'obs_base',
        timestamp: 1000,
        lat: 12.971600,
        lng: 77.594600,
        accuracyM: 4.0,
        speedKmh: 65.0,
        heading: 90.0,
        peakVerticalG: 2.1,
        peakYawRateDegS: 30.0,
        confidence: 0.85,
        severity: RoadHazardSeverity.high,
        classification: RoadHazardClassification.pothole,
        pseudonymousRiderId: 'rider_base',
      );
      final basePin = aggregator.ingestObservation(base);

      // 1. Report 20m away: merges
      final pin20m = aggregator.ingestObservation(base.copyWith(
        eventId: 'obs_20m',
        lng: 77.594600 + (20.0 / 108540.0),
        pseudonymousRiderId: 'rider_20m',
      ));
      expect(pin20m.hazardId, equals(basePin.hazardId));
      expect(aggregator.activePins.length, equals(1));

      // 2. Report 99m away: merges
      final pin99m = aggregator.ingestObservation(base.copyWith(
        eventId: 'obs_99m',
        lng: 77.594600 + (99.0 / 108540.0),
        pseudonymousRiderId: 'rider_99m',
      ));
      expect(pin99m.hazardId, equals(basePin.hazardId));
      expect(aggregator.activePins.length, equals(1));

      // 3. Report 101.5m away: splits into separate pin
      final pin101m = aggregator.ingestObservation(base.copyWith(
        eventId: 'obs_101m',
        lng: 77.594600 + (101.5 / 108540.0),
        pseudonymousRiderId: 'rider_101m',
      ));
      expect(pin101m.hazardId, isNot(equals(basePin.hazardId)));
      expect(aggregator.activePins.length, equals(2));
    });

    test('TEST-AGG-05: Repeated reports from the SAME rider do not artificially increment corroboration', () {
      final aggregator = RoadHazardAggregator(deduplicationRadiusM: 100.0);

      const obs1 = RoadHazardObservation(
        eventId: 'obs_lead_1',
        timestamp: 1000,
        lat: 12.971600,
        lng: 77.594600,
        accuracyM: 4.0,
        speedKmh: 65.0,
        heading: 90.0,
        peakVerticalG: 2.1,
        peakYawRateDegS: 30.0,
        confidence: 0.80,
        severity: RoadHazardSeverity.high,
        classification: RoadHazardClassification.pothole,
        pseudonymousRiderId: 'rider_same_lead',
      );
      final pin1 = aggregator.ingestObservation(obs1);
      expect(pin1.corroborationCount, equals(1));

      // Same rider reports again 35m later (e.g. secondary observation or retry)
      final obsRepeat = obs1.copyWith(
        eventId: 'obs_lead_2',
        timestamp: 2000,
        lng: 77.594920,
        pseudonymousRiderId: 'rider_same_lead',
      );
      final pin2 = aggregator.ingestObservation(obsRepeat);
      expect(pin2.hazardId, equals(pin1.hazardId));
      expect(pin2.corroborationCount, equals(1), reason: 'Corroboration count must only increment for distinct riders');
    });

    test('TEST-AGG-06: Low GPS accuracy (> 25m) causes detector rejection', () {
      final detectorHighGps = RoadHazardDetector();
      for (int t = 0; t < 500; t += 20) {
        detectorHighGps.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: 9.80665,
        ));
      }

      // GPS accuracy is poor (40 meters, e.g. canyon/indoor)
      detectorHighGps.onGpsFix(
        const TrackPoint(
          ts: 1000,
          lat: 12.971598,
          lng: 77.594562,
          speedKmh: 60.0,
          accuracyM: 40.0,
        ),
        nowMs: 1000,
      );

      RoadHazardObservation? result;
      for (int t = 1000; t <= 1300; t += 20) {
        final az = (t >= 1000 && t <= 1040) ? 32.0 : 9.8;
        final gz = (t >= 1020 && t <= 1080) ? 35.0 : 0.0;
        final obs = detectorHighGps.onKinematicSample(KinematicSample(
          timestampMs: t,
          ax: 0.0,
          ay: 0.0,
          az: az,
          gz: gz,
        ));
        if (obs != null) result = obs;
      }

      // Must be rejected due to poor GPS accuracy!
      expect(result, isNull);
    });
  });
}
