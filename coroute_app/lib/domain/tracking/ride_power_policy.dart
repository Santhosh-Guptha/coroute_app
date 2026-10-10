import '../../core/config/app_config.dart';
import 'battery_governor.dart';

/// Reduce radio work first. GPS and crash detection keep their existing
/// accuracy and sampling. Critical activity always retains normal cadence.
class RidePowerPolicy {
  bool conserving = false;
  final BatteryGovernor governor = BatteryGovernor();

  /// Battery governor operating stage.
  BatteryGovernorStage get stage => governor.stage;

  /// Hysteresis avoids switching profiles repeatedly around 15%.
  void updateBattery(int percent, {required bool charging}) {
    governor.updateBattery(percent, charging: charging);
    if (charging) {
      conserving = false;
      return;
    }
    if (percent < 0 || percent > 100) return;
    if (percent <= 15) conserving = true;
    if (percent >= 20) conserving = false;
  }

  Duration telemetryInterval({required bool moving, required bool lowData, required bool critical}) {
    if (critical) return AppConfig.telemetryMinInterval;
    if (!moving) return AppConfig.telemetryIdleInterval;
    return AppConfig.telemetryInterval(lowData || conserving);
  }

  Duration notificationInterval({required bool critical}) =>
      conserving && !critical ? const Duration(seconds: 20) : const Duration(seconds: 10);
}
