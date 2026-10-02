import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../constants/telemetry_utils.dart';
import '../theme/app_theme.dart';

class CockpitHud extends StatelessWidget {
  final double speedKmh;
  final double heading;
  final int batteryLevel;
  final bool isCharging;

  const CockpitHud({
    super.key,
    required this.speedKmh,
    required this.heading,
    this.batteryLevel = 100,
    this.isCharging = false,
  });

  @override
  Widget build(BuildContext context) {
    final cardinal = TelemetryUtils.getCardinalDirection(heading);
    final speedCat = TelemetryUtils.getSpeedCategory(speedKmh);

    Color speedColor = AppTheme.neonCyan;
    if (speedKmh > 95) {
      speedColor = AppTheme.speedWarning;
    } else if (speedKmh > 60) {
      speedColor = AppTheme.hyperAmber;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.obsidianVoid.withOpacity(0.85),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.neonCyan.withOpacity(0.35), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 1. Digital Speedometer
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    speedKmh.toStringAsFixed(0),
                    style: TextStyle(
                      color: speedColor,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    'km/h',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Text(
                speedCat,
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),

          const SizedBox(width: 18),
          Container(height: 34, width: 1, color: AppTheme.subtleBorder),
          const SizedBox(width: 18),

          // 2. Analog Rotating Compass
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.rotate(
                angle: heading * (math.pi / 180.0),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.neonCyan.withOpacity(0.4), width: 1.5),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.navigation,
                      color: AppTheme.neonCyan,
                      size: 16,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${heading.round()}° $cardinal',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),

          const SizedBox(width: 18),
          Container(height: 34, width: 1, color: AppTheme.subtleBorder),
          const SizedBox(width: 18),

          // 3. Battery & Power Telemetry
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                children: [
                  Icon(
                    isCharging ? Icons.battery_charging_full : Icons.battery_full,
                    color: batteryLevel > 20 ? AppTheme.emeraldSafe : AppTheme.laserRed,
                    size: 16,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '$batteryLevel%',
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const Text(
                'Live Cockpit',
                style: TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
