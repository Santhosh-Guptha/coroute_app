/// 3.56 what the rider may host, as the gateway decided it (pure Dart).
///
/// The admin sets an access mode in the web admin (paid, free for everyone, free up to limits;
/// gateway `src/access_mode.js`). The app never learns the mode, a plan or a price: only these
/// capabilities, from `GET /api/me/capabilities` or `capabilities` in `GET /api/membership/my`, and
/// re-read on the `CAPABILITIES_CHANGED` socket event.
class RideCapabilities {
  const RideCapabilities({
    required this.gated,
    required this.canHostGroup,
    required this.maxRiders,
    this.groupFeatures,
    this.hostedRidesLeft,
    this.hostedRidesLimit,
    this.reason,
    this.version = 0,
  });

  /// False while nothing is gated (free for everyone): the app shows no plan status at all.
  final bool gated;

  /// The rider may start a group ride others can join.
  final bool canHostGroup;

  /// Riders in a ride the rider hosts, host included (1 = a solo ride).
  final int maxRiders;

  /// The group features of the rider's own group rides: null = every group feature, else the list of
  /// feature ids (feature switch ids such as `intercom`, `rideRoles`, `crewRides`).
  final List<String>? groupFeatures;

  /// Group rides left to host this month (free up to limits); null = no monthly limit.
  final int? hostedRidesLeft;
  final int? hostedRidesLimit;

  /// Why hosting is limited: `GROUP_PLAN_REQUIRED`, `HOSTED_RIDES_LIMIT`, or null.
  final String? reason;

  final int version;

  /// Before the server answered: what the app assumed before 3.56 (paid, solo for Community).
  static const RideCapabilities unknown = RideCapabilities(gated: true, canHostGroup: false, maxRiders: 1);

  /// Everything open (a server without payments).
  static const RideCapabilities open = RideCapabilities(gated: false, canHostGroup: true, maxRiders: 12);

  bool get allGroupFeatures => groupFeatures == null;

  /// A group feature in the rider's own group rides.
  bool allows(String featureId) => groupFeatures == null || !gatable.contains(featureId) || groupFeatures!.contains(featureId);

  /// The only features a free tier can leave out (gateway access_mode.js GATABLE_GROUP_FEATURES);
  /// safety features are never limited.
  static const Set<String> gatable = {
    'intercom', 'rideRoles', 'autoRoles', 'crewRides', 'groupFuel', 'regroupSuggest', 'publicRide', 'discovery', 'vehicleSwap',
  };

  factory RideCapabilities.fromJson(Map<String, dynamic> json) {
    final gf = json['groupFeatures'];
    int? optInt(Object? v) => v is num ? v.toInt() : null;
    return RideCapabilities(
      gated: json['gated'] != false,
      canHostGroup: json['canHostGroup'] == true,
      maxRiders: optInt(json['maxRiders']) ?? 1,
      groupFeatures: gf is List ? gf.map((e) => e.toString()).toList(growable: false) : null,
      hostedRidesLeft: optInt(json['hostedRidesLeft']),
      hostedRidesLimit: optInt(json['hostedRidesLimit']),
      reason: json['reason']?.toString(),
      version: optInt(json['version']) ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'gated': gated,
        'canHostGroup': canHostGroup,
        'maxRiders': maxRiders,
        'groupFeatures': groupFeatures ?? 'all',
        'hostedRidesLeft': hostedRidesLeft,
        'hostedRidesLimit': hostedRidesLimit,
        'reason': reason,
        'version': version,
      };
}
