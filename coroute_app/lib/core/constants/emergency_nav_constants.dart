/// In-app navigation to an emergency and accident warnings on the phone
/// (3.15 Rider Safety Network). Used by `EmergencyGuidance`.
class EmergencyNavConstants {
  EmergencyNavConstants._();

  /// Spoken once each while riding to an emergency ("Emergency location 2 kilometers away.").
  static const List<int> navThresholdsM = [5000, 2000, 1000, 500, 100];

  /// Spoken once each while approaching a reported accident on my way.
  static const List<int> hazardThresholdsM = [5000, 2000, 1000, 500];

  /// A threshold this close above the first distance counts as already passed (no speech right at the start).
  static const double thresholdHysteresisM = 50;

  /// A new route is asked for when the emergency point moved this far from where the route ends.
  static const double retargetMoveM = 200;

  /// A hazard this far behind me along the route is passed: removed and silent.
  static const double hazardPassedM = 100;

  /// Off the group route, a hazard counts as ahead only within this angle of my heading.
  static const double hazardHeadingDeg = 45;

  /// On the group route when within this distance of it (me and the hazard).
  static const double onRouteM = 300;

  /// Off route a hazard is passed when the straight distance grew this many fixes in a row after being this close.
  static const double hazardPassedNearM = 300;
  static const int hazardPassedGrowingFixes = 3;

  /// My heading is taken from two fixes at least this far apart.
  static const double headingMinMoveM = 15;

  /// Rough ETA with no route: straight distance times this detour factor at this speed.
  static const double straightDetourFactor = 1.4;
  static const double straightSpeedKmh = 40;

  /// The arrival question shows within this distance of the emergency (the server also asks at 100 m).
  static const double arrivalAskM = 100;
}
