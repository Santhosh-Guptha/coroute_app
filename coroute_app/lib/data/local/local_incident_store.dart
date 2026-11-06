import 'dart:convert';
import 'dart:io';
import '../../domain/safety/crash_incident.dart';
import 'durable_event_queue.dart';

/// Local persistent store for motorcycle crash incidents.
/// Keeps a durable on-device record of all detected crashes, confirmation responses,
/// vitals telemetry, and dispatch statuses across app restarts.
class LocalIncidentStore {
  final File file;
  final DurableEventQueue? eventQueue;
  final List<CrashIncident> _incidents = [];
  bool _loaded = false;

  LocalIncidentStore({
    required this.file,
    this.eventQueue,
  });

  factory LocalIncidentStore.fromPath(String path, {DurableEventQueue? eventQueue}) {
    return LocalIncidentStore(file: File(path), eventQueue: eventQueue);
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _incidents.clear();
    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = jsonDecode(content);
          if (decoded is List) {
            for (final item in decoded) {
              if (item is Map) {
                _incidents.add(CrashIncident.fromJson(Map<String, dynamic>.from(item)));
              }
            }
          }
        }
      } catch (_) {}
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    final parent = file.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    final raw = jsonEncode(_incidents.map((i) => i.toJson()).toList());
    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsString(raw, flush: true);
    if (await tempFile.exists()) {
      await tempFile.rename(file.path);
    }
  }

  /// Records a new crash or emergency incident locally.
  /// If [syncToQueue] is true and [incident.status] is dispatched,
  /// enqueues it into the [DurableEventQueue] with critical priority.
  Future<void> recordIncident(CrashIncident incident, {bool syncToQueue = true}) async {
    await _ensureLoaded();
    final idx = _incidents.indexWhere((i) => i.incidentId == incident.incidentId);
    if (idx >= 0) {
      _incidents[idx] = incident;
    } else {
      _incidents.insert(0, incident);
    }
    await _persist();

    if (syncToQueue && eventQueue != null && incident.status == IncidentStatus.dispatched) {
      await eventQueue!.enqueue(incident.toDurableEvent());
    }
  }

  /// Updates status of an existing incident (e.g. from countdownActive to confirmedOk or dispatched).
  Future<void> updateStatus(
    String incidentId,
    IncidentStatus newStatus, {
    int? resolvedAt,
    bool syncToQueue = true,
  }) async {
    await _ensureLoaded();
    final idx = _incidents.indexWhere((i) => i.incidentId == incidentId);
    if (idx < 0) return;

    final updated = _incidents[idx].copyWith(
      status: newStatus,
      resolvedAt: resolvedAt,
    );
    _incidents[idx] = updated;
    await _persist();

    if (syncToQueue && eventQueue != null && newStatus == IncidentStatus.dispatched) {
      await eventQueue!.enqueue(updated.toDurableEvent());
    }
  }

  /// Retrieves an incident by its unique ID.
  Future<CrashIncident?> getIncident(String incidentId) async {
    await _ensureLoaded();
    final idx = _incidents.indexWhere((i) => i.incidentId == incidentId);
    return idx >= 0 ? _incidents[idx] : null;
  }

  /// Returns recent incidents, newest first.
  Future<List<CrashIncident>> getRecentIncidents({int limit = 50}) async {
    await _ensureLoaded();
    return _incidents.take(limit).toList();
  }

  /// Clears stored incidents.
  Future<void> clear() async {
    _incidents.clear();
    if (await file.exists()) {
      await file.delete();
    }
    _loaded = true;
  }
}
