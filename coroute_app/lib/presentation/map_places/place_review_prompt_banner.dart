import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/place_review_service.dart';
import '../../domain/places/place_dwell.dart';
import 'place_review_sheet.dart';
import 'place_style.dart';

/// 3.55: the polite cockpit question after a while at a place (shown only when stopped):
/// "How was Sri Sai Dhaba?" / "You spent 25 min there. A quick rating helps the riders coming
/// after you." with "Rate" (opens the rating sheet) and "Not now".
class PlaceReviewPromptBanner extends StatelessWidget {
  const PlaceReviewPromptBanner({super.key, required this.prompt, required this.service});

  final PlaceReviewPrompt prompt;
  final PlaceReviewService service;

  /// "Rate": the question goes and the rating sheet opens.
  static Future<void> rate(BuildContext context, PlaceReviewService service, PlaceReviewPrompt prompt) async {
    service.dismissPrompt();
    await showPlaceReviewSheet(context, place: prompt.place, service: service, dwellMin: prompt.dwellMin);
  }

  @override
  Widget build(BuildContext context) {
    final p = prompt.place;
    return Semantics(
      container: true,
      label: '${prompt.title} ${prompt.message}',
      child: Material(
        color: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 580),
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
          decoration: BoxDecoration(
            color: AppTheme.card,
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(color: AppTheme.border, width: 2),
            boxShadow: dsFloatingShadow(),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(radius: 18, backgroundColor: p.category.color, child: Icon(p.category.icon, size: 20, color: Colors.white)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(prompt.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 16)),
                  const SizedBox(height: 2),
                  Text(prompt.message, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(color: AppTheme.text2)),
                ]),
              ),
            ]),
            const SizedBox(height: 6),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                key: const ValueKey('placePromptNotNow'),
                onPressed: service.dismissPrompt,
                style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
                child: const Text('Not now'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const ValueKey('placePromptRate'),
                onPressed: () => rate(context, service, prompt),
                icon: const Icon(Icons.star_rounded),
                label: const Text('Rate'),
                style: FilledButton.styleFrom(minimumSize: const Size(104, 48), backgroundColor: AppTheme.brand),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
