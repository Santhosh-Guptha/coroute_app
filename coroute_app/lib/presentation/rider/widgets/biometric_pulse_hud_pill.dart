import 'package:flutter/material.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../data/services/biometric_safety_bridge.dart';

/// A glove-friendly, high-contrast HUD pill displaying the live pulse (BPM)
/// and cardiac trauma state from a paired smartwatch or BLE heart rate sensor.
class BiometricPulseHudPill extends StatelessWidget {
  const BiometricPulseHudPill({
    super.key,
    required this.snapshot,
    this.onTap,
    this.onDismiss,
  });

  final BiometricSnapshot snapshot;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    if (!snapshot.isConnected && snapshot.currentBpm == 0) {
      return const SizedBox.shrink();
    }

    final (label, icon, color, bg) = switch (snapshot.traumaLevel) {
      BiometricTraumaLevel.criticalTraumaLevel1 => (
          snapshot.currentBpm == 0 ? 'CRITICAL · 0 BPM' : 'TRAUMA L1 · ${snapshot.currentBpm} BPM',
          snapshot.currentBpm == 0 ? Icons.heart_broken_rounded : Icons.warning_amber_rounded,
          AppTheme.laserRed,
          AppTheme.card,
        ),
      BiometricTraumaLevel.elevatedTrauma => (
          'STRESS · ${snapshot.currentBpm} BPM',
          Icons.favorite_rounded,
          AppTheme.hyperAmber,
          AppTheme.card,
        ),
      BiometricTraumaLevel.stableTrauma => (
          'PULSE · ${snapshot.currentBpm} BPM',
          Icons.favorite_rounded,
          AppTheme.neonCyan,
          AppTheme.card,
        ),
      BiometricTraumaLevel.unverified => (
          snapshot.isConnected ? 'WATCH LINKED' : 'WATCH OFFLINE',
          Icons.watch_rounded,
          AppTheme.textMuted,
          AppTheme.card,
        ),
    };

    return Semantics(
      label: 'Rider Biometric Pulse: $label',
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
                color: snapshot.isConnected
                    ? color.withValues(alpha: 0.7)
                    : AppTheme.border,
                width: snapshot.isCritical ? 2.0 : 1.5,
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
                if (snapshot.source != BiometricSensorSource.none) ...[
                  const SizedBox(width: 6),
                  Text(
                    '· ${snapshot.source.wire.split('_').first}',
                    style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textMuted,
                    ),
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
