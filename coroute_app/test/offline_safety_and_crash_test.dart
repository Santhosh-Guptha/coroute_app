import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/crash_detector.dart';
import 'package:coroute_app/data/models/pending_sos.dart';
import 'package:coroute_app/data/models/network_wire.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Standalone Local Crash Detection (No Cloud & No GPS)', () {
    test('detects high-impact motorcycle crash purely on accelerometer and gyroscope streams', () {
      // In standalone offline mode, the detector does NOT require prior GPS fixes to arm
      final detector = CrashDetector(standaloneOfflineMode: true);
      expect(detector.wantsSensor, isTrue);

      const t0 = 1700000000000;

      // 1. Riding baseline motion (vibrations on bike)
      for (var s = 0; s < 10; s++) {
        detector.onAccel(AccelBucket(
          tMs: t0 + s * 1000,
          peakG: 1.4,
          meanG: 1.0,
          stdG: 0.25,
          peakDynG: 0.5,
          peakGyroRadS: 0.3,
          tiltDeg: 5.0,
        ));
      }

      // 2. Severe impact and bike rollover: 6.5G dynamic shock + 3.2 rad/s angular spin + 65 deg tilt
      final impactBucket = AccelBucket(
        tMs: t0 + 10000,
        peakG: 6.8,
        meanG: 2.5,
        stdG: 1.8,
        peakDynG: 6.5,
        peakGyroRadS: 3.2,
        tiltDeg: 65.0,
        impactDurationMs: 120.0,
      );
      final candidateEvent = detector.onAccel(impactBucket);
      expect(candidateEvent, isNull, reason: 'Stop and stillness window must be evaluated');
      expect(detector.evaluating, isTrue);

      // 3. Post-impact motorcycle slide and tumble (1-3s)
      for (var s = 11; s <= 13; s++) {
        detector.onAccel(AccelBucket(
          tMs: t0 + s * 1000,
          peakG: 2.2,
          meanG: 1.2,
          stdG: 0.8,
          peakDynG: 1.8,
          peakGyroRadS: 1.5,
          tiltDeg: 70.0,
        ));
      }

      // 4. Motorcycle and rider come to rest on road shoulder (stillness stdG < 0.05 for 20s)
      CrashEvent? detectedCrash;
      for (var s = 14; s <= 45; s++) {
        final ev = detector.onAccel(AccelBucket(
          tMs: t0 + s * 1000,
          peakG: 1.02,
          meanG: 1.0,
          stdG: 0.02,
          peakDynG: 0.02,
          peakGyroRadS: 0.01,
          tiltDeg: 72.0,
        ));
        if (ev != null) {
          detectedCrash = ev;
          break;
        }
      }

      expect(detectedCrash, isNotNull);
      expect(detectedCrash!.impactG, greaterThanOrEqualTo(6.5));
      expect(detectedCrash.hasRotationOrTilt, isTrue);
    });

    test('rejects road bumps and speed breakers without crash false alarm', () {
      final detector = CrashDetector(standaloneOfflineMode: true);
      const t0 = 1700000000000;

      // Bump: 2.8G transient shock with 0 rotation, followed by continued riding
      detector.onAccel(AccelBucket(
        tMs: t0,
        peakG: 2.8,
        meanG: 1.1,
        stdG: 0.4,
        peakDynG: 2.6,
        peakGyroRadS: 0.2, // minimal rotation
        tiltDeg: 2.0,      // bike remains upright
        impactDurationMs: 25.0,
      ));

      // Rider continues riding (continuous engine & road vibration stdG > 0.25)
      for (var s = 1; s <= 30; s++) {
        final ev = detector.onAccel(AccelBucket(
          tMs: t0 + s * 1000,
          peakG: 1.5,
          meanG: 1.0,
          stdG: 0.3,
          peakDynG: 0.6,
          peakGyroRadS: 0.2,
          tiltDeg: 3.0,
        ));
        expect(ev, isNull);
      }
      expect(detector.evaluating, isFalse);
    });
  });


  // 3.55 platform: the separate incident queue was retired. The one offline store for a crash
  // SOS is the pending-SOS store (ConvoyService), resent with the same clientId on reconnect.
  group('Offline crash SOS record (pending-SOS store)', () {
    test('crash SOS raised offline round-trips through disk with its crash fields and clientId', () {
      const pending = PendingSos(
        clientId: 'usr_a-1700000000000',
        groupId: 'GRP-99',
        lat: 12.9716,
        lng: 77.5946,
        type: 'CRASH',
        createdAt: 1700000000000,
        auto: true,
        speedBeforeKmh: 52.0,
        impactG: 5.7,
        source: EmergencySource.crashAuto,
      );
      final restored = PendingSos.decode(pending.encode());
      expect(restored, isNotNull);
      expect(restored!.clientId, pending.clientId);
      expect(restored.type, 'CRASH');
      expect(restored.auto, isTrue);
      expect(restored.impactG, 5.7);
      expect(restored.speedBeforeKmh, 52.0);
      expect(restored.source, EmergencySource.crashAuto);
      expect(restored.createdAt, 1700000000000);
      // The replay carries the same clientId: the gateway stores it once (idempotent per rider + clientId).
      final wire = restored.toMessage();
      expect(wire['type'], 'SOS');
      expect(wire['clientId'], pending.clientId);
      expect(wire['alertType'], 'CRASH');
      expect(wire['occurredAt'], 1700000000000);
    });
  });
}
