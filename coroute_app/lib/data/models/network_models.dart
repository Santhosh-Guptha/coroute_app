import 'medical_info.dart';
import 'network_wire.dart';

// Rider Safety Network and Rider Discovery Network models (3.15). Immutable,
// tolerant of missing or wrong fields (a bad field never drops a message).

double? _d(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
int? _i(Object? v) => v is num && v.isFinite ? v.toInt() : null;
String _s(Object? v) => v?.toString() ?? '';
bool _b(Object? v) => v == true;

/// A rider from another group who answered an emergency of my group. The original
/// group never gets the responder's user id or group: [rid] is a per-incident id.
class NetResponder {
  final String rid;
  final String name;
  final ResponderStatus status;
  final int? etaS;
  final double? distanceM;

  /// Position, only while on the way (accepted, en route, arriving).
  final double? lat;
  final double? lng;
  final int acceptedAt;
  final int arrivedAt;

  /// Why they stopped, for example NOT_FOUND ("Unable to locate"); '' otherwise.
  final String reason;

  /// 3.16: asked although far by road (straight-line close, road far); [etaS] and
  /// [distanceM] are then road values.
  final bool farByRoad;

  const NetResponder({
    required this.rid,
    required this.name,
    required this.status,
    this.etaS,
    this.distanceM,
    this.lat,
    this.lng,
    this.acceptedAt = 0,
    this.arrivedAt = 0,
    this.reason = '',
    this.farByRoad = false,
  });

  /// On the way or with the rider.
  bool get isActive => status.isActive;

  static NetResponder? fromJson(Object? json) {
    if (json is! Map) return null;
    final rid = _s(json['rid']);
    if (rid.isEmpty) return null;
    return NetResponder(
      rid: rid,
      name: _s(json['name']),
      status: ResponderStatus.fromWire(json['status']?.toString()) ?? ResponderStatus.requested,
      etaS: _i(json['etaS']),
      distanceM: _d(json['distanceM']),
      lat: _d(json['lat']),
      lng: _d(json['lng']),
      acceptedAt: _i(json['acceptedAt']) ?? 0,
      arrivedAt: _i(json['arrivedAt']) ?? 0,
      reason: _s(json['reason']),
      farByRoad: _b(json['farByRoad']),
    );
  }

  Map<String, dynamic> toJson() => {
        'rid': rid,
        'name': name,
        'status': status.wire,
        'etaS': ?etaS,
        'distanceM': ?distanceM,
        'lat': ?lat,
        'lng': ?lng,
        'acceptedAt': acceptedAt,
        'arrivedAt': arrivedAt,
        if (reason.isNotEmpty) 'reason': reason,
        if (farByRoad) 'farByRoad': true,
      };
}

/// A place near an emergency found by the server (3.16: the nearest hospital).
class NearbyPlace {
  final String name;
  final double lat;
  final double lng;
  final double distanceM;

  const NearbyPlace({required this.name, required this.lat, required this.lng, required this.distanceM});

  static NearbyPlace? fromJson(Object? json) {
    if (json is! Map) return null;
    final lat = _d(json['lat']), lng = _d(json['lng']);
    final name = _s(json['name']).trim();
    if (lat == null || lng == null || name.isEmpty) return null;
    return NearbyPlace(name: name, lat: lat, lng: lng, distanceM: _d(json['distanceM']) ?? 0);
  }

  Map<String, dynamic> toJson() => {'name': name, 'lat': lat, 'lng': lng, 'distanceM': distanceM};
}

/// A live emergency link this phone created (3.16). The token lives in memory only:
/// never persisted, never logged (the server keeps only its hash).
class LiveLink {
  final String token;
  final String url;

  /// Epoch ms.
  final int expiresAt;

  const LiveLink({required this.token, required this.url, required this.expiresAt});

  bool isValidAt(int nowMs) => token.isNotEmpty && expiresAt > nowMs;

  static LiveLink? fromJson(Object? json) {
    if (json is! Map) return null;
    final token = _s(json['token']);
    final url = _s(json['url']);
    final exp = _i(json['expiresAt']);
    if (token.isEmpty || url.isEmpty || exp == null) return null;
    return LiveLink(token: token, url: url, expiresAt: exp);
  }

  @override
  String toString() => 'LiveLink(expiresAt: $expiresAt)'; // never the token
}

/// The search for nearby riders for one emergency, as the rider's own group sees it.
class EmergencyNetwork {
  final NetworkState state;
  final int stage;
  final int notified;

  /// A rider from a nearby group reported they are at the scene (no identity).
  final bool onScene;
  final List<NetResponder> responders;

  const EmergencyNetwork({
    this.state = NetworkState.off,
    this.stage = 0,
    this.notified = 0,
    this.onScene = false,
    this.responders = const [],
  });

  /// The responder on the way or with the rider (accepted, en route, arriving, arrived), if any.
  NetResponder? get activeResponder {
    NetResponder? best;
    for (final r in responders) {
      if (!r.isActive) continue;
      // Someone already there beats someone on the way.
      if (best == null || (r.status == ResponderStatus.arrived && best.status != ResponderStatus.arrived)) best = r;
    }
    return best;
  }

  static EmergencyNetwork? fromJson(Object? json) {
    if (json is! Map) return null;
    final raw = json['responders'];
    return EmergencyNetwork(
      state: NetworkState.fromWire(json['state']?.toString()) ?? NetworkState.off,
      stage: _i(json['stage']) ?? 0,
      notified: _i(json['notified']) ?? 0,
      onScene: _b(json['onScene']),
      responders: raw is List ? [for (final r in raw) ?NetResponder.fromJson(r)] : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'state': state.wire,
        'stage': stage,
        'notified': notified,
        if (onScene) 'onScene': true,
        'responders': [for (final r in responders) r.toJson()],
      };
}

/// The nearest rider of my own group to an emergency (computed by the server, by road when it can).
class OwnNearest {
  final String userId;
  final String name;
  final int etaS;
  final double distanceM;

  /// True when measured along the route, false for a straight-line estimate.
  final bool routeBased;

  const OwnNearest({required this.userId, required this.name, required this.etaS, required this.distanceM, this.routeBased = false});

  static OwnNearest? fromJson(Object? json) {
    if (json is! Map) return null;
    final uid = _s(json['userId']);
    final eta = _i(json['etaS']);
    if (uid.isEmpty || eta == null) return null;
    return OwnNearest(
      userId: uid,
      name: _s(json['name']),
      etaS: eta,
      distanceM: _d(json['distanceM']) ?? 0,
      routeBased: _b(json['routeBased']),
    );
  }

  Map<String, dynamic> toJson() => {'userId': userId, 'name': name, 'etaS': etaS, 'distanceM': distanceM, 'routeBased': routeBased};
}

/// The rider in trouble, as a responder sees them after accepting (first name and vehicle only).
class AssistSubject {
  final String firstName;
  final String vehicleType;
  final String vehicleColor;

  const AssistSubject({this.firstName = '', this.vehicleType = '', this.vehicleColor = ''});

  static AssistSubject? fromJson(Object? json) {
    if (json is! Map) return null;
    final s = AssistSubject(firstName: _s(json['firstName']), vehicleType: _s(json['vehicleType']), vehicleColor: _s(json['vehicleColor']));
    return (s.firstName.isEmpty && s.vehicleType.isEmpty && s.vehicleColor.isEmpty) ? null : s;
  }
}

/// A request to help a rider of another group (ASSIST_REQUEST, then ASSIST_UPDATE).
/// Before I accept it carries only the emergency point and distances.
class AssistRequest {
  final String incidentId;
  final double lat;
  final double lng;
  final double distanceM;
  final bool aheadOnRoute;
  final double? routeDistanceM;
  final int? etaS;
  final bool fasterThanGroup;
  final EmergencySeverity severity;

  /// ACCIDENT or EMERGENCY.
  final String kind;
  final int reportedAt;
  final int lastUpdateAt;

  /// When this phone got it (epoch ms).
  final int receivedAt;
  final ResponderStatus myStatus;
  final EmergencyStatus? incidentStatus;

  /// After I accepted: first name and vehicle of the rider.
  final AssistSubject? subject;

  /// After I accepted, and only if the rider chose to share it with a responder.
  final MedicalInfo? medical;

  /// "Have you reached the rider?" (I am within about 100 m).
  final bool arrivalCheck;

  /// 3.16: asked although far by road (straight-line close, road far); [routeDistanceM]
  /// and [etaS] are then road values.
  final bool farByRoad;

  const AssistRequest({
    required this.incidentId,
    required this.lat,
    required this.lng,
    this.distanceM = 0,
    this.aheadOnRoute = false,
    this.routeDistanceM,
    this.etaS,
    this.fasterThanGroup = true,
    this.severity = EmergencySeverity.high,
    this.kind = 'ACCIDENT',
    this.reportedAt = 0,
    this.lastUpdateAt = 0,
    this.receivedAt = 0,
    this.myStatus = ResponderStatus.requested,
    this.incidentStatus,
    this.subject,
    this.medical,
    this.arrivalCheck = false,
    this.farByRoad = false,
  });

  /// I accepted and am on the way (accepted, en route, arriving).
  bool get accepted => myStatus.isGoing;

  /// An accident (not another kind of emergency).
  bool get isAccident => kind.toUpperCase() != 'EMERGENCY';

  /// ASSIST_REQUEST. Null without a valid incident id or position.
  static AssistRequest? fromJson(Object? json, {required int receivedAt}) {
    if (json is! Map) return null;
    final id = _s(json['incidentId']);
    final lat = _d(json['lat']), lng = _d(json['lng']);
    if (id.isEmpty || lat == null || lng == null) return null;
    final reported = _i(json['reportedAt']) ?? receivedAt;
    return AssistRequest(
      incidentId: id,
      lat: lat,
      lng: lng,
      distanceM: _d(json['distanceM']) ?? 0,
      aheadOnRoute: _b(json['aheadOnRoute']),
      routeDistanceM: _d(json['routeDistanceM']),
      etaS: _i(json['etaS']),
      fasterThanGroup: json['fasterThanGroup'] != false,
      severity: EmergencySeverity.fromWire(json['severity']?.toString()) ?? EmergencySeverity.high,
      kind: _s(json['kind']).isEmpty ? 'ACCIDENT' : _s(json['kind']).toUpperCase(),
      reportedAt: reported,
      lastUpdateAt: _i(json['lastUpdateAt']) ?? reported,
      receivedAt: receivedAt,
      myStatus: ResponderStatus.fromWire(json['myStatus']?.toString()) ?? ResponderStatus.requested,
      incidentStatus: EmergencyStatus.fromWire(json['incidentStatus']?.toString()),
      subject: AssistSubject.fromJson(json['subject']),
      medical: MedicalInfo.fromJson(json['medical']),
      arrivalCheck: _b(json['arrivalCheck']),
      farByRoad: _b(json['farByRoad']),
    );
  }

  /// Applies an ASSIST_UPDATE: only the fields it carries change.
  AssistRequest merge(Map<String, dynamic> u) {
    final lat = _d(u['lat']), lng = _d(u['lng']);
    return copyWith(
      lat: lat != null && lng != null ? lat : null,
      lng: lat != null && lng != null ? lng : null,
      lastUpdateAt: _i(u['lastUpdateAt']),
      etaS: _i(u['etaS']),
      distanceM: _d(u['distanceM']),
      myStatus: ResponderStatus.fromWire(u['myStatus']?.toString()),
      incidentStatus: EmergencyStatus.fromWire(u['incidentStatus']?.toString()),
      subject: AssistSubject.fromJson(u['subject']),
      medical: MedicalInfo.fromJson(u['medical']),
      arrivalCheck: u.containsKey('arrivalCheck') ? _b(u['arrivalCheck']) : null,
    );
  }

  AssistRequest copyWith({
    double? lat,
    double? lng,
    double? distanceM,
    bool? aheadOnRoute,
    double? routeDistanceM,
    int? etaS,
    int? lastUpdateAt,
    ResponderStatus? myStatus,
    EmergencyStatus? incidentStatus,
    AssistSubject? subject,
    MedicalInfo? medical,
    bool? arrivalCheck,
    bool? farByRoad,
  }) =>
      AssistRequest(
        incidentId: incidentId,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        distanceM: distanceM ?? this.distanceM,
        aheadOnRoute: aheadOnRoute ?? this.aheadOnRoute,
        routeDistanceM: routeDistanceM ?? this.routeDistanceM,
        etaS: etaS ?? this.etaS,
        fasterThanGroup: fasterThanGroup,
        severity: severity,
        kind: kind,
        reportedAt: reportedAt,
        lastUpdateAt: lastUpdateAt ?? this.lastUpdateAt,
        receivedAt: receivedAt,
        myStatus: myStatus ?? this.myStatus,
        incidentStatus: incidentStatus ?? this.incidentStatus,
        subject: subject ?? this.subject,
        medical: medical ?? this.medical,
        arrivalCheck: arrivalCheck ?? this.arrivalCheck,
        farByRoad: farByRoad ?? this.farByRoad,
      );
}

/// "Another nearby rider is responding to this emergency. No assistance is currently required."
class AssistNotice {
  final String incidentId;
  final AssistClosedReason reason;
  final int at;

  const AssistNotice({required this.incidentId, required this.reason, required this.at});
}

/// An accident reported ahead on my route (HAZARD). No identity, only the point.
class HazardWarning {
  final String hazardId;
  final double lat;
  final double lng;
  final HazardLevel level;

  /// Distance ahead along my route when the server sent it.
  final double? aheadM;
  final bool onRoute;
  final int reportedAt;
  final int receivedAt;

  const HazardWarning({
    required this.hazardId,
    required this.lat,
    required this.lng,
    this.level = HazardLevel.active,
    this.aheadM,
    this.onRoute = false,
    this.reportedAt = 0,
    this.receivedAt = 0,
  });

  static HazardWarning? fromJson(Object? json, {required int receivedAt}) {
    if (json is! Map) return null;
    final id = _s(json['hazardId']);
    final lat = _d(json['lat']), lng = _d(json['lng']);
    if (id.isEmpty || lat == null || lng == null) return null;
    return HazardWarning(
      hazardId: id,
      lat: lat,
      lng: lng,
      level: HazardLevel.fromWire(json['level']?.toString()) ?? HazardLevel.active,
      aheadM: _d(json['aheadM']),
      onRoute: _b(json['onRoute']),
      reportedAt: _i(json['reportedAt']) ?? receivedAt,
      receivedAt: receivedAt,
    );
  }
}

/// Another public riding group nearby (DISCOVERY). Approximate only: never positions or names of riders.
class Encounter {
  final String encounterId;
  final EncounterType type;
  final String groupName;
  final int riders;
  final double distanceM;
  final int? meetingS;
  final bool sameRoute;

  /// When this phone got the latest version (epoch ms).
  final int at;
  final bool iWaved;
  final int? theyWavedAt;

  const Encounter({
    required this.encounterId,
    required this.type,
    required this.groupName,
    this.riders = 0,
    this.distanceM = 0,
    this.meetingS,
    this.sameRoute = false,
    this.at = 0,
    this.iWaved = false,
    this.theyWavedAt,
  });

  /// The encounter type travels as `encounterType` (the message's own `type` is DISCOVERY);
  /// a payload object whose `type` is the encounter type is read too.
  static Encounter? fromJson(Object? json, {required int at}) {
    if (json is! Map) return null;
    final id = _s(json['encounterId']);
    final type = EncounterType.fromWire(json['encounterType']?.toString()) ?? EncounterType.fromWire(json['type']?.toString());
    if (id.isEmpty || type == null) return null;
    return Encounter(
      encounterId: id,
      type: type,
      groupName: _s(json['groupName']),
      riders: _i(json['riders']) ?? 0,
      distanceM: _d(json['distanceM']) ?? 0,
      meetingS: _i(json['meetingS']),
      sameRoute: _b(json['sameRoute']),
      at: at,
    );
  }

  Encounter copyWith({bool? iWaved, int? theyWavedAt}) => Encounter(
        encounterId: encounterId,
        type: type,
        groupName: groupName,
        riders: riders,
        distanceM: distanceM,
        meetingS: meetingS,
        sameRoute: sameRoute,
        at: at,
        iWaved: iWaved ?? this.iWaved,
        theyWavedAt: theyWavedAt ?? this.theyWavedAt,
      );
}
