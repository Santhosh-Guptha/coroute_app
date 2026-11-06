import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/sync/durable_event.dart';
import 'package:coroute_app/data/local/file_durable_event_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File queueFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('coroute_queue_test_');
    queueFile = File('${tempDir.path}/durable_events.json');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('DurableEventQueue Survival Across Process Kill & Phone Restart', () {
    test('survives instance teardown and reloads all records, statuses, and retry counts', () async {
      // Phase 1: First app session - enqueue various events
      final queue1 = FileDurableEventQueue(file: queueFile);

      final gpsEvent = DurableEvent(
        eventId: 'evt_gps_1',
        idempotencyKey: 'gps_grp1_chunk1',
        eventType: DurableEventType.gpsTrail,
        priority: EventPriority.normal,
        groupId: 'GRP-100',
        payload: {'points': 20, 'seq': 1},
        createdAt: 1700000000000,
      );

      final sosEvent = DurableEvent(
        eventId: 'evt_sos_1',
        idempotencyKey: 'sos_user99_1700000001000',
        eventType: DurableEventType.sos,
        priority: EventPriority.critical,
        groupId: 'GRP-100',
        payload: {'alertType': 'CRASH', 'lat': 12.9716, 'lng': 77.5946, 'impactG': 5.8},
        createdAt: 1700000001000,
      );

      final tripEvent = DurableEvent(
        eventId: 'evt_trip_1',
        idempotencyKey: 'trip_TRIP-100-user99',
        eventType: DurableEventType.tripCompletion,
        priority: EventPriority.high,
        groupId: 'GRP-100',
        payload: {'distanceM': 45200, 'durationS': 3600},
        createdAt: 1700000002000,
      );

      await queue1.enqueue(gpsEvent);
      await queue1.enqueue(sosEvent);
      await queue1.enqueue(tripEvent);

      // Record a failure on GPS event to test retryCount and nextRetryAt persistence
      await queue1.recordFailure(
        'evt_gps_1',
        'Connection reset by peer',
        nowMs: 1700000005000,
        backoffOverride: const Duration(seconds: 10),
      );

      // Phase 2: Simulate process kill / app crash (dispose queue1 completely)
      await queue1.close();

      // Verify the backing file actually exists on physical disk
      expect(await queueFile.exists(), isTrue);

      // Phase 3: Phone restart / second app session - load new queue from same file
      final queue2 = FileDurableEventQueue(file: queueFile);

      expect(await queue2.countPending(), 3);

      final loadedSos = await queue2.getByIdempotencyKey('sos_user99_1700000001000');
      expect(loadedSos, isNotNull);
      expect(loadedSos!.eventType, DurableEventType.sos);
      expect(loadedSos.priority, EventPriority.critical);
      expect(loadedSos.payload['impactG'], 5.8);

      final loadedGps = await queue2.getByIdempotencyKey('gps_grp1_chunk1');
      expect(loadedGps, isNotNull);
      expect(loadedGps!.retryCount, 1);
      expect(loadedGps.nextRetryAt, 1700000015000);
      expect(loadedGps.lastError, 'Connection reset by peer');

      await queue2.close();
    });
  });

  group('Idempotency Keys and Duplicate Prevention', () {
    test('enqueuing event with duplicate idempotency key does not create duplicates', () async {
      final queue = FileDurableEventQueue(file: queueFile);

      const key = 'sos_idempotent_test_key_001';
      final event1 = DurableEvent(
        eventId: 'evt_1',
        idempotencyKey: key,
        eventType: DurableEventType.sos,
        priority: EventPriority.critical,
        groupId: 'GRP-1',
        payload: {'step': 1, 'lat': 12.0},
        createdAt: 1000,
      );

      await queue.enqueue(event1);
      expect(await queue.countPending(), 1);

      // Enqueue again with same idempotency key and updated payload
      final event2 = DurableEvent(
        eventId: 'evt_2',
        idempotencyKey: key,
        eventType: DurableEventType.sos,
        priority: EventPriority.critical,
        groupId: 'GRP-1',
        payload: {'step': 2, 'lat': 12.001},
        createdAt: 1050,
      );

      await queue.enqueue(event2);
      // Count must still be 1 (deduplicated)
      expect(await queue.countPending(), 1);

      final stored = await queue.getByIdempotencyKey(key);
      expect(stored, isNotNull);
      expect(stored!.payload['step'], 2);
      expect(stored.payload['lat'], 12.001);

      // Mark it synced
      await queue.markSynced([stored.eventId]);
      expect(await queue.countPending(), 0);

      // Try enqueuing again after synced: duplicate is rejected idempotently
      final event3 = DurableEvent(
        eventId: 'evt_3',
        idempotencyKey: key,
        eventType: DurableEventType.sos,
        priority: EventPriority.critical,
        groupId: 'GRP-1',
        payload: {'step': 3},
        createdAt: 2000,
      );
      await queue.enqueue(event3);
      expect(await queue.countPending(), 0); // Still 0, not re-queued
    });
  });

  group('Priority Queueing: Emergency/SOS Before GPS/Analytics', () {
    test('critical emergency events ALWAYS peek ahead of ordinary GPS and analytics', () async {
      final queue = FileDurableEventQueue(file: queueFile);

      // Enqueue 5 normal GPS events first at t = 100
      for (var i = 1; i <= 5; i++) {
        await queue.enqueue(DurableEvent(
          eventId: 'gps_$i',
          idempotencyKey: 'key_gps_$i',
          eventType: DurableEventType.gpsTrail,
          priority: EventPriority.normal, // Priority 2
          groupId: 'GRP-1',
          payload: {'seq': i},
          createdAt: 100 + i,
        ));
      }

      // Enqueue 2 low priority analytics events at t = 110
      for (var i = 1; i <= 2; i++) {
        await queue.enqueue(DurableEvent(
          eventId: 'analytics_$i',
          idempotencyKey: 'key_analytics_$i',
          eventType: DurableEventType.analytics,
          priority: EventPriority.low, // Priority 3
          groupId: 'GRP-1',
          payload: {'metric': 'battery', 'val': 85},
          createdAt: 110 + i,
        ));
      }

      // Enqueue 1 trip completion event (high priority) at t = 120
      await queue.enqueue(DurableEvent(
        eventId: 'trip_end',
        idempotencyKey: 'key_trip_end',
        eventType: DurableEventType.tripCompletion,
        priority: EventPriority.high, // Priority 1
        groupId: 'GRP-1',
        payload: {'status': 'ENDED'},
        createdAt: 120,
      ));

      // Now, an emergency crash occurs at t = 130!
      await queue.enqueue(DurableEvent(
        eventId: 'crash_emergency',
        idempotencyKey: 'key_crash_emergency',
        eventType: DurableEventType.crashIncident,
        priority: EventPriority.critical, // Priority 0 (CRITICAL!)
        groupId: 'GRP-1',
        payload: {'impactG': 6.2, 'speedBeforeKmh': 65.0},
        createdAt: 130,
      ));

      // Also a manual SOS at t = 135!
      await queue.enqueue(DurableEvent(
        eventId: 'sos_manual',
        idempotencyKey: 'key_sos_manual',
        eventType: DurableEventType.sos,
        priority: EventPriority.critical, // Priority 0 (CRITICAL!)
        groupId: 'GRP-1',
        payload: {'alertType': 'MANUAL'},
        createdAt: 135,
      ));

      // Peek next 10 events:
      final pending = await queue.peekPending(limit: 10, nowMs: 200);

      expect(pending.length, 10);

      // Index 0 MUST be the first critical event (crash_emergency)
      expect(pending[0].eventId, 'crash_emergency');
      expect(pending[0].priority, EventPriority.critical);

      // Index 1 MUST be the second critical event (sos_manual)
      expect(pending[1].eventId, 'sos_manual');
      expect(pending[1].priority, EventPriority.critical);

      // Index 2 MUST be high priority (trip_end)
      expect(pending[2].eventId, 'trip_end');
      expect(pending[2].priority, EventPriority.high);

      // Indices 3-7 MUST be normal GPS trail points in chronological order
      for (var i = 0; i < 5; i++) {
        expect(pending[3 + i].priority, EventPriority.normal);
        expect(pending[3 + i].eventId, 'gps_${i + 1}');
      }

      // Indices 8-9 MUST be low priority analytics
      expect(pending[8].priority, EventPriority.low);
      expect(pending[9].priority, EventPriority.low);
    });
  });

  group('Exponential Backoff Retry on Network Failure', () {
    test('computes exponential backoff correctly and delays retries', () async {
      final queue = FileDurableEventQueue(file: queueFile);

      // Critical event exponential backoff: 500ms, 1000ms, 2000ms, 4000ms...
      expect(calculateExponentialBackoffMs(1, priority: EventPriority.critical), 500);
      expect(calculateExponentialBackoffMs(2, priority: EventPriority.critical), 1000);
      expect(calculateExponentialBackoffMs(3, priority: EventPriority.critical), 2000);
      expect(calculateExponentialBackoffMs(4, priority: EventPriority.critical), 4000);
      expect(calculateExponentialBackoffMs(10, priority: EventPriority.critical), 15000); // capped at 15s

      // Normal event backoff: 1000ms, 2000ms, 4000ms, 8000ms...
      expect(calculateExponentialBackoffMs(1, priority: EventPriority.normal), 1000);
      expect(calculateExponentialBackoffMs(2, priority: EventPriority.normal), 2000);
      expect(calculateExponentialBackoffMs(3, priority: EventPriority.normal), 4000);
      expect(calculateExponentialBackoffMs(4, priority: EventPriority.normal), 8000);
      expect(calculateExponentialBackoffMs(10, priority: EventPriority.normal), 60000); // capped at 60s

      final event = DurableEvent(
        eventId: 'evt_fail_test',
        idempotencyKey: 'key_fail_test',
        eventType: DurableEventType.gpsTrail,
        priority: EventPriority.normal,
        groupId: 'GRP-1',
        payload: {'seq': 1},
        createdAt: 1000,
      );
      await queue.enqueue(event);

      // Attempt 1 fails at t = 2000 ms
      await queue.recordFailure('evt_fail_test', 'Socket timeout', nowMs: 2000);

      // Next retry is scheduled at 2000 + 1000 = 3000 ms
      var peekAt2500 = await queue.peekPending(nowMs: 2500);
      expect(peekAt2500, isEmpty, reason: 'Event is backing off, should not peek yet');

      var peekAt3000 = await queue.peekPending(nowMs: 3000);
      expect(peekAt3000.length, 1, reason: 'Event backoff expired, should peek now');
      expect(peekAt3000.first.retryCount, 1);

      // Attempt 2 fails at t = 3000 ms
      await queue.recordFailure('evt_fail_test', 'HTTP 503', nowMs: 3000);

      // Next retry is scheduled at 3000 + 2000 = 5000 ms
      var peekAt4500 = await queue.peekPending(nowMs: 4500);
      expect(peekAt4500, isEmpty);

      var peekAt5000 = await queue.peekPending(nowMs: 5000);
      expect(peekAt5000.length, 1);
      expect(peekAt5000.first.retryCount, 2);
    });
  });

}
