import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/models/road_hazard_telemetry.dart';

/// Floating high-contrast HUD pill for impending road hazard warnings (FEAT-02).
/// Displays prominent alert 300 meters before reaching a severe pothole or surface defect.
class RoadHazardHudPill extends StatelessWidget {
  final RoadHazardObservation hazard;
  final int distanceM;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;

  const RoadHazardHudPill({
    super.key,
    required this.hazard,
    this.distanceM = 300,
    this.onTap,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final amber = AppTheme.warnText;
    final isCritical = hazard.severity == RoadHazardSeverity.critical;
    final accent = isCritical ? AppTheme.sos : amber;
    final isConfident = hazard.confidence >= 0.80;

    final title = isCritical
        ? 'CAUTION: CRITICAL ROAD HAZARD'
        : (isConfident ? 'CAUTION: SEVERE ROAD HAZARD' : 'CAUTION: ROAD SURFACE ANOMALY');
    final subtitle = '$distanceM meters ahead';

    return Semantics(
      liveRegion: true,
      container: true,
      label: '$title, $subtitle.',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.lg),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 580, minHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.card,
              borderRadius: BorderRadius.circular(Radii.lg),
              border: Border.all(color: accent, width: 2),
              boxShadow: dsFloatingShadow(),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isCritical ? Icons.report_problem_rounded : Icons.warning_amber_rounded,
                    color: accent,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            subtitle,
                            style: TextStyle(
                              color: AppTheme.text,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (hazard.classification == RoadHazardClassification.pothole) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: AppTheme.soft,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'POTHOLE',
                                style: TextStyle(
                                  color: AppTheme.text2,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                if (onDismiss != null)
                  IconButton(
                    icon: Icon(Icons.close_rounded, color: AppTheme.text2, size: 22),
                    tooltip: 'Dismiss',
                    onPressed: onDismiss,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
