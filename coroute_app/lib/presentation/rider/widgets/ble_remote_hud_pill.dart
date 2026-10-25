import 'package:flutter/material.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../data/services/ble_remote_service.dart';

/// A glove-friendly, high-contrast HUD pill displaying the paired status
/// and battery level of a Bluetooth handlebar remote.
class BleRemoteHudPill extends StatelessWidget {
  const BleRemoteHudPill({
    super.key,
    required this.status,
    this.batteryPercent,
    this.lastGesture,
    this.onTap,
    this.onDismiss,
  });

  final BleRemoteStatus status;
  final int? batteryPercent;
  final BleRemoteGesture? lastGesture;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final (label, icon, color, bg) = switch (status) {
      BleRemoteStatus.paired => (
          batteryPercent != null ? 'REMOTE PAIRED · $batteryPercent%' : 'REMOTE PAIRED',
          Icons.bluetooth_connected,
          AppTheme.neonCyan,
          AppTheme.card,
        ),
      BleRemoteStatus.listening => (
          'REMOTE READY · TAP BAR',
          Icons.radio_button_checked,
          AppTheme.textSecondary,
          AppTheme.card,
        ),
      BleRemoteStatus.disconnected => (
          'REMOTE DISCONNECTED',
          Icons.bluetooth_disabled,
          AppTheme.textMuted,
          AppTheme.card,
        ),
    };

    return Semantics(
      label: 'Handlebar Remote Status: $label',
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
                color: status == BleRemoteStatus.paired
                    ? color.withValues(alpha: 0.6)
                    : AppTheme.border,
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 8,
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
                      letterSpacing: 0.8,
                      color: color,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (batteryPercent != null && status == BleRemoteStatus.paired) ...[
                  const SizedBox(width: 8),
                  Icon(
                    batteryPercent! > 20 ? Icons.battery_charging_full : Icons.battery_alert,
                    size: 14,
                    color: batteryPercent! > 20 ? color : AppTheme.hyperAmber,
                  ),
                ],
                if (onDismiss != null) ...[
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: onDismiss,
                    child: Icon(Icons.close, size: 14, color: AppTheme.textMuted),
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
