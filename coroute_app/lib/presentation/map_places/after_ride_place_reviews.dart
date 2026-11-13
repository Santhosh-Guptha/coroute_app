import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/place_review_service.dart';
import '../../domain/places/place_dwell.dart';
import 'place_review_sheet.dart';
import 'place_style.dart';

/// 3.55 follow-up (owner approved): the place review question after the ride ends.
///
/// Places where the rider stayed long enough during the ride (the cockpit dwell rule) and did not
/// answer the cockpit question: at most 2, longest stay first, each with "Rate"; "Skip" ends it.
/// The caller passes [enabled] from the admin switches `placeReviews` and `reviewPrompt`. Shows
/// nothing when there is nothing to ask.
class AfterRidePlaceReviews extends StatelessWidget {
  const AfterRidePlaceReviews({super.key, required this.service, required this.enabled, this.onDone, this.rideId});

  final PlaceReviewService service;
  final bool enabled;

  /// Only the questions of this ride (its group id: the ride end screen, the trip report of that
  /// ride); null shows any stored ones (the next app open).
  final String? rideId;

  /// After "Skip" or once every place was rated (the sheet closes itself).
  final VoidCallback? onDone;

  static const String title = 'Rate places from your ride';
  static const String skipLabel = 'Skip';
  static const String rateLabel = 'Rate';

  /// "You stayed 25 min. A quick rating helps the next riders." (pure, for tests).
  static String subtitle(PlaceReviewPrompt p) => 'You stayed ${p.dwellMin} min. A quick rating helps the next riders.';

  /// Opens the question as a bottom sheet on [context] when there is something to ask. Closing it
  /// any other way counts as "Skip".
  static Future<void> show(BuildContext context, {required PlaceReviewService service, required bool enabled, String? rideId}) async {
    if (service.afterRidePrompts(enabled: enabled, rideId: rideId).isEmpty) return;
    var done = false;
    await showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: AppMotion.sheetStyleOf(context), // round 7: spring in, reduce-motion aware
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: AppTheme.card,
      constraints: const BoxConstraints(maxWidth: 600),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.s16, Space.s16, Space.s16, Space.s24),
        child: AfterRidePlaceReviews(
          service: service,
          enabled: enabled,
          rideId: rideId,
          onDone: () {
            done = true;
            Navigator.of(ctx).maybePop();
          },
        ),
      ),
    );
    if (!done) service.skipAfterRide(rideId: rideId);
  }

  Future<void> _rate(BuildContext context, PlaceReviewPrompt p) async {
    await showPlaceReviewSheet(context, place: p.place, service: service, dwellMin: p.dwellMin);
    service.answerAfterRide(p.placeId);
    if (service.afterRidePrompts(enabled: enabled, rideId: rideId).isEmpty) onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final list = service.afterRidePrompts(enabled: enabled, rideId: rideId);
        if (list.isEmpty) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(header: true, child: Text(title, style: AppText.title)),
            const SizedBox(height: Space.s8),
            for (final p in list)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.s8),
                child: Row(children: [
                  CircleAvatar(radius: 18, backgroundColor: p.place.category.color, child: Icon(p.place.category.icon, size: 20, color: Colors.white)),
                  const SizedBox(width: Space.s12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.place.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                      Text(subtitle(p), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: AppTheme.text2)),
                    ]),
                  ),
                  const SizedBox(width: Space.s8),
                  FilledButton.icon(
                    key: ValueKey('afterRideRate:${p.placeId}'),
                    onPressed: () => _rate(context, p),
                    icon: const Icon(Icons.star_rounded),
                    label: const Text(rateLabel),
                    style: FilledButton.styleFrom(minimumSize: const Size(96, 48), backgroundColor: AppTheme.brand),
                  ),
                ]),
              ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                key: const ValueKey('afterRideSkip'),
                onPressed: () {
                  service.skipAfterRide(rideId: rideId);
                  onDone?.call();
                },
                style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
                child: const Text(skipLabel),
              ),
            ),
          ],
        );
      },
    );
  }
}
