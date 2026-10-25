import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/data/services/biometric_safety_bridge.dart';
import 'package:coroute_app/presentation/rider/widgets/biometric_pulse_hud_pill.dart';
import 'package:coroute_app/presentation/safety/crash_alarm_screen.dart';

void main() {
  setUp(() {
    FeatureGates.forceAllUnlocked = false;
    FeatureGates.activeTier = SubscriptionTier.proRider;
    BiometricSafetyBridge().reset();
  });

  tearDown(() {
    FeatureGates.forceAllUnlocked = false;
    FeatureGates.activeTier = SubscriptionTier.community;
    BiometricSafetyBridge().reset();
  });

  group('FEAT-04: BiometricSafetyBridge Core Logic & Gating', () {
    test('TEST-BIO-01: Pro & Road Captain Tier Entitlement Gating', () {
      // Community: locked
      expect(
        FeatureGates.isUnlocked(Feature.biometricTraumaPulse, SubscriptionTier.community),
        isFalse,
      );
      expect(FeatureGates.requiredTier(Feature.biometricTraumaPulse), equals(SubscriptionTier.proRider));

      // Pro Rider: unlocked
      expect(
        FeatureGates.isUnlocked(Feature.biometricTraumaPulse, SubscriptionTier.proRider),
        isTrue,
      );

      // Road Captain: unlocked
      expect(
        FeatureGates.isUnlocked(Feature.biometricTraumaPulse, SubscriptionTier.roadCaptain),
        isTrue,
      );

      // Tour Operator: unlocked
      expect(
        FeatureGates.isUnlocked(Feature.biometricTraumaPulse, SubscriptionTier.tourOperator),
        isTrue,
      );
    });

    test('TEST-BIO-02: Bridge Lifecycle Management', () {
      final bridge = BiometricSafetyBridge();
      expect(bridge.isActive, isFalse);

      bridge.start(source: BiometricSensorSource.appleHealthKit);
      expect(bridge.isActive, isTrue);
      expect(bridge.snapshot.isConnected, isTrue);
      expect(bridge.snapshot.source, equals(BiometricSensorSource.appleHealthKit));

      bridge.stop();
      expect(bridge.isActive, isFalse);
      expect(bridge.snapshot.isConnected, isFalse);
    });

    test('TEST-BIO-03: Rolling 5-Minute History Buffer Pruning & Capacity Clamping', () {
      final bridge = BiometricSafetyBridge();
      bridge.start(source: BiometricSensorSource.bleHeartRateGatt);

      final baseTime = 1730000000000;

      // Add sample 6 minutes ago (should be pruned)
      bridge.recordSample(70, timestampMs: baseTime - (6 * 60 * 1000));
      // Add sample 2 minutes ago (valid)
      bridge.recordSample(75, timestampMs: baseTime - (2 * 60 * 1000));
      // Add current sample
      bridge.recordSample(80, timestampMs: baseTime);

      expect(bridge.samples.length, equals(2));
      expect(bridge.samples.first.bpm, equals(75));
      expect(bridge.samples.last.bpm, equals(80));

      // Test max sample capacity clamping (60 samples)
      for (int i = 0; i < 70; i++) {
        bridge.recordSample(80 + (i % 5), timestampMs: baseTime + (i * 1000));
      }
      expect(bridge.samples.length, lessThanOrEqualTo(BiometricSafetyBridge.maxSamples));
    });

    test('TEST-BIO-04: Dynamic Baseline Calculation', () {
      final bridge = BiometricSafetyBridge();
      bridge.start(source: BiometricSensorSource.bleHeartRateGatt);

      final now = DateTime.now().millisecondsSinceEpoch;
      bridge.recordSample(70, timestampMs: now - 30000);
      bridge.recordSample(80, timestampMs: now - 20000);
      bridge.recordSample(90, timestampMs: now - 10000);

      final baseline = bridge.computeBaselineBpm();
      expect(baseline, equals(80));
      expect(bridge.snapshot.baselineBpm, equals(80));
    });

    test('TEST-BIO-05: Critical Trauma L1 — Asystole / Pulselessness (0 BPM)', () {
      final bridge = BiometricSafetyBridge();
      bridge.start(source: BiometricSensorSource.bleHeartRateGatt);

      // Resting samples
      final now = DateTime.now().millisecondsSinceEpoch;
      bridge.recordSample(78, timestampMs: now - 5000);

      // Post-crash pulse drops to 0 while watch remains on wrist
      bridge.recordSample(0, timestampMs: now, onWrist: true);

      expect(bridge.snapshot.traumaLevel, equals(BiometricTraumaLevel.criticalTraumaLevel1));
      expect(bridge.snapshot.isCritical, isTrue);
      expect(bridge.snapshot.traumaDescription, contains('Cardiac Arrest / Pulselessness Alert'));
    });

    test('TEST-BIO-06: Critical Trauma L1 — Severe Tachycardia (BPM >= 160 or Baseline + 60)', () {
      final bridge = BiometricSafetyBridge();
      bridge.start(source: BiometricSensorSource.appleHealthKit);

      final now = DateTime.now().millisecondsSinceEpoch;
      bridge.recordSample(80, timestampMs: now - 10000);

      // Spikes to 168 BPM post-impact
      bridge.recordSample(168, timestampMs: now, onWrist: true);

      expect(bridge.snapshot.traumaLevel, equals(BiometricTraumaLevel.criticalTraumaLevel1));
      expect(bridge.snapshot.isCritical, isTrue);
      expect(bridge.snapshot.traumaDescription, contains('Severe Post-Impact Tachycardia'));
    });

    test('TEST-BIO-07: Elevated Trauma — Acute Stress (120 - 159 BPM)', () {
      final bridge = BiometricSafetyBridge();
      bridge.start(source: BiometricSensorSource.googleHealthConnect);

      final now = DateTime.now().millisecondsSinceEpoch;
      bridge.recordSample(75, timestampMs: now - 10000);
      bridge.recordSample(135, timestampMs: now, onWrist: true);

      expect(bridge.snapshot.traumaLevel, equals(BiometricTraumaLevel.elevatedTrauma));
      expect(bridge.snapshot.isCritical, isFalse);
      expect(bridge.snapshot.traumaDescription, contains('Acute Stress Tachycardia'));
    });

    test('TEST-BIO-08: Stable Trauma — Normal Sinus Rhythm (60 - 100 BPM)', () {
      final bridge = BiometricSafetyBridge();
      bridge.start(source: BiometricSensorSource.bleHeartRateGatt);

      final now = DateTime.now().millisecondsSinceEpoch;
      bridge.recordSample(72, timestampMs: now, onWrist: true);

      expect(bridge.snapshot.traumaLevel, equals(BiometricTraumaLevel.stableTrauma));
      expect(bridge.snapshot.isCritical, isFalse);
      expect(bridge.snapshot.traumaDescription, contains('Stable Sinus Rhythm'));
    });

    test('TEST-BIO-09: Sensor Disconnected / Watch Off Wrist Fallback', () {
      final bridge = BiometricSafetyBridge();
      bridge.start(source: BiometricSensorSource.bleHeartRateGatt);

      // Watch was taken off or flew off wrist
      bridge.recordSample(0, onWrist: false);

      expect(bridge.snapshot.traumaLevel, equals(BiometricTraumaLevel.unverified));
      expect(bridge.snapshot.isCritical, isFalse);
      expect(bridge.snapshot.traumaDescription, contains('Sensor Unlinked / Disconnected'));
    });

    test('TEST-BIO-10: Paramedic Payload Packaging with Blood Group & 5-min History', () {
      final bridge = BiometricSafetyBridge();
      bridge.start(source: BiometricSensorSource.appleHealthKit);

      final now = DateTime.now().millisecondsSinceEpoch;
      bridge.recordSample(75, timestampMs: now - 60000);
      bridge.recordSample(165, timestampMs: now);

      final payload = bridge.toBiometricPayload(bloodGroup: 'O+');

      expect(payload['traumaLevel'], equals('CRITICAL_TRAUMA_L1'));
      expect(payload['currentBpm'], equals(165));
      expect(payload['bloodGroup'], equals('O+'));
      expect(payload['sensorSource'], equals('APPLE_HEALTHKIT'));
      expect(payload['watchOnWrist'], isTrue);
      expect(payload['heartRateHistory'], isA<List>());
      expect((payload['heartRateHistory'] as List).length, equals(2));
    });
  });

  group('FEAT-04: UI Widget Rendering & Visual Hardening', () {
    testWidgets('TEST-BIO-11: BiometricPulseHudPill Rendering & Semantics', (tester) async {
      final handle = tester.ensureSemantics();

      // Stable pulse state
      const stableSnap = BiometricSnapshot(
        currentBpm: 76,
        baselineBpm: 72,
        traumaLevel: BiometricTraumaLevel.stableTrauma,
        source: BiometricSensorSource.appleHealthKit,
        isWatchOnWrist: true,
        isConnected: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: BiometricPulseHudPill(
                snapshot: stableSnap,
                onTap: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('PULSE · 76 BPM'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
      expect(find.bySemanticsLabel('Rider Biometric Pulse: PULSE · 76 BPM'), findsOneWidget);

      // Critical pulse state
      const critSnap = BiometricSnapshot(
        currentBpm: 172,
        baselineBpm: 75,
        traumaLevel: BiometricTraumaLevel.criticalTraumaLevel1,
        source: BiometricSensorSource.bleHeartRateGatt,
        isWatchOnWrist: true,
        isConnected: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: BiometricPulseHudPill(
                snapshot: critSnap,
                onTap: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('TRAUMA L1 · 172 BPM'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

      handle.dispose();
    });

    testWidgets('TEST-BIO-12: CrashAlarmView Renders Pulse & Trauma Badge', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CrashAlarmView(
            secondsLeft: 12,
            onImOk: () {},
            onSendNow: () {},
            currentBpm: 168,
            traumaLevel: BiometricTraumaLevel.criticalTraumaLevel1,
          ),
        ),
      );

      expect(find.text('12'), findsOneWidget);
      expect(find.text('168 BPM · Critical Trauma Level 1'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    });
  });
}
