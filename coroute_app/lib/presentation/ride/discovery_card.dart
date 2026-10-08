import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/network_models.dart';
import '../../data/models/network_wire.dart';
import '../../domain/notify/relation.dart';

/// Words of a group encounter (social, approximate only: name, rider count,
/// rounded distance; never positions or members).
class DiscoveryTexts {
  DiscoveryTexts._();

  /// "Weekend Riders nearby".
  static String title(Encounter e) {
    final n = e.groupName.trim();
    return n.isEmpty ? 'A riding group nearby' : '$n nearby';
  }

  /// "6 riders, about 4.7 km".
  static String size(Encounter e) {
    final riders = e.riders == 1 ? '1 rider' : '${e.riders} riders';
    return '$riders, about ${Relation.distanceText(e.distanceM)}';
  }

  /// "Travelling on the same route" / "Approaching from the opposite direction" / ...
  static String how(Encounter e) {
    switch (e.type) {
      case EncounterType.sameDirection:
        return e.sameRoute ? 'Travelling on the same route' : 'Travelling the same way';
      case EncounterType.oppositeDirection:
        return 'Approaching from the opposite direction';
      case EncounterType.converging:
        return 'Joining your route ahead';
      case EncounterType.crossing:
        return 'Crossing your route ahead';
    }
  }

  /// "You may meet in about 3 min", or null.
  static String? meeting(Encounter e) {
    final s = e.meetingS;
    if (s == null || s <= 0) return null;
    final min = (s / 60).round();
    return min < 1 ? 'You may meet in under a minute' : 'You may meet in about ${formatDuration(Duration(minutes: min))}';
  }

  /// "Royal Riders waved".
  static String waved(Encounter e) {
    final n = e.groupName.trim();
    return n.isEmpty ? 'A riding group waved' : '$n waved';
  }
}

/// The small neutral card for another public riding group nearby. Never
/// shown during an emergency (the ride screen checks
/// `AlertArbiter.socialAllowed`). **View Group** opens a sheet with the
/// same approximate facts (no map position), **Wave** sends one wave (then
/// says "Waved"), **Ignore** hides it until the encounter changes.
class DiscoveryCard extends StatelessWidget {
  final Encounter encounter;
  final VoidCallback onView;
  final VoidCallback onWave;
  final VoidCallback onIgnore;

  const DiscoveryCard({super.key, required this.encounter, required this.onView, required this.onWave, required this.onIgnore});

  @override
  Widget build(BuildContext context) {
    final e = encounter;
    final meet = DiscoveryTexts.meeting(e);
    final Color info = StatusColors.info;
    final lines = <String>[DiscoveryTexts.size(e), DiscoveryTexts.how(e), ?meet];
    ButtonStyle flat() => TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: AppTheme.textPrimary,
          padding: const EdgeInsets.symmetric(horizontal: Space.s8),
        );
    return Semantics(
      container: true,
      label: [DiscoveryTexts.title(e), ...lines].join('. '),
      child: Material(
        color: AppTheme.slateCard,
        elevation: 1,
        shadowColor: AppTheme.shadow,
        shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: AppTheme.subtleBorder)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.s12, Space.s8, Space.s8, Space.s4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExcludeSemantics(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.groups_rounded, color: info, size: 22)),
                    const SizedBox(width: Space.s8),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(DiscoveryTexts.title(e), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                          Text(lines.join('. '), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.textSecondary)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: Space.s4,
                children: [
                  TextButton(style: flat(), onPressed: onView, child: const Text('View Group', maxLines: 1)),
                  TextButton(
                    style: flat(),
                    onPressed: e.iWaved ? null : onWave,
                    child: Text(e.iWaved ? 'Waved' : 'Wave', maxLines: 1),
                  ),
                  TextButton(style: flat(), onPressed: onIgnore, child: const Text('Ignore', maxLines: 1)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Royal Riders waved": one neutral line, shown for a few seconds.
class WavedLine extends StatelessWidget {
  final Encounter encounter;
  const WavedLine({super.key, required this.encounter});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Material(
        color: AppTheme.slateCard,
        shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: AppTheme.subtleBorder)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.s12, vertical: Space.s8),
            child: Row(
              children: [
                Icon(Icons.waving_hand_rounded, size: 20, color: StatusColors.info),
                const SizedBox(width: Space.s8),
                Expanded(child: Text(DiscoveryTexts.waved(encounter), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens "View Group": the group's name, rider count, rough distance and
/// how the groups move, plus Wave. No map position, no members.
Future<void> showDiscoverySheet(BuildContext context, Encounter e, {required VoidCallback onWave}) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    title: e.groupName.trim().isEmpty ? 'Riding group' : e.groupName.trim(),
    builder: (ctx) {
      final meet = DiscoveryTexts.meeting(e);
      Widget line(IconData icon, String text) => Padding(
            padding: const EdgeInsets.only(bottom: Space.s8),
            child: Row(
              children: [
                Icon(icon, size: 20, color: AppTheme.textSecondary),
                const SizedBox(width: Space.s8),
                Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body)),
              ],
            ),
          );
      return SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            line(Icons.groups_rounded, DiscoveryTexts.size(e)),
            line(Icons.alt_route_rounded, DiscoveryTexts.how(e)),
            if (meet != null) line(Icons.schedule_rounded, meet),
            Text('A public riding group that also chose to be seen. Only its name and rider count are shared, never positions.', style: AppText.caption),
            const SizedBox(height: Space.s16),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: e.iWaved
                  ? null
                  : () {
                      onWave();
                      Navigator.of(ctx).maybePop();
                    },
              icon: const Icon(Icons.waving_hand_rounded),
              label: Text(e.iWaved ? 'Waved' : 'Wave', maxLines: 1),
            ),
          ],
        ),
      );
    },
  );
}
