import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../ui/ride_metric.dart';
import '../ui/ui_tokens.dart';

/// My speed against the group speed limit, as one small card. The ride
/// screen shows it only when the lead set a limit.
///
/// [heading], [batteryLevel] and [isCharging] are accepted so older callers
/// keep compiling; they are not shown any more (compass, heading and battery
/// were noise while riding; my battery is in the riders list).
class CockpitHud extends StatelessWidget {
  final double speedKmh;
  final double heading;
  final int batteryLevel;
  final bool isCharging;

  /// The group speed limit; 0 when the lead has not set one.
  final int speedLimitKmh;

  const CockpitHud({
    super.key,
    required this.speedKmh,
    this.heading = 0,
    this.batteryLevel = 100,
    this.isCharging = false,
    this.speedLimitKmh = 0,
  });

  /// The line under the number: "Over the 80 limit", "Limit 80" or "Speed".
  static String labelFor(double speedKmh, int limit) {
    if (limit <= 0) return 'Speed';
    return speedKmh > limit ? 'Over the $limit limit' : 'Limit $limit';
  }

  @override
  Widget build(BuildContext context) {
    final limit = speedLimitKmh;
    final over = limit > 0 && speedKmh > limit;
    final near = limit > 0 && !over && speedKmh > limit - 10;
    final Color? color = over ? AppTheme.speedWarning : (near ? StatusColors.warning : null);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.s12, vertical: Space.s8),
      decoration: BoxDecoration(
        color: AppTheme.slateCard,
        borderRadius: Radii.mdAll,
        border: Border.all(color: over ? AppTheme.speedWarning : AppTheme.subtleBorder),
      ),
      child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (over) ...[
              Icon(Icons.speed_rounded, size: 20, color: AppTheme.speedWarning),
              const SizedBox(width: Space.s8),
            ],
            Flexible(
              child: RideMetric(
                value: speedKmh.isFinite ? speedKmh.toStringAsFixed(0) : '0',
                unit: 'km/h',
                label: labelFor(speedKmh, limit),
                color: color,
              ),
            ),
          ],
      ),
    );
  }
}
