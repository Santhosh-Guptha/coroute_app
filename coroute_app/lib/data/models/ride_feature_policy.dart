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
    this.stretchAlertKm = 3,
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

  /// 3.55 group stretch alert: the lead is told past this along-route spread (km: 1, 2, 3 or 5).
  final int stretchAlertKm;
  static const List<int> stretchAlertChoices = [1, 2, 3, 5];
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
      stretchAlertKm: j['stretchAlertKm'] is int && stretchAlertChoices.contains(j['stretchAlertKm']) ? j['stretchAlertKm'] as int : 3,
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
    'stretchAlertKm': stretchAlertKm,
  };
}
