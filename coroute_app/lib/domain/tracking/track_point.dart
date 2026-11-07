/// One GPS fix as recorded on the phone.
class TrackPoint {
  final int ts; // epoch ms
  final double lat;
  final double lng;
  final double speedKmh;
  final double accuracyM;

  /// 3.55 high-altitude care: GPS altitude in metres when the fix had one (null = unknown).
  /// Used on the phone only; not part of the stored or uploaded track.
  final double? altM;

  const TrackPoint({
    required this.ts,
    required this.lat,
    required this.lng,
    this.speedKmh = 0,
    this.accuracyM = 0,
    this.altM,
  });

  Map<String, dynamic> toJson() => {'ts': ts, 'lat': lat, 'lng': lng, 'v': speedKmh, 'acc': accuracyM};

  factory TrackPoint.fromJson(Map<String, dynamic> j) => TrackPoint(
        ts: (j['ts'] as num).toInt(),
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        speedKmh: (j['v'] as num?)?.toDouble() ?? 0,
        accuracyM: (j['acc'] as num?)?.toDouble() ?? 0,
      );
}
