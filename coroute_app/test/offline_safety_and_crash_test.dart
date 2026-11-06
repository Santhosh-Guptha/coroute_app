import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/crash_detector.dart';
import 'package:coroute_app/domain/safety/crash_incident.dart';
import 'package:coroute_app/domain/sync/durable_event.dart';
import 'package:coroute_app/data/local/file_durable_event_queue.dart';
import 'package:coroute_app/data/local/local_incident_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File incidentFile;
  late File queueFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('coroute_offline_safety_test_');
    incidentFile = File('${tempDir.path}/incidents.json');
    queueFile = File('${tempDir.path}/durable_events.json');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

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


  group('Local Incident Persistence Across App Restarts', () {
    test('persists crash incident details, status updates, and vitals across store restart', () async {
      final queue = FileDurableEventQueue(file: queueFile);

      // Session 1: App records a crash incident
      final store1 = LocalIncidentStore(file: incidentFile, eventQueue: queue);

      const incident = CrashIncident(
        incidentId: 'inc_test_1001',
        timestamp: 1700000000000,
        lat: 12.9716,
        lng: 77.5946,
        impactG: 5.7,
        speedBeforeKmh: 52.0,
        peakGyroRadS: 2.8,
        tiltDeg: 62.0,
        isSlideFall: true,
        source: 'CRASH_AUTO',
        status: IncidentStatus.countdownActive,
        idempotencyKey: 'crash_inc_test_1001',
        groupId: 'GRP-99',
        vitals: {'bpm': 135, 'trauma': 'MODERATE'},
      );

      await store1.recordIncident(incident);

      // Rider confirms "I'M OK"
      await store1.updateStatus(
        'inc_test_1001',
        IncidentStatus.confirmedOk,
        resolvedAt: 1700000010000,
      );

      // Verify file written to disk
      expect(await incidentFile.exists(), isTrue);

      // Session 2: Phone reboots or app relaunched
      final store2 = LocalIncidentStore(file: incidentFile, eventQueue: queue);

      final loaded = await store2.getIncident('inc_test_1001');
      expect(loaded, isNotNull);
      expect(loaded!.incidentId, 'inc_test_1001');
      expect(loaded.lat, 12.9716);
      expect(loaded.lng, 77.5946);
      expect(loaded.impactG, 5.7);
      expect(loaded.speedBeforeKmh, 52.0);
      expect(loaded.tiltDeg, 62.0);
      expect(loaded.isSlideFall, isTrue);
      expect(loaded.status, IncidentStatus.confirmedOk);
      expect(loaded.resolvedAt, 1700000010000);
      expect(loaded.vitals?['bpm'], 135);
    });

    test('dispatched incident automatically enqueues into durable priority queue', () async {
      final queue = FileDurableEventQueue(file: queueFile);
      final store = LocalIncidentStore(file: incidentFile, eventQueue: queue);

      const incident = CrashIncident(
        incidentId: 'inc_unresponsive_2002',
        timestamp: 1700000050000,
        lat: 13.0827,
        lng: 80.2707,
        impactG: 7.1,
        speedBeforeKmh: 68.0,
        source: 'CRASH_AUTO',
        status: IncidentStatus.dispatched, // Dispatched!
        idempotencyKey: 'crash_inc_unresponsive_2002',
        groupId: 'GRP-99',
      );

      await store.recordIncident(incident);

      // Verify it was automatically enqueued into DurableEventQueue
      expect(await queue.countPending(), 1);

      final pendingEvents = await queue.peekPending();
      expect(pendingEvents.length, 1);
      expect(pendingEvents.first.eventType, DurableEventType.crashIncident);
      expect(pendingEvents.first.priority, EventPriority.critical);
      expect(pendingEvents.first.idempotencyKey, 'crash_inc_unresponsive_2002');
    });
  });
}
