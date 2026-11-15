import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';

/// v3.60 meet first, in the cockpit while the group gathers: where to meet, how far I am, who is there, and for the
/// host / ride head "Start ride" (from the meeting point). Each rider's own route to the meeting point is on the map.
class GatheringCard extends StatelessWidget {
  final String placeName;
  final int arrived;
  final int total;
  final double? myDistanceM;
  final bool canStart;
  final VoidCallback? onStart;
  const GatheringCard({super.key, required this.placeName, required this.arrived, required this.total, this.myDistanceM, this.canStart = false, this.onStart});

  static String distanceLabel(double m) => m < 1000 ? '${m.round()} m away' : '${(m / 1000).toStringAsFixed(m < 10000 ? 1 : 0)} km away';

  @override
  Widget build(BuildContext context) {
    final here = myDistanceM != null && myDistanceM! <= 150;
    return Container(
      key: const Key('gathering_card'),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: AppTheme.card.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.brand.withValues(alpha: 0.7), width: 1.5),
        boxShadow: dsFloatingShadow(),
      ),
      child: Row(
        children: [
          Icon(Icons.flag_circle_rounded, color: AppTheme.accentText, size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(placeName.isEmpty ? 'Meeting point' : 'Meet at $placeName', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                Text(
                  [
                    '$arrived of $total there',
                    if (here) 'you are there' else if (myDistanceM != null) distanceLabel(myDistanceM!),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.label,
                ),
              ],
            ),
          ),
          if (canStart) ...[
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('gathering_start'),
              style: FilledButton.styleFrom(minimumSize: const Size(88, 48), backgroundColor: AppTheme.brand),
              onPressed: onStart,
              child: const Text('Start ride'),
            ),
          ],
        ],
      ),
    );
  }
}
