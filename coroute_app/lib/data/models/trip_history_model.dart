class TripBreadcrumbPoint {
  final double lat;
  final double lng;
  final double speedKmh;
  final double heading;
  final int timestamp;

  TripBreadcrumbPoint({
    required this.lat,
    required this.lng,
    required this.speedKmh,
    required this.heading,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lng': lng,
        'speedKmh': speedKmh,
        'heading': heading,
        'timestamp': timestamp,
      };

  factory TripBreadcrumbPoint.fromJson(Map<String, dynamic> json) =>
      TripBreadcrumbPoint(
        lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
        lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
        speedKmh: (json['speedKmh'] as num?)?.toDouble() ?? 0.0,
        heading: (json['heading'] as num?)?.toDouble() ?? 0.0,
        timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      );
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
    );
  }
}
