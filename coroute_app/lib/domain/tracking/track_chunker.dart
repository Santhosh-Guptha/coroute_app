import 'geo_math.dart';
import 'track_point.dart';

/// A recorded point waiting in the phone's upload queue.
class QueuedPoint {
  final int id;
  final String groupId;
  final TrackPoint point;
  const QueuedPoint(this.id, this.groupId, this.point);
}

/// One upload unit, matching the gateway's TRACK chunk format
/// (gateway/src/tracks.js): encoded polyline + per-point offsets, speed and accuracy.
class TrackChunk {
  final int seq;
  final int startTs;
  final String enc;
  final List<int> t;
  final List<int> v;
  final List<int> acc;
  final List<int> ids;

  const TrackChunk({required this.seq, required this.startTs, required this.enc, required this.t, required this.v, required this.acc, required this.ids});

  Map<String, dynamic> toJson() => {'seq': seq, 'startTs': startTs, 'enc': enc, 't': t, 'v': v, 'acc': acc};
}

class TrackChunker {
  TrackChunker._();

  static const int maxPoints = 120;
  static const int maxSpanMs = 6 * 3600 * 1000;

  /// Splits queued points (oldest first) into chunks of at most [maxPoints].
  ///
  /// `seq` is derived from the first queue row id and the point count, so a
  /// retry of exactly the same chunk is recognised by the server as a
  /// duplicate, while a retry that has since grown gets a new seq (the server
  /// merges overlapping chunks by timestamp, so nothing is double counted).
  static List<TrackChunk> build(List<QueuedPoint> points, {int max = maxPoints}) {
    final chunks = <TrackChunk>[];
    var current = <QueuedPoint>[];
    void close() {
      if (current.isEmpty) return;
      final start = current.first.point.ts;
      chunks.add(TrackChunk(
        seq: current.first.id * 1000 + current.length,
        startTs: start,
        enc: GeoMath.encodePolyline(current.map((q) => (q.point.lat, q.point.lng))),
        t: current.map((q) => q.point.ts - start).toList(),
        v: current.map((q) => q.point.speedKmh.round().clamp(0, 300).toInt()).toList(),
        acc: current.map((q) => q.point.accuracyM.round().clamp(0, 5000).toInt()).toList(),
        ids: current.map((q) => q.id).toList(),
      ));
      current = <QueuedPoint>[];
    }

    for (final q in points) {
      if (current.isNotEmpty) {
        final start = current.first.point.ts;
        final last = current.last.point.ts;
        if (current.length >= max || q.point.ts < last || q.point.ts - start > maxSpanMs) close();
      }
      current.add(q);
    }
    close();
    return chunks;
  }
}
