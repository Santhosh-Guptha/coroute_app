import 'package:flutter/foundation.dart';
import '../../domain/tracking/track_chunker.dart';
import '../local/track_queue.dart';
import 'api_client.dart';

/// Drains the on-phone point queue to the gateway
/// (`POST /api/convoys/:groupId/tracks`, up to 20 chunks per request).
///
/// Safe to call at any time and from anywhere: calls never overlap, a failed
/// request leaves the points queued for the next attempt, and a group the
/// server refuses (not a member, or the trip closed long ago) is dropped.
class TrackUploader {
  TrackUploader(this._api, this._queue);

  final ApiClient _api;
  final TrackQueue _queue;
  Future<int>? _running;

  static const int _chunksPerRequest = 20;

  /// Uploads pending points. Returns how many points the server accepted.
  Future<int> flush({String? onlyGroup}) {
    final running = _running;
    if (running != null) return running.then((_) => _flush(onlyGroup));
    final f = _flush(onlyGroup);
    _running = f;
    return f.whenComplete(() {
      if (identical(_running, f)) _running = null;
    });
  }

  Future<int> _flush(String? onlyGroup) async {
    if (!_api.hasToken) return 0;
    var uploaded = 0;
    final groups = onlyGroup != null ? [onlyGroup] : await _queue.groupsWithPending();
    for (final gid in groups) {
      for (var round = 0; round < 50; round++) {
        final pts = await _queue.pending(gid, limit: TrackChunker.maxPoints * _chunksPerRequest);
        if (pts.isEmpty) break;
        final chunks = TrackChunker.build(pts);
        try {
          final res = await _api.post('/convoys/$gid/tracks', {'chunks': chunks.map((c) => c.toJson()).toList()}, const Duration(seconds: 20));
          final acked = <int>{};
          if (res is Map) {
            for (final s in (res['acked'] as List? ?? const [])) {
              if (s is num) acked.add(s.toInt());
            }
            // Rejected chunks hold data the server will never accept: do not retry them forever.
            for (final r in (res['rejected'] as List? ?? const [])) {
              if (r is Map && r['seq'] is num) acked.add((r['seq'] as num).toInt());
            }
          }
          final done = <int>[];
          for (final c in chunks) {
            if (acked.contains(c.seq)) {
              done.addAll(c.ids);
              uploaded += c.ids.length;
            }
          }
          await _queue.markUploaded(done);
          if (done.isEmpty) break;
        } on ApiException catch (e) {
          if (e.statusCode == 403 || e.statusCode == 404 || e.statusCode == 410) {
            await _queue.dropGroup(gid);
          } else {
            debugPrint('track upload deferred: ${e.message}');
            return uploaded; // offline or server busy: try again later
          }
          break;
        }
        if (pts.length < TrackChunker.maxPoints * _chunksPerRequest) break;
      }
    }
    _queue.prune().ignore();
    return uploaded;
  }
}
