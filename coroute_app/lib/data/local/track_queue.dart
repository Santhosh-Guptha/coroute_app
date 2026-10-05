import '../../domain/tracking/track_chunker.dart';
import '../../domain/tracking/track_point.dart';

/// Durable queue of recorded GPS points waiting for upload.
///
/// Points are written on the phone first, so a dead zone, a crash or a
/// restart never loses the route; the uploader drains the queue whenever the
/// connection allows.
abstract class TrackQueue {
  Future<void> add(String groupId, TrackPoint p);

  /// Oldest pending points of one group.
  Future<List<QueuedPoint>> pending(String groupId, {int limit = 2400});

  Future<List<String>> groupsWithPending();
  Future<void> markUploaded(List<int> ids);

  /// Forgets a group entirely (server refused it: not a member or trip closed).
  Future<void> dropGroup(String groupId);

  /// Removes uploaded points older than [keep].
  Future<void> prune({Duration keep = const Duration(days: 2)});

  /// Writes anything still buffered in memory.
  Future<void> flushBuffer();
}

/// In-memory queue for tests and for platforms without SQLite.
class MemoryTrackQueue implements TrackQueue {
  final List<_Row> _rows = [];
  int _nextId = 1;

  int get length => _rows.length;
  int pendingCount(String groupId) => _rows.where((r) => r.groupId == groupId && !r.uploaded).length;

  @override
  Future<void> add(String groupId, TrackPoint p) async {
    _rows.add(_Row(_nextId++, groupId, p));
  }

  @override
  Future<List<QueuedPoint>> pending(String groupId, {int limit = 2400}) async =>
      _rows.where((r) => r.groupId == groupId && !r.uploaded).take(limit).map((r) => QueuedPoint(r.id, r.groupId, r.point)).toList();

  @override
  Future<List<String>> groupsWithPending() async => _rows.where((r) => !r.uploaded).map((r) => r.groupId).toSet().toList();

  @override
  Future<void> markUploaded(List<int> ids) async {
    final set = ids.toSet();
    for (final r in _rows) {
      if (set.contains(r.id)) r.uploaded = true;
    }
  }

  @override
  Future<void> dropGroup(String groupId) async => _rows.removeWhere((r) => r.groupId == groupId);

  @override
  Future<void> prune({Duration keep = const Duration(days: 2)}) async {
    final cutoff = DateTime.now().millisecondsSinceEpoch - keep.inMilliseconds;
    _rows.removeWhere((r) => r.uploaded && r.point.ts < cutoff);
  }

  @override
  Future<void> flushBuffer() async {}
}

class _Row {
  final int id;
  final String groupId;
  final TrackPoint point;
  bool uploaded = false;
  _Row(this.id, this.groupId, this.point);
}
