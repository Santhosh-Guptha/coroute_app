import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../domain/safety/ride_safety_summary.dart';

/// "Safety summary" on my own trip report (3.55 ride safety report, switch 'safetyReport'):
/// hard brakes, minutes over the limit, km after dark, breaks, tiredness, "Bike down?" checks
/// and road hazards felt. From this phone's own stats only; never uploaded or shared.
class RideSafetySummaryCard extends StatelessWidget {
  final RideSafetySummary summary;
  const RideSafetySummaryCard({super.key, required this.summary});

  static const String title = 'Safety summary';
  static const String hint = 'From your phone only. Only you can see this.';

  @override
  Widget build(BuildContext context) {
    final lines = summary.lines();
    return DsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.health_and_safety_outlined, size: 20, color: AppTheme.accentText),
              const SizedBox(width: Space.s8),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.s4),
          Text(hint, style: AppText.caption),
          const SizedBox(height: Space.s8),
          for (final (label, value) in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body)),
                  const SizedBox(width: Space.s8),
                  Flexible(
                    child: Text(
                      value,
                      textAlign: TextAlign.end,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
