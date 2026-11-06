import '../../domain/sync/durable_event.dart';

/// Abstract contract for a crash-resilient local event queue.
/// Supports priority queueing, idempotency key enforcement, exponential backoff,
/// and persistence across process kills and phone reboots.
abstract class DurableEventQueue {
  /// Enqueues a durable event. If an event with the same [idempotencyKey]
  /// already exists in the queue:
  /// - If already synced: returns without doing anything (idempotent duplicate rejection).
  /// - If pending or in-flight: updates payload without duplicating queue entry.
  Future<void> enqueue(DurableEvent event);

  /// Enqueues multiple events in a single transactional batch.
  Future<void> enqueueBatch(List<DurableEvent> events);

  /// Fetches pending events eligible for synchronization at [nowMs], ordered strictly by:
  /// `priority ASC, createdAt ASC, id ASC`.
  /// This guarantees that [EventPriority.critical] (SOS, crash incidents) ALWAYS sync
  /// before [EventPriority.normal] (GPS trail points) and [EventPriority.low] (analytics).
  /// Events currently waiting in exponential backoff (`nextRetryAt > nowMs`) are skipped.
  Future<List<DurableEvent>> peekPending({
    int limit = 50,
    int? nowMs,
    EventPriority? maxPriority,
  });

  /// Transitions events to [EventSyncStatus.inFlight] while network dispatch is active.
  Future<void> markInFlight(List<String> eventIds);

  /// Marks events as [EventSyncStatus.synced] after server confirmation/acknowledgement.
  Future<void> markSynced(List<String> eventIds);

  /// Records a failed sync attempt, updates the retry count, and computes
  /// the next retry timestamp using exponential backoff.
  Future<void> recordFailure(
    String eventId,
    String error, {
    int? nowMs,
    Duration? backoffOverride,
  });

  /// Returns the number of events waiting to be synced.
  Future<int> countPending({EventPriority? priority, DurableEventType? type});

  /// Finds an existing event by its idempotency key.
  Future<DurableEvent?> getByIdempotencyKey(String idempotencyKey);

  /// Prunes completed/synced events older than [keepDuration] to reclaim storage.
  Future<void> pruneSynced({Duration keepDuration = const Duration(days: 3)});

  /// Clears all events (used for test teardown and account resets).
  Future<void> clear();

  /// Closes database or file handles safely.
  Future<void> close();
}
