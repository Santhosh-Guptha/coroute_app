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
  });

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
    };
  }

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
    );
  }
}
