import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../domain/sync/durable_event.dart';
import 'durable_event_queue.dart';

/// A durable file-backed [DurableEventQueue] implementation that writes to flash storage.
/// Survives app process kills, background termination, and device reboots.
/// Operates purely with standard file I/O, making it fully functional in all test environments.
class FileDurableEventQueue implements DurableEventQueue {
  final File file;
  final List<DurableEvent> _events = [];
  bool _initialized = false;
  int _nextLocalId = 1;

  FileDurableEventQueue({required this.file});

  factory FileDurableEventQueue.fromPath(String path) {
    return FileDurableEventQueue(file: File(path));
  }

  Future<void> _ensureLoaded() async {
    if (_initialized) return;
    _events.clear();
    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = jsonDecode(content);
          if (decoded is List) {
            for (final item in decoded) {
              if (item is Map) {
                final ev = DurableEvent.fromJson(Map<String, dynamic>.from(item));
                _events.add(ev);
                if (ev.id != null && ev.id! >= _nextLocalId) {
                  _nextLocalId = ev.id! + 1;
                }
              }
            }
          }
        }
      } catch (e) {
        // Corrupted file recovery: preserve whatever was parseable or start fresh
      }
    }
    _initialized = true;
  }

  Future<void> _persist() async {
    final parent = file.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    final raw = jsonEncode(_events.map((e) => e.toJson()).toList());
    // Write atomically via temporary file and rename to avoid half-written corruptions
    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsString(raw, flush: true);
    if (await tempFile.exists()) {
      await tempFile.rename(file.path);
    }
  }

  @override
  Future<void> enqueue(DurableEvent event) async {
    await _ensureLoaded();

    // Idempotency check: if an event with the same idempotencyKey already exists:
    final existingIdx = _events.indexWhere((e) => e.idempotencyKey == event.idempotencyKey);
    if (existingIdx >= 0) {
      final existing = _events[existingIdx];
      // Already synced: duplicate event ignored idempotently
      if (existing.status == EventSyncStatus.synced) {
        return;
      }
      // If still pending or in flight, update payload / timestamp if newer
      _events[existingIdx] = existing.copyWith(
        payload: event.payload,
        priority: event.priority.value < existing.priority.value ? event.priority : existing.priority,
        nextRetryAt: 0,
        status: EventSyncStatus.pending,
      );
      await _persist();
      return;
    }

    final assignedEvent = event.copyWith(
      id: event.id ?? _nextLocalId++,
    );
    _events.add(assignedEvent);
    await _persist();
  }

  @override
  Future<void> enqueueBatch(List<DurableEvent> events) async {
    await _ensureLoaded();
    for (final ev in events) {
      final existingIdx = _events.indexWhere((e) => e.idempotencyKey == ev.idempotencyKey);
      if (existingIdx >= 0) {
        final existing = _events[existingIdx];
        if (existing.status != EventSyncStatus.synced) {
          _events[existingIdx] = existing.copyWith(
            payload: ev.payload,
            priority: ev.priority.value < existing.priority.value ? ev.priority : existing.priority,
            nextRetryAt: 0,
            status: EventSyncStatus.pending,
          );
        }
      } else {
        _events.add(ev.copyWith(id: ev.id ?? _nextLocalId++));
      }
    }
    await _persist();
  }

  @override
  Future<List<DurableEvent>> peekPending({
    int limit = 50,
    int? nowMs,
    EventPriority? maxPriority,
  }) async {
    await _ensureLoaded();
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;

    // Filter pending events that are not waiting for exponential backoff
    final candidates = _events.where((e) {
      if (e.status != EventSyncStatus.pending) return false;
      if (e.nextRetryAt > now) return false;
      if (maxPriority != null && !e.priority.isHigherOrEqualPriorityThan(maxPriority)) return false;
      return true;
    }).toList();

    // Strict priority sorting:
    // 1. Priority (critical 0 before high 1 before normal 2 before low 3)
    // 2. CreatedAt (FIFO within same priority)
    // 3. ID (deterministic order)
    candidates.sort((a, b) {
      final pComp = a.priority.value.compareTo(b.priority.value);
      if (pComp != 0) return pComp;
      final tComp = a.createdAt.compareTo(b.createdAt);
      if (tComp != 0) return tComp;
      return (a.id ?? 0).compareTo(b.id ?? 0);
    });

    return candidates.take(limit).toList();
  }

  @override
  Future<void> markInFlight(List<String> eventIds) async {
    await _ensureLoaded();
    final set = eventIds.toSet();
    var changed = false;
    for (var i = 0; i < _events.length; i++) {
      if (set.contains(_events[i].eventId) && _events[i].status == EventSyncStatus.pending) {
        _events[i] = _events[i].copyWith(status: EventSyncStatus.inFlight);
        changed = true;
      }
    }
    if (changed) await _persist();
  }

  @override
  Future<void> markSynced(List<String> eventIds) async {
    await _ensureLoaded();
    final set = eventIds.toSet();
    var changed = false;
    for (var i = 0; i < _events.length; i++) {
      if (set.contains(_events[i].eventId)) {
        _events[i] = _events[i].copyWith(
          status: EventSyncStatus.synced,
          lastError: null,
        );
        changed = true;
      }
    }
    if (changed) await _persist();
  }

  @override
  Future<void> recordFailure(
    String eventId,
    String error, {
    int? nowMs,
    Duration? backoffOverride,
  }) async {
    await _ensureLoaded();
    final idx = _events.indexWhere((e) => e.eventId == eventId);
    if (idx < 0) return;

    final ev = _events[idx];
    final nextRetryCount = ev.retryCount + 1;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;

    final delayMs = backoffOverride?.inMilliseconds ??
        calculateExponentialBackoffMs(nextRetryCount, priority: ev.priority);

    _events[idx] = ev.copyWith(
      status: EventSyncStatus.pending,
      retryCount: nextRetryCount,
      nextRetryAt: now + delayMs,
      lastError: error,
    );
    await _persist();
  }

  @override
  Future<int> countPending({EventPriority? priority, DurableEventType? type}) async {
    await _ensureLoaded();
    return _events.where((e) {
      if (e.status != EventSyncStatus.pending) return false;
      if (priority != null && e.priority != priority) return false;
      if (type != null && e.eventType != type) return false;
      return true;
    }).length;
  }

  @override
  Future<DurableEvent?> getByIdempotencyKey(String idempotencyKey) async {
    await _ensureLoaded();
    final idx = _events.indexWhere((e) => e.idempotencyKey == idempotencyKey);
    return idx >= 0 ? _events[idx] : null;
  }

  @override
  Future<void> pruneSynced({Duration keepDuration = const Duration(days: 3)}) async {
    await _ensureLoaded();
    final cutoff = DateTime.now().millisecondsSinceEpoch - keepDuration.inMilliseconds;
    final before = _events.length;
    _events.removeWhere((e) => e.status == EventSyncStatus.synced && e.createdAt < cutoff);
    if (_events.length != before) {
      await _persist();
    }
  }

  @override
  Future<void> clear() async {
    _events.clear();
    _nextLocalId = 1;
    if (await file.exists()) {
      await file.delete();
    }
    _initialized = true;
  }

  @override
  Future<void> close() async {
    // Flush completed
  }
}
