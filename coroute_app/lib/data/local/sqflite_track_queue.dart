import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../../domain/tracking/track_chunker.dart';
import '../../domain/tracking/track_point.dart';
import 'track_queue.dart';

/// SQLite-backed [TrackQueue]. Inserts are buffered and written ten at a time
/// in one transaction, which keeps disk wake-ups (and battery use) low.
class SqfliteTrackQueue implements TrackQueue {
  SqfliteTrackQueue({this.bufferSize = 10});

  final int bufferSize;
  Database? _db;
  Future<Database>? _opening;
  final List<(String, TrackPoint)> _buffer = [];

  Future<Database> _open() {
    if (_db != null) return Future.value(_db!);
    return _opening ??= () async {
      final dir = await getDatabasesPath();
      final db = await openDatabase(
        p.join(dir, 'coroute_tracks.db'),
        version: 1,
        onCreate: (db, _) async {
          await db.execute('CREATE TABLE points (id INTEGER PRIMARY KEY AUTOINCREMENT, gid TEXT NOT NULL, ts INTEGER NOT NULL, '
              'lat REAL NOT NULL, lng REAL NOT NULL, v REAL NOT NULL, acc REAL NOT NULL, up INTEGER NOT NULL DEFAULT 0)');
          await db.execute('CREATE INDEX points_pending ON points (gid, up, id)');
        },
      );
      _db = db;
      return db;
    }();
  }

  @override
  Future<void> add(String groupId, TrackPoint point) async {
    _buffer.add((groupId, point));
    if (_buffer.length >= bufferSize) await flushBuffer();
  }

  @override
  Future<void> flushBuffer() async {
    if (_buffer.isEmpty) return;
    final rows = List<(String, TrackPoint)>.from(_buffer);
    _buffer.clear();
    try {
      final db = await _open();
      final batch = db.batch();
      for (final (gid, pt) in rows) {
        batch.insert('points', {'gid': gid, 'ts': pt.ts, 'lat': pt.lat, 'lng': pt.lng, 'v': pt.speedKmh, 'acc': pt.accuracyM});
      }
      await batch.commit(noResult: true);
    } catch (e) {
      debugPrint('track queue write note: $e');
      _buffer.insertAll(0, rows); // try again with the next write
    }
  }

  @override
  Future<List<QueuedPoint>> pending(String groupId, {int limit = 2400}) async {
    await flushBuffer();
    final db = await _open();
    final rows = await db.query('points', where: 'gid = ? AND up = 0', whereArgs: [groupId], orderBy: 'id ASC', limit: limit);
    return rows
        .map((r) => QueuedPoint(
              r['id'] as int,
              r['gid'] as String,
              TrackPoint(
                ts: r['ts'] as int,
                lat: (r['lat'] as num).toDouble(),
                lng: (r['lng'] as num).toDouble(),
                speedKmh: (r['v'] as num).toDouble(),
                accuracyM: (r['acc'] as num).toDouble(),
              ),
            ))
        .toList();
  }

  @override
  Future<int> countPending(String groupId) async {
    // Points still in the write buffer count too; the buffer is not flushed for this (no extra disk write).
    final buffered = _buffer.where((r) => r.$1 == groupId).length;
    try {
      final db = await _open();
      final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM points WHERE gid = ? AND up = 0', [groupId]);
      final n = rows.isEmpty ? 0 : ((rows.first['n'] as num?)?.toInt() ?? 0);
      return n + buffered;
    } catch (e) {
      debugPrint('track queue count note: $e');
      return buffered;
    }
  }

  @override
  Future<List<String>> groupsWithPending() async {
    await flushBuffer();
    final db = await _open();
    final rows = await db.rawQuery('SELECT DISTINCT gid FROM points WHERE up = 0');
    return rows.map((r) => r['gid'] as String).toList();
  }

  @override
  Future<void> markUploaded(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _open();
    for (var i = 0; i < ids.length; i += 500) {
      final part = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      await db.rawUpdate('UPDATE points SET up = 1 WHERE id IN (${List.filled(part.length, '?').join(',')})', part);
    }
  }

  @override
  Future<void> dropGroup(String groupId) async {
    _buffer.removeWhere((r) => r.$1 == groupId);
    final db = await _open();
    await db.delete('points', where: 'gid = ?', whereArgs: [groupId]);
  }

  @override
  Future<void> prune({Duration keep = const Duration(days: 2)}) async {
    final db = await _open();
    final cutoff = DateTime.now().millisecondsSinceEpoch - keep.inMilliseconds;
    await db.delete('points', where: 'up = 1 AND ts < ?', whereArgs: [cutoff]);
  }
}
