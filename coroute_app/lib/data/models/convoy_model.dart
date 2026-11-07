import 'network_wire.dart';
import 'ride_feature_policy.dart';
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
  final String? tripOwnerUserId;
  final String? tripHeadUserId;

  bool isTripOwner(String uid) => (tripOwnerUserId ?? createdByUserId) == uid;
  bool isTripHead(String uid) => (tripHeadUserId ?? tripOwnerUserId ?? createdByUserId) == uid;

  /// True when the trip has only 1 participant (solo trip / convoy.riders.length <= 1).
  bool get isSolo => riders.length <= 1;

  /// A SOLO ride: the host rides on Community (free), so the gateway gave it one seat. Talk,
  /// messages, the invite code, regroup and lead/sweep roles are group features and are hidden
  /// (the gateway refuses them with SOLO_RIDE); every safety feature stays. A group ride (seats 2+,
  /// or unknown from an older server) shows them to every rider in it, whatever their own plan.
  bool get isSoloRide => capacity == 1;

  /// The group features (talk, messages, invite, regroup, roles) belong to this ride.
  bool get hasGroupFeatures => !isSoloRide;

  /// Seats of this ride, host included: the host's membership seats, set by the gateway when the
  /// ride starts (and raised when the host upgrades). 0 when the gateway did not say (older server).
  final int capacity;

  /// Riders in the ride over its seats, e.g. "1/6"; only the count when the seats are unknown.
  String get riderCountLabel => capacity > 0 ? '${riders.length}/$capacity' : '${riders.length}';

  /// No seat is left for a new rider.
  bool get isFull => capacity > 0 && riders.length >= capacity;
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
  final RideFeaturePolicy featurePolicy;
  final Map<String, dynamic> featureAnalytics;

  /// 3.55: automatic riding roles (the front rider leads, the last one sweeps). Off unless the
  /// lead turned it on; the gateway moves the roles and tells the riders to change position.
  final bool autoRoles;

  /// The riding lead (front): the rider with role LEAD, else the creator (older rides).
  String? get ridingLeadId {
    for (final r in riders.values) {
      if (r.role == 'LEAD') return r.userId;
    }
    return riders.containsKey(createdByUserId) ? createdByUserId : null;
  }

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
    this.tripOwnerUserId,
    this.tripHeadUserId,
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
    this.featurePolicy = const RideFeaturePolicy(),
    this.featureAnalytics = const {},
    this.capacity = 0,
    this.autoRoles = false,
  });

  ConvoyModel copyWith({
    String? groupId,
    String? name,
    String? joinCode,
    String? createdByUserId,
    String? createdByUserName,
    String? tripOwnerUserId,
    String? tripHeadUserId,
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
    RideFeaturePolicy? featurePolicy,
    Map<String, dynamic>? featureAnalytics,
    int? capacity,
    bool? autoRoles,
  }) {
    return ConvoyModel(
      groupId: groupId ?? this.groupId,
      name: name ?? this.name,
      joinCode: joinCode ?? this.joinCode,
      createdByUserId: createdByUserId ?? this.createdByUserId,
      createdByUserName: createdByUserName ?? this.createdByUserName,
      tripOwnerUserId: tripOwnerUserId ?? this.tripOwnerUserId,
      tripHeadUserId: tripHeadUserId ?? this.tripHeadUserId,
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
      featurePolicy: featurePolicy ?? this.featurePolicy,
      featureAnalytics: featureAnalytics ?? this.featureAnalytics,
      capacity: capacity ?? this.capacity,
      autoRoles: autoRoles ?? this.autoRoles,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'groupId': groupId,
      'name': name,
      'joinCode': joinCode,
      'createdByUserId': createdByUserId,
      'createdByUserName': createdByUserName,
      if (tripOwnerUserId != null) 'tripOwnerUserId': tripOwnerUserId,
      if (tripHeadUserId != null) 'tripHeadUserId': tripHeadUserId,
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
      'featurePolicy': featurePolicy.toJson(),
      'featureAnalytics': featureAnalytics,
      if (capacity > 0) 'capacity': capacity,
      if (autoRoles) 'autoRoles': true,
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
      tripOwnerUserId: json['tripOwnerUserId']?.toString(),
      tripHeadUserId: json['tripHeadUserId']?.toString(),
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
      autoRoles: json['autoRoles'] == true,
      townLimitKmh: (json['townLimitKmh'] as num?)?.toInt() ?? 0,
      featurePolicy: RideFeaturePolicy.fromJson(json['featurePolicy']),
      featureAnalytics: json['featureAnalytics'] is Map ? Map<String, dynamic>.from(json['featureAnalytics']) : const {},
      capacity: (json['capacity'] as num?)?.toInt() ?? 0,
    );
  }
}
