/// Lead-controlled group defaults. Rider consent and emergency handling stay independent.
class RideFeaturePolicy {
  const RideFeaturePolicy({
    this.essentialsEnabled = true,
    this.autoDiscovery = true,
    this.groupFuelEnabled = true,
    this.guardianEnabled = true,
    this.guardianRequirePin = false,
    this.guardianMaxHours = 72,
    this.notificationInsights = true,
    this.guardianStopMinutes = 15,
    this.guardianOfflineMinutes = 10,
    this.guardianDeviationMinutes = 5,
  });
  final bool essentialsEnabled,
      autoDiscovery,
      groupFuelEnabled,
      guardianEnabled,
      guardianRequirePin,
      notificationInsights;
  final int guardianMaxHours,
      guardianStopMinutes,
      guardianOfflineMinutes,
      guardianDeviationMinutes;
  factory RideFeaturePolicy.fromJson(dynamic value) {
    final j = value is Map ? value : const {};
    bool flag(String key, bool fallback) =>
        j[key] is bool ? j[key] as bool : fallback;
    int bounded(String key, int fallback, int min, int max) =>
        j[key] is int && j[key] >= min && j[key] <= max
        ? j[key] as int
        : fallback;
    return RideFeaturePolicy(
      essentialsEnabled: flag('essentialsEnabled', true),
      autoDiscovery: flag('autoDiscovery', true),
      groupFuelEnabled: flag('groupFuelEnabled', true),
      guardianEnabled: flag('guardianEnabled', true),
      guardianRequirePin: flag('guardianRequirePin', false),
      notificationInsights: flag('notificationInsights', true),
      guardianMaxHours: bounded('guardianMaxHours', 72, 1, 336),
      guardianStopMinutes: bounded('guardianStopMinutes', 15, 5, 120),
      guardianOfflineMinutes: bounded('guardianOfflineMinutes', 10, 2, 60),
      guardianDeviationMinutes: bounded('guardianDeviationMinutes', 5, 1, 30),
    );
  }
  Map<String, dynamic> toJson() => {
    'essentialsEnabled': essentialsEnabled,
    'autoDiscovery': autoDiscovery,
    'groupFuelEnabled': groupFuelEnabled,
    'guardianEnabled': guardianEnabled,
    'guardianRequirePin': guardianRequirePin,
    'guardianMaxHours': guardianMaxHours,
    'notificationInsights': notificationInsights,
    'guardianStopMinutes': guardianStopMinutes,
    'guardianOfflineMinutes': guardianOfflineMinutes,
    'guardianDeviationMinutes': guardianDeviationMinutes,
  };
}
