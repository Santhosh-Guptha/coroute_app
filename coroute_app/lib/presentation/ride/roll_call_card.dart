import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../domain/group/roll_call.dart';
import '../../domain/ride/bike_markers.dart';
import '../../domain/ride/ride_facts.dart';
import '../widgets/feature_switch.dart';

/// 3.55 "Start and arrival roll call" (switch `rollCall`) in the ride sheet of a group ride:
/// "Joined" / "Not yet" during the first 15 minutes (until everyone has joined), then
/// "Arrived" / "On the way" once anyone has reached the destination. Informational only (no
/// taps needed). Built from the ride data already on the phone ([RollCall]).
class RollCallCard extends StatelessWidget {
  final ConvoyModel convoy;
  final int nowMs;
  const RollCallCard({super.key, required this.convoy, required this.nowMs});

  /// When this phone first saw each ride started (the ride model has no start time).
  static final Map<String, int> _startedSeen = <String, int>{};

  static int _startedAt(ConvoyModel c, int now) {
    if (c.tripStatus != 'STARTED' && c.tripStatus != 'PAUSED') return 0;
    if (_startedSeen.length > 20) _startedSeen.clear();
    // A ride created moments ago started now; an older one opened after a restart counts from its
    // creation (so a long ride never shows the start roll call again).
    return _startedSeen.putIfAbsent(c.groupId, () => c.createdAtEpochMs > 0 && now - c.createdAtEpochMs < RollCall.startWindow.inMilliseconds ? c.createdAtEpochMs : now);
  }

  static RollCallState stateFor(ConvoyModel c, int now) => RollCall.compute(
        riders: [for (final r in c.riders.values) inputFor(c, r)],
        nowMs: now,
        rideStartedAtMs: _startedAt(c, now),
        groupRide: c.hasGroupFeatures && !c.isSolo,
      );

  /// 3.55 pillion seat: a seated pillion is on their rider's bike, so they joined / arrived with
  /// the bike (listed by name, never "Not yet" / "On the way" apart from their rider).
  @visibleForTesting
  static RollCallInput inputFor(ConvoyModel c, RiderModel r) {
    final bike = BikeMarkerPlan.riderOf(r, c.riders);
    final arrived = c.destinationArrivals[r.userId]?.arrivedAt ?? 0;
    if (bike == null) {
      return RollCallInput(
        userId: r.userId,
        name: r.name,
        lastSeenMs: r.lastSeenEpochMs,
        hasPosition: RideFacts.hasPosition(r),
        arrivedAtMs: arrived,
      );
    }
    final bikeArrived = c.destinationArrivals[bike.userId]?.arrivedAt ?? 0;
    return RollCallInput(
      userId: r.userId,
      name: r.name,
      lastSeenMs: r.lastSeenEpochMs > bike.lastSeenEpochMs ? r.lastSeenEpochMs : bike.lastSeenEpochMs,
      hasPosition: RideFacts.hasPosition(r) || RideFacts.hasPosition(bike),
      arrivedAtMs: arrived > 0 ? arrived : bikeArrived,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!context.featureOn('rollCall')) return const SizedBox.shrink();
    final state = stateFor(convoy, nowMs);
    if (state.phase == RollCallPhase.none) return const SizedBox.shrink();
    final title = state.phase == RollCallPhase.start ? 'Start roll call' : 'Arrival roll call';
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s12),
      child: Semantics(
        container: true,
        label: '$title. ${state.summary}',
        child: Container(
          padding: const EdgeInsets.all(Space.s12),
          decoration: BoxDecoration(
            color: AppTheme.card,
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(state.phase == RollCallPhase.start ? Icons.how_to_reg_rounded : Icons.sports_score_rounded, size: 20, color: AppTheme.accentText),
                  const SizedBox(width: Space.s8),
                  Expanded(child: Text(title, style: AppText.label.copyWith(fontWeight: FontWeight.w700))),
                  Text(state.summary, style: AppText.caption),
                ],
              ),
              const SizedBox(height: Space.s8),
              for (final e in state.entries.take(12))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Icon(e.done ? Icons.check_circle_rounded : Icons.schedule_rounded, size: 18, color: e.done ? StatusColors.success : StatusColors.warning),
                      const SizedBox(width: Space.s8),
                      Expanded(child: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body)),
                      Text(e.label, style: AppText.caption.copyWith(color: e.done ? StatusColors.success : StatusColors.warning, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              if (state.entries.length > 12) Text('and ${state.entries.length - 12} more', style: AppText.caption),
            ],
          ),
        ),
      ),
    );
  }
}
