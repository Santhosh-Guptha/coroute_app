import 'package:flutter/material.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../data/services/smart_airbag_bridge_service.dart';

/// A glove-friendly, high-contrast HUD pill displaying the live connection state,
/// armed/disarmed status, and battery level of a Bluetooth smart airbag vest.
class SmartAirbagHudPill extends StatelessWidget {
  const SmartAirbagHudPill({
    super.key,
    required this.connectionState,
    required this.telemetry,
    this.batteryLevel,
    this.onTap,
    this.onDismiss,
  });

  final AirbagConnectionState connectionState;
  final AirbagTelemetry telemetry;
  final int? batteryLevel;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final batteryPercent = batteryLevel ?? telemetry.batteryLevel;
    final isArmed = telemetry.isArmed;

    final (label, icon, color, bg) = switch (connectionState) {
      AirbagConnectionState.deployed => (
          '🚨 AIRBAG DEPLOYED',
          Icons.emergency_rounded,
          AppTheme.laserRed,
          AppTheme.card,
        ),
      AirbagConnectionState.fault => (
          '⚠️ AIRBAG FAULT',
          Icons.warning_amber_rounded,
          AppTheme.hyperAmber,
          AppTheme.card,
        ),
      AirbagConnectionState.connected => (
          isArmed
              ? (batteryPercent != null
                  ? '🦺 Airbag Vest Connected · Armed · $batteryPercent%'
                  : '🦺 Airbag Vest Connected · Armed')
              : (batteryPercent != null
                  ? '🦺 Airbag Vest Connected · Disarmed · $batteryPercent%'
                  : '🦺 Airbag Vest Connected · Disarmed'),
          isArmed ? Icons.shield_rounded : Icons.shield_outlined,
          isArmed ? AppTheme.neonCyan : AppTheme.hyperAmber,
          AppTheme.card,
        ),
      AirbagConnectionState.connecting => (
          'CONNECTING AIRBAG...',
          Icons.bluetooth_searching_rounded,
          AppTheme.textSecondary,
          AppTheme.card,
        ),
      AirbagConnectionState.scanning => (
          'SCANNING FOR VEST...',
          Icons.bluetooth_searching_rounded,
          AppTheme.textSecondary,
          AppTheme.card,
        ),
      AirbagConnectionState.disconnected => (
          'AIRBAG DISCONNECTED',
          Icons.bluetooth_disabled_rounded,
          AppTheme.textMuted,
          AppTheme.card,
        ),
    };

    final isCritical = connectionState == AirbagConnectionState.deployed;

    return Semantics(
      label: 'Airbag Vest Status: $label',
      container: true,
      excludeSemantics: true,
      button: onTap != null,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            constraints: const BoxConstraints(minHeight: 40, maxWidth: 360),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: bg.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isCritical
                    ? AppTheme.laserRed
                    : (connectionState == AirbagConnectionState.connected
                        ? color.withValues(alpha: 0.7)
                        : AppTheme.border),
                width: isCritical ? 2.0 : 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: isCritical
                      ? AppTheme.laserRed.withValues(alpha: 0.35)
                      : Colors.black.withValues(alpha: 0.25),
                  blurRadius: isCritical ? 12 : 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                      color: color,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (batteryPercent != null &&
                    connectionState == AirbagConnectionState.connected) ...[
                  const SizedBox(width: 8),
                  Icon(
                    batteryPercent > 20
                        ? Icons.battery_charging_full
                        : Icons.battery_alert_rounded,
                    size: 14,
                    color: batteryPercent > 20 ? color : AppTheme.hyperAmber,
                  ),
                ],
                if (onDismiss != null && !isCritical) ...[
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: onDismiss,
                    child: Icon(
                      Icons.close,
                      size: 14,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
