import 'network_wire.dart';
import 'rider_model.dart';
import 'sos_alert_model.dart';
import 'group_message_model.dart';
import 'route_model.dart';
import 'stop_point_model.dart';

class ConvoyModel {
  final String groupId;
  final String name;
  final String joinCode;
  final String createdByUserId;
  final String createdByUserName;
  final String startLocationName;
  final String destinationName;
  final double destinationLat;
  final double destinationLng;
  final String tripStatus; // 'PLANNING', 'STARTED', 'PAUSED', 'ENDED'
  final int createdAtEpochMs;
  final Map<String, RiderModel> riders;
  final List<SosAlertModel> activeAlerts;
  final List<GroupMessageModel> messages;
  final List<StopPointModel> stopPoints;
  final Map<String, String> pendingMembers;
  final Map<String, int> waitRequests;
  final double distanceThresholdMeters;
  final int stopThresholdSeconds;
  final bool voiceGuidanceEnabled;
  /// Group speed limit in km/h set by the lead; 0 means no limit.
  final int speedLimitKmh;
  final List<Map<String, double>> routeBreadcrumbs;
  final RouteModel? route;
  final Map<String, StopArrival> destinationArrivals;
  final double? startLat;
  final double? startLng;

  /// Social discovery (3.15, lead only): PRIVATE by default. Safety never depends on it.
  final GroupVisibility visibility;

  /// "Nearby group discovery": only works while [visibility] is public (both groups).
  final bool discovery;

  /// Group default for "Ask nearby riders to help our riders" (a rider's own switch wins).
  final bool assistDefault;

  /// 3.16: lower speed limit (km/h) within 1 km of planned stops, the start and the
  /// destination; 0 = off. Lead only.
  final int townLimitKmh;

  /// The rider the lead made the sweeper (3.16), if any.
  String? get sweeperId {
    for (final r in riders.values) {
      if (r.isSweeper) return r.userId;
    }
    return null;
  }

  /// The route line to draw and measure against: the planned route when there is one.
  List<(double, double)> get routeLine {
    final r = route;
    if (r != null && r.points.length >= 2) return r.points;
    return routeBreadcrumbs.where((p) => p['lat'] != null && p['lng'] != null).map((p) => (p['lat']!, p['lng']!)).toList();
  }

  /// Stops still on the plan (not suggested, not skipped), in order.
  List<StopPointModel> get plannedStops => (stopPoints.where((s) => s.isPlanned).toList()..sort((a, b) => a.orderIndex.compareTo(b.orderIndex)));

  /// Suggestions waiting for the lead.
  List<StopPointModel> get suggestedStops => stopPoints.where((s) => s.isSuggested).toList();

  ConvoyModel({
    required this.groupId,
    required this.name,
    required this.joinCode,
    required this.createdByUserId,
    required this.createdByUserName,
    this.startLocationName = '',
    this.destinationName = '',
    this.destinationLat = 0.0,
    this.destinationLng = 0.0,
    this.tripStatus = 'STARTED',
    required this.createdAtEpochMs,
    this.riders = const {},
    this.activeAlerts = const [],
    this.messages = const [],
    this.stopPoints = const [],
    this.pendingMembers = const {},
    this.waitRequests = const {},
    this.distanceThresholdMeters = 1000.0,
    this.stopThresholdSeconds = 180,
    this.voiceGuidanceEnabled = true,
    this.speedLimitKmh = 0,
    this.routeBreadcrumbs = const [],
    this.route,
    this.destinationArrivals = const {},
    this.startLat,
    this.startLng,
    this.visibility = GroupVisibility.private,
    this.discovery = false,
    this.assistDefault = true,
    this.townLimitKmh = 0,
  });

  ConvoyModel copyWith({
    String? groupId,
    String? name,
    String? joinCode,
    String? createdByUserId,
    String? createdByUserName,
    String? startLocationName,
    String? destinationName,
    double? destinationLat,
    double? destinationLng,
    String? tripStatus,
    int? createdAtEpochMs,
    Map<String, RiderModel>? riders,
    List<SosAlertModel>? activeAlerts,
    List<GroupMessageModel>? messages,
    List<StopPointModel>? stopPoints,
    Map<String, String>? pendingMembers,
    Map<String, int>? waitRequests,
    double? distanceThresholdMeters,
    int? stopThresholdSeconds,
    bool? voiceGuidanceEnabled,
    int? speedLimitKmh,
    List<Map<String, double>>? routeBreadcrumbs,
    RouteModel? route,
    bool clearRoute = false,
    Map<String, StopArrival>? destinationArrivals,
    double? startLat,
    double? startLng,
    GroupVisibility? visibility,
    bool? discovery,
    bool? assistDefault,
    int? townLimitKmh,
  }) {
    return ConvoyModel(
      groupId: groupId ?? this.groupId,
      name: name ?? this.name,
      joinCode: joinCode ?? this.joinCode,
      createdByUserId: createdByUserId ?? this.createdByUserId,
      createdByUserName: createdByUserName ?? this.createdByUserName,
      startLocationName: startLocationName ?? this.startLocationName,
      destinationName: destinationName ?? this.destinationName,
      destinationLat: destinationLat ?? this.destinationLat,
      destinationLng: destinationLng ?? this.destinationLng,
      tripStatus: tripStatus ?? this.tripStatus,
      createdAtEpochMs: createdAtEpochMs ?? this.createdAtEpochMs,
      riders: riders ?? this.riders,
      activeAlerts: activeAlerts ?? this.activeAlerts,
      messages: messages ?? this.messages,
      stopPoints: stopPoints ?? this.stopPoints,
      pendingMembers: pendingMembers ?? this.pendingMembers,
      waitRequests: waitRequests ?? this.waitRequests,
      distanceThresholdMeters: distanceThresholdMeters ?? this.distanceThresholdMeters,
      stopThresholdSeconds: stopThresholdSeconds ?? this.stopThresholdSeconds,
      voiceGuidanceEnabled: voiceGuidanceEnabled ?? this.voiceGuidanceEnabled,
      speedLimitKmh: speedLimitKmh ?? this.speedLimitKmh,
      routeBreadcrumbs: routeBreadcrumbs ?? this.routeBreadcrumbs,
      route: clearRoute ? null : (route ?? this.route),
      destinationArrivals: destinationArrivals ?? this.destinationArrivals,
      startLat: startLat ?? this.startLat,
      startLng: startLng ?? this.startLng,
      visibility: visibility ?? this.visibility,
      discovery: discovery ?? this.discovery,
      assistDefault: assistDefault ?? this.assistDefault,
      townLimitKmh: townLimitKmh ?? this.townLimitKmh,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'groupId': groupId,
      'name': name,
      'joinCode': joinCode,
      'createdByUserId': createdByUserId,
      'createdByUserName': createdByUserName,
      'startLocationName': startLocationName,
      'destinationName': destinationName,
      'destinationLat': destinationLat,
      'destinationLng': destinationLng,
      'tripStatus': tripStatus,
      'createdAtEpochMs': createdAtEpochMs,
      'riders': riders.map((k, v) => MapEntry(k, v.toJson())),
      'activeAlerts': activeAlerts.map((e) => e.toJson()).toList(),
      'messages': messages.map((e) => e.toJson()).toList(),
      'stopPoints': stopPoints.map((e) => e.toJson()).toList(),
      'pendingMembers': pendingMembers,
      'waitRequests': waitRequests,
      'distanceThresholdMeters': distanceThresholdMeters,
      'stopThresholdSeconds': stopThresholdSeconds,
      'voiceGuidanceEnabled': voiceGuidanceEnabled,
      'speedLimitKmh': speedLimitKmh,
      'routeBreadcrumbs': routeBreadcrumbs,
      if (route != null) 'route': route!.toJson(),
      'destinationArrivals': destinationArrivals.map((k, v) => MapEntry(k, v.toJson())),
      if (startLat != null && startLng != null) 'start': {'lat': startLat, 'lng': startLng, 'name': startLocationName},
      'visibility': visibility.wire,
      'discovery': discovery,
      'assistDefault': assistDefault,
      'townLimitKmh': townLimitKmh,
    };
  }

  factory ConvoyModel.fromJson(Map<String, dynamic> json) {
    final rawRiders = json['riders'] as Map<dynamic, dynamic>? ?? {};
    final ridersMap = <String, RiderModel>{};
    rawRiders.forEach((k, v) {
      if (v is Map) {
        ridersMap[k.toString()] = RiderModel.fromJson(Map<String, dynamic>.from(v));
      }
    });

    final rawAlerts = json['activeAlerts'] as List<dynamic>? ?? [];
    final alertsList = rawAlerts
        .whereType<Map>()
        .map((e) => SosAlertModel.fromJson(Map<String, dynamic>.from(e)))
        .toList();

    final rawMessages = json['messages'] as List<dynamic>? ?? [];
    final messagesList = rawMessages
        .whereType<Map>()
        .map((e) => GroupMessageModel.fromJson(Map<String, dynamic>.from(e)))
        .toList();

    final rawStops = json['stopPoints'] as List<dynamic>? ?? [];
    final stopsList = rawStops
        .whereType<Map>()
        .map((e) => StopPointModel.fromJson(Map<String, dynamic>.from(e)))
        .toList();

    final rawPending = json['pendingMembers'] as Map<dynamic, dynamic>? ?? {};
    final pendingMap = <String, String>{};
    rawPending.forEach((k, v) => pendingMap[k.toString()] = v.toString());

    final rawWait = json['waitRequests'] as Map<dynamic, dynamic>? ?? {};
    final waitMap = <String, int>{};
    rawWait.forEach((k, v) => waitMap[k.toString()] = (v as num).toInt());

    final rawCrumbs = json['routeBreadcrumbs'] as List<dynamic>? ?? [];
    final breadcrumbsList = rawCrumbs
        .whereType<Map>()
        .map((e) => {
              'lat': (e['lat'] as num?)?.toDouble() ?? 0.0,
              'lng': (e['lng'] as num?)?.toDouble() ?? 0.0,
            })
        .toList();

    return ConvoyModel(
      groupId: json['groupId'] ?? '',
      name: json['name'] ?? '',
      joinCode: json['joinCode'] ?? '',
      createdByUserId: json['createdByUserId'] ?? '',
      createdByUserName: json['createdByUserName'] ?? '',
      startLocationName: json['startLocationName'] ?? '',
      destinationName: json['destinationName'] ?? '',
      destinationLat: (json['destinationLat'] as num?)?.toDouble() ?? 0.0,
      destinationLng: (json['destinationLng'] as num?)?.toDouble() ?? 0.0,
      tripStatus: json['tripStatus'] ?? 'STARTED',
      createdAtEpochMs: (json['createdAtEpochMs'] as num?)?.toInt() ?? 0,
      riders: ridersMap,
      activeAlerts: alertsList,
      messages: messagesList,
      stopPoints: stopsList,
      pendingMembers: pendingMap,
      waitRequests: waitMap,
      distanceThresholdMeters: (json['distanceThresholdMeters'] as num?)?.toDouble() ?? 1000.0,
      stopThresholdSeconds: (json['stopThresholdSeconds'] as num?)?.toInt() ?? 180,
      voiceGuidanceEnabled: json['voiceGuidanceEnabled'] ?? true,
      speedLimitKmh: (json['speedLimitKmh'] as num?)?.toInt() ?? 0,
      routeBreadcrumbs: breadcrumbsList,
      route: json['route'] is Map ? RouteModel.fromJson(Map<String, dynamic>.from(json['route'] as Map)) : null,
      destinationArrivals: StopArrival.mapFrom(json['destinationArrivals']),
      startLat: json['start'] is Map ? ((json['start'] as Map)['lat'] as num?)?.toDouble() : null,
      startLng: json['start'] is Map ? ((json['start'] as Map)['lng'] as num?)?.toDouble() : null,
      visibility: GroupVisibility.fromWire(json['visibility']?.toString()),
      discovery: json['discovery'] == true,
      assistDefault: json['assistDefault'] != false,
      townLimitKmh: (json['townLimitKmh'] as num?)?.toInt() ?? 0,
    );
  }
}
