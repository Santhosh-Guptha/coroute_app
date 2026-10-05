/// One GPS fix as recorded on the phone.
class TrackPoint {
  final int ts; // epoch ms
  final double lat;
  final double lng;
  final double speedKmh;
  final double accuracyM;

  const TrackPoint({
    required this.ts,
    required this.lat,
    required this.lng,
    this.speedKmh = 0,
    this.accuracyM = 0,
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
