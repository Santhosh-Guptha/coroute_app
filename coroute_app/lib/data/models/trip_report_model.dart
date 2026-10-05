/// The trip report built by the gateway when a trip ends (convoys.report).
/// Holds statistics only, no coordinates.
class TripReportModel {
  final String name;
  final int startedAt;
  final int endedAt;
  final int durationMs;
  final int memberCount;
  final double distanceM;
  final int plannedStops;
  final int visitedStops;
  final int sos;
  final int arrived;
  final int speedLimitKmh;
  final int overspeedCount;
  final List<MemberReport> members;

  const TripReportModel({
    required this.name,
    required this.startedAt,
    required this.endedAt,
    required this.durationMs,
    required this.memberCount,
    required this.distanceM,
    required this.plannedStops,
    required this.visitedStops,
    required this.sos,
    required this.arrived,
    this.speedLimitKmh = 0,
    this.overspeedCount = 0,
    required this.members,
  });

  static int _i(dynamic v) => v is num ? v.toInt() : 0;
  static double _d(dynamic v) => v is num ? v.toDouble() : 0;

  factory TripReportModel.fromJson(Map<String, dynamic> j) {
    final g = j['group'] is Map ? Map<String, dynamic>.from(j['group'] as Map) : const <String, dynamic>{};
    final ms = (j['members'] as List? ?? const []).whereType<Map>().map((m) => MemberReport.fromJson(Map<String, dynamic>.from(m))).toList();
    return TripReportModel(
      name: g['name']?.toString() ?? '',
      startedAt: _i(g['startedAt']),
      endedAt: _i(g['endedAt']),
      durationMs: _i(g['durationMs']),
      memberCount: _i(g['members']),
      distanceM: _d(g['distanceM']),
      plannedStops: _i(g['plannedStops']),
      visitedStops: _i(g['visitedStops']),
      sos: _i(g['sos']),
      arrived: _i(g['arrived']),
      speedLimitKmh: _i(g['speedLimitKmh']),
      overspeedCount: _i(g['overspeedCount']),
      members: ms,
    );
  }
}

class MemberReport {
  final String userId;
  final String name;
  final String role;
  final String vehicleType;
  final bool trackAvailable;
  final int durationMs;
  final double distanceM;
  final int movingMs;
  final int restMs;
  final int stops;
  final int longestStopMs;
  final double avgMovingKmh;
  final double maxKmh;
  final int separatedMs;
  final int offRouteMs;
  final int offlineMs;
  final int sos;
  final int overspeedCount;
  final int overspeedMs;
  final double overspeedMaxKmh;
  final bool reachedDestination;

  /// When this rider's recorded route begins and ends, and the place names there.
  final int firstFixAt;
  final int lastFixAt;
  final String startPlace;
  final String endPlace;

  /// When the rider joined, for riders without an uploaded route.
  final int joinedAt;

  const MemberReport({
    required this.userId,
    required this.name,
    this.role = 'PACK',
    this.vehicleType = '',
    this.trackAvailable = false,
    this.durationMs = 0,
    this.distanceM = 0,
    this.movingMs = 0,
    this.restMs = 0,
    this.stops = 0,
    this.longestStopMs = 0,
    this.avgMovingKmh = 0,
    this.maxKmh = 0,
    this.separatedMs = 0,
    this.offRouteMs = 0,
    this.offlineMs = 0,
    this.sos = 0,
    this.overspeedCount = 0,
    this.overspeedMs = 0,
    this.overspeedMaxKmh = 0,
    this.reachedDestination = false,
    this.firstFixAt = 0,
    this.lastFixAt = 0,
    this.startPlace = '',
    this.endPlace = '',
    this.joinedAt = 0,
  });

  factory MemberReport.fromJson(Map<String, dynamic> j) {
    int i(String k) => j[k] is num ? (j[k] as num).toInt() : 0;
    double d(String k) => j[k] is num ? (j[k] as num).toDouble() : 0;
    return MemberReport(
      userId: j['userId']?.toString() ?? '',
      name: j['name']?.toString() ?? '',
      role: j['role']?.toString() ?? 'PACK',
      vehicleType: j['vehicleType']?.toString() ?? '',
      trackAvailable: j['trackAvailable'] == true,
      durationMs: i('durationMs'),
      distanceM: d('distanceM'),
      movingMs: i('movingMs'),
      restMs: i('restMs'),
      stops: i('stops'),
      longestStopMs: i('longestStopMs'),
      avgMovingKmh: d('avgMovingKmh'),
      maxKmh: d('maxKmh'),
      separatedMs: i('separatedMs'),
      offRouteMs: i('offRouteMs'),
      offlineMs: i('offlineMs'),
      sos: i('sos'),
      overspeedCount: i('overspeedCount'),
      overspeedMs: i('overspeedMs'),
      overspeedMaxKmh: d('overspeedMaxKmh'),
      reachedDestination: j['reachedDestination'] == true,
      firstFixAt: i('firstFixAt'),
      lastFixAt: i('lastFixAt'),
      startPlace: j['startPlace']?.toString() ?? '',
      endPlace: j['endPlace']?.toString() ?? '',
      joinedAt: i('joinedAt'),
    );
  }
}
