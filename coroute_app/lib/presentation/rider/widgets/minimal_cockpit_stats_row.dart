import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/models/convoy_model.dart';
import '../../../data/models/rider_model.dart';
import '../../../domain/ride/ride_facts.dart';

/// Clean single-line live ride metrics displayed directly above the HOLD TO TALK bar.
///
/// Format matches the streamlined cockpit design:
/// - Left: "ETA 16:14 · 9.7 km left"
/// - Right: "Kiran 1.2 km ahead · [shield] Guardian on"
class MinimalCockpitStatsRow extends StatelessWidget {
  final ConvoyModel convoy;
  final RiderModel me;
  final RideSnapshot snap;
  final String eta;
  final bool guardianOn;
  final int now;
  final int? meshPeersCount;

  const MinimalCockpitStatsRow({
    super.key,
    required this.convoy,
    required this.me,
    required this.snap,
    required this.eta,
    required this.guardianOn,
    required this.now,
    this.meshPeersCount,
  });

  @override
  Widget build(BuildContext context) {
    final left = snap.remainingM;
    final riding = RideFacts.ridingCount(convoy.riders.values, nowMs: now);
    final total = convoy.riders.length;

    // Relative position calculation (e.g. "Kiran 1.2 km ahead" or "450 m behind")
    String? relativeText;
    if (total > 1) {
      final ladder = snap.ladder;
      LadderRung? nearest;
      for (final r in ladder) {
        if (r.isMe || r.fromMeM == null) continue;
        if (nearest == null || (r.fromMeM!.abs() < nearest.fromMeM!.abs())) {
          nearest = r;
        }
      }
      if (nearest != null && nearest.fromMeM != null) {
        final name = nearest.rider.name.split(' ').first;
        final d = formatDistanceRounded(nearest.fromMeM!.abs());
        final isAhead = nearest.ahead ?? (nearest.fromMeM! >= 0);
        relativeText = isAhead ? '$name $d ahead' : '$name $d behind';
      }
    }

    final rightGroupText = relativeText ?? (total > 1 ? '$riding/$total riding' : 'Solo ride');

    return Row(
      children: [
        // Left: ETA & Remaining Distance
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'ETA $eta',
                  style: AppText.label.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppTheme.text,
                    fontSize: 13,
                  ),
                ),
                if (left != null) ...[
                  TextSpan(
                    text: ' · ${formatDistanceRounded(left)} left',
                    style: AppText.caption.copyWith(
                      color: AppTheme.muted,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),

        // Right: Group relative position / spread & Guardian badge
        Flexible(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  rightGroupText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(
                    color: AppTheme.accentText,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                guardianOn ? Icons.verified_user_rounded : Icons.shield_outlined,
                size: 14,
                color: guardianOn ? AppTheme.accentText : AppTheme.muted,
              ),
              const SizedBox(width: 3),
              Text(
                guardianOn ? 'Guardian on' : 'Guardian off',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                  color: guardianOn ? AppTheme.accentText : AppTheme.muted,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              if (meshPeersCount != null && meshPeersCount! > 0) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.hub_outlined,
                  size: 13,
                  color: AppTheme.accentText,
                ),
                const SizedBox(width: 3),
                Text(
                  '$meshPeersCount mesh',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(
                    color: AppTheme.accentText,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
