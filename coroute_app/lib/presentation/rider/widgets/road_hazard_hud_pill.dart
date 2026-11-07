import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/models/road_hazard_telemetry.dart';

/// Floating high-contrast HUD pill for impending road hazard warnings.
/// Displays prominent alert 300 m before reaching a severe pothole or surface defect.
///
/// 3.55: titled by kind ("Pothole ahead", "Speed breaker ahead", "Rough road ahead"); a saved
/// report from earlier rides says "Reported by CoRoute riders" and offers "Fixed?" ([onFixed]).
class RoadHazardHudPill extends StatelessWidget {
  final RoadHazardObservation hazard;
  final int distanceM;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;

  /// Saved reports only: the rider says the spot is fixed / not there.
  final VoidCallback? onFixed;

  const RoadHazardHudPill({
    super.key,
    required this.hazard,
    this.distanceM = 300,
    this.onTap,
    this.onDismiss,
    this.onFixed,
  });

  /// "Pothole ahead", "Speed breaker ahead", "Rough road ahead", "Road hazard ahead".
  static String titleFor(RoadHazardObservation h) => switch (h.classification) {
        RoadHazardClassification.pothole || RoadHazardClassification.severeRidge => 'Pothole ahead',
        RoadHazardClassification.speedBreaker => 'Speed breaker ahead',
        RoadHazardClassification.roughRoad => 'Rough road ahead',
        RoadHazardClassification.transverseJoint => 'Road joint ahead',
        RoadHazardClassification.uncertainSurfaceAnomaly => 'Road hazard ahead',
      };

  @override
  Widget build(BuildContext context) {
    final amber = AppTheme.warnText;
    final isCritical = hazard.severity == RoadHazardSeverity.critical;
    final accent = isCritical ? AppTheme.sos : amber;
    final isConfident = hazard.confidence >= 0.80;

    // An older report without a kind: plain "Road hazard ahead", "Severe" when critical or confident.
    final legacy = hazard.classification == RoadHazardClassification.uncertainSurfaceAnomaly && !hazard.fromHistory;
    final plainTitle = legacy && (isCritical || isConfident) ? 'Severe road hazard ahead' : titleFor(hazard);
    final title = plainTitle.toUpperCase();
    final subtitle = hazard.fromHistory
        ? '$distanceM m ahead · Reported by CoRoute riders${hazard.reports > 1 ? ' (${hazard.reports})' : ''}'
        : '$distanceM m ahead';

    return Semantics(
      liveRegion: true,
      container: true,
      label: '$plainTitle, ${subtitle.replaceAll(' m ahead', ' metres ahead')}.',
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
                          Flexible(
                            child: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppTheme.text,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (hazard.fromHistory && onFixed != null)
                  Semantics(
                    button: true,
                    label: 'Report this spot as fixed',
                    excludeSemantics: true,
                    child: TextButton(
                      key: const ValueKey('roadHazardFixed'),
                      onPressed: onFixed,
                      style: TextButton.styleFrom(minimumSize: const Size(56, 48), padding: const EdgeInsets.symmetric(horizontal: 8)),
                      child: Text('Fixed?', style: TextStyle(color: AppTheme.accentText, fontWeight: FontWeight.w800)),
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
