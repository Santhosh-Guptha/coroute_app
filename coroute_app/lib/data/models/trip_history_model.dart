import '../../domain/tracking/track_cleaner.dart';

class TripBreadcrumbPoint {
  final double lat;
  final double lng;
  final double speedKmh;
  final double heading;
  final int timestamp;

  /// A signal gap comes before this point: the line is cut here (JSON `gap`).
  final bool gapBefore;

  TripBreadcrumbPoint({
    required this.lat,
    required this.lng,
    required this.speedKmh,
    required this.heading,
    required this.timestamp,
    this.gapBefore = false,
  });

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lng': lng,
        'speedKmh': speedKmh,
        'heading': heading,
        'timestamp': timestamp,
        if (gapBefore) 'gap': true,
      };

  factory TripBreadcrumbPoint.fromJson(Map<String, dynamic> json) =>
      TripBreadcrumbPoint(
        lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
        lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
        speedKmh: (json['speedKmh'] as num?)?.toDouble() ?? 0.0,
        heading: (json['heading'] as num?)?.toDouble() ?? 0.0,
        timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
        gapBefore: json['gap'] == true,
      );

  /// The trail as the pieces that were really ridden: cut at every marked
  /// signal gap and at impossible jumps (older trails have no marks; they are
  /// simplified, so long straight lines between points are normal there and
  /// only a jump cuts). Points without a position (0, 0) are skipped.
  static List<List<TripBreadcrumbPoint>> pieces(List<TripBreadcrumbPoint> trail) {
    final out = <List<TripBreadcrumbPoint>>[];
    var cur = <TripBreadcrumbPoint>[];
    for (final p in trail) {
      if (p.lat == 0 && p.lng == 0) continue;
      if (cur.isNotEmpty) {
        final a = cur.last;
        final cut = p.gapBefore || (a.timestamp > 0 && p.timestamp > 0 && TrackRules.jumpBetween(a.lat, a.lng, a.timestamp, p.lat, p.lng, p.timestamp));
        if (cut) {
          out.add(cur);
          cur = <TripBreadcrumbPoint>[];
        }
      }
      cur.add(p);
    }
    if (cur.isNotEmpty) out.add(cur);
    return out;
  }
}

class TripHistoryModel {
  final String tripId;
  final String tripName;
  final String startLocationName;
  final String destinationName;
  final int startTimeEpochMs;
  final int endTimeEpochMs;
  final double totalDistanceKm;
  final double topSpeedKmh;
  final double avgSpeedKmh;
  final int riderCount;
  final int stopCount;
  final List<TripBreadcrumbPoint> breadcrumbTrail;
  final String userId;
  final String createdByUserName;

  /// The convoy this trip belongs to; such trips open the group report.
  final String groupId;
  final int movingMs;
  final int restMs;

  /// 'server': built from the recorded routes when the trip ended (exact).
  /// 'device': the phone's own record, kept until the server's arrives.
  final String source;

  /// The trip numbers this phone computed from its own recorded track (see
  /// TripStats.toJson), sent with the trip; null when it had no track.
  final Map<String, num>? clientStats;

  /// How many trail points the server holds for this trip. The trip list is synced without
  /// trails (data and memory on low-end phones); a trail is loaded when the trip is opened.
  final int trailPoints;

  /// The route exists on the server but is not on this phone yet.
  bool get trailOnServerOnly => breadcrumbTrail.isEmpty && trailPoints > 0;

  bool get hasReport => groupId.isNotEmpty;

  /// A convoy trip whose exact report has not reached this phone yet.
  bool get isEstimate => groupId.isNotEmpty && source != 'server';

  TripHistoryModel({
    required this.tripId,
    required this.tripName,
    this.startLocationName = '',
    this.destinationName = '',
    required this.startTimeEpochMs,
    required this.endTimeEpochMs,
    required this.totalDistanceKm,
    required this.topSpeedKmh,
    required this.avgSpeedKmh,
    this.riderCount = 1,
    this.stopCount = 0,
    this.breadcrumbTrail = const [],
    this.userId = '',
    this.createdByUserName = '',
    this.groupId = '',
    this.movingMs = 0,
    this.restMs = 0,
    this.source = 'device',
    this.clientStats,
    int? trailPoints,
  }) : trailPoints = trailPoints ?? breadcrumbTrail.length;

  int get durationMinutes {
    final diff = endTimeEpochMs - startTimeEpochMs;
    return (diff / (1000 * 60)).round();
  }

  Map<String, dynamic> toJson() {
    return {
      'tripId': tripId,
      'tripName': tripName,
      'startLocationName': startLocationName,
      'destinationName': destinationName,
      'startTimeEpochMs': startTimeEpochMs,
      'endTimeEpochMs': endTimeEpochMs,
      'totalDistanceKm': totalDistanceKm,
      'topSpeedKmh': topSpeedKmh,
      'avgSpeedKmh': avgSpeedKmh,
      'riderCount': riderCount,
      'stopCount': stopCount,
      'breadcrumbTrail': breadcrumbTrail.map((e) => e.toJson()).toList(),
      'userId': userId,
      'createdByUserName': createdByUserName,
      if (groupId.isNotEmpty) 'groupId': groupId,
      'source': source,
      'movingMs': movingMs,
      'restMs': restMs,
      'trailPoints': trailPoints,
      if (clientStats != null) 'clientStats': clientStats,
    };
  }

  /// What is kept on the phone for the history list: everything except the trail.
  Map<String, dynamic> toStorageJson() => {...toJson(), 'breadcrumbTrail': const <Map<String, dynamic>>[]};

  /// The same trip with its trail (loaded from the server or kept from memory).
  TripHistoryModel withTrail(List<TripBreadcrumbPoint> trail) => TripHistoryModel(
        tripId: tripId,
        tripName: tripName,
        startLocationName: startLocationName,
        destinationName: destinationName,
        startTimeEpochMs: startTimeEpochMs,
        endTimeEpochMs: endTimeEpochMs,
        totalDistanceKm: totalDistanceKm,
        topSpeedKmh: topSpeedKmh,
        avgSpeedKmh: avgSpeedKmh,
        riderCount: riderCount,
        stopCount: stopCount,
        breadcrumbTrail: trail,
        userId: userId,
        createdByUserName: createdByUserName,
        groupId: groupId,
        movingMs: movingMs,
        restMs: restMs,
        source: source,
        clientStats: clientStats,
        trailPoints: trail.isNotEmpty ? trail.length : trailPoints,
      );

  factory TripHistoryModel.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['breadcrumbTrail'] as List<dynamic>? ?? [];
    final points = rawPoints
        .whereType<Map<String, dynamic>>()
        .map((e) => TripBreadcrumbPoint.fromJson(e))
        .toList();

    return TripHistoryModel(
      tripId: json['tripId'] ?? '',
      tripName: json['tripName'] ?? '',
      startLocationName: json['startLocationName'] ?? '',
      destinationName: json['destinationName'] ?? '',
      startTimeEpochMs: (json['startTimeEpochMs'] as num?)?.toInt() ?? 0,
      endTimeEpochMs: (json['endTimeEpochMs'] as num?)?.toInt() ?? 0,
      totalDistanceKm: (json['totalDistanceKm'] as num?)?.toDouble() ?? 0.0,
      topSpeedKmh: (json['topSpeedKmh'] as num?)?.toDouble() ?? 0.0,
      avgSpeedKmh: (json['avgSpeedKmh'] as num?)?.toDouble() ?? 0.0,
      riderCount: (json['riderCount'] as num?)?.toInt() ?? 1,
      stopCount: (json['stopCount'] as num?)?.toInt() ?? 0,
      breadcrumbTrail: points,
      userId: json['userId'] ?? '',
      createdByUserName: json['createdByUserName'] ?? '',
      groupId: json['groupId']?.toString() ?? '',
      source: json['source']?.toString() == 'server' ? 'server' : 'device',
      movingMs: (json['movingMs'] as num?)?.toInt() ?? 0,
      restMs: (json['restMs'] as num?)?.toInt() ?? 0,
      trailPoints: (json['trailPoints'] as num?)?.toInt(),
      clientStats: json['clientStats'] is Map
          ? {
              for (final e in (json['clientStats'] as Map).entries)
                if (e.value is num) e.key.toString(): e.value as num,
            }
          : null,
    );
  }
}
