import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/local/review_prompt_store.dart';
import '../../data/local/ride_stats_store.dart';
import '../../data/models/ride_analytics_inputs.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/safety_service.dart';
import '../../data/services/trip_storage_service.dart';
import '../../domain/review/review_prompt_policy.dart';

enum ReviewPromptChoice { rate, notNow, never }

/// The friendly "Rate CoRoute" sheet, shown only when [ReviewPromptPolicy]
/// allows it (after a good ride, at most once every 120 days). Hooked after the
/// post-trip feedback sheet closes and when a trip report first opens.
class AppReviewPrompt {
  AppReviewPrompt._();

  static bool _busy = false;

  static const String title = 'Enjoying safer rides?';
  static const String message = 'Rate CoRoute on Google Play — it helps us build more safety features.';
  static const String messageAppStore = 'Rate CoRoute on the App Store — it helps us build more safety features.';

  /// The store links for this platform, tried in order; empty where there is none
  /// (iOS without a configured App Store URL, web, desktop): then the prompt is skipped.
  static List<Uri> storeUris() {
    if (kIsWeb) return const [];
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return ReviewPromptPolicy.playStoreUris(AppConstants.androidPackageId);
      case TargetPlatform.iOS:
        final url = AppConstants.iosAppStoreUrl.trim();
        final uri = url.isEmpty ? null : Uri.tryParse(url);
        return uri == null || uri.scheme != 'https' ? const [] : [uri];
      default:
        return const [];
    }
  }

  /// Checks the rules for the trip that just finished ([tripId] or its convoy
  /// [groupId]) and shows the sheet when they allow it. Never throws.
  static Future<void> maybeShowAfterRide(BuildContext context, {String tripId = '', String groupId = '', int? rating}) async {
    if (_busy || !context.mounted) return;
    _busy = true;
    try {
      final uris = storeUris();
      TripStorageService? trips;
      try {
        trips = context.read<TripStorageService>();
      } catch (_) {
        trips = null;
      }
      if (trips == null || uris.isEmpty) return;
      TripHistoryModel? trip;
      for (final t in trips.trips) {
        if ((tripId.isNotEmpty && t.tripId == tripId) || (groupId.isNotEmpty && t.groupId == groupId)) {
          trip = t;
          if (tripId.isEmpty || t.tripId == tripId) break;
        }
      }
      if (trip == null) return;
      final gid = groupId.isNotEmpty ? groupId : trip.groupId;
      final emergencyActive = _emergencyActive(context);
      final stored = await ReviewPromptStore.read();
      final stats = await RideStatsStore.loadAll();
      RideStats? mine;
      var lastEmergency = 0;
      for (final s in stats) {
        if (s.groupId == gid) mine = s;
        if (s.hadEmergency) {
          final at = s.endedAt > 0 ? s.endedAt : DateTime.now().millisecondsSinceEpoch;
          if (at > lastEmergency) lastEmergency = at;
        }
      }
      // Install time: the first start of this install (ReviewPromptStore.markFirstSeen in main).
      final firstSeen = stored.firstSeen;
      final now = DateTime.now().millisecondsSinceEpoch;
      final verdict = ReviewPromptPolicy.evaluate(ReviewPromptInput(
        nowMs: now,
        firstSeenMs: firstSeen,
        lastShownMs: stored.lastShown,
        neverAsk: stored.never,
        storeAvailable: uris.isNotEmpty,
        rideKm: RideAnalyticsInputs.kmOf(trip),
        rideHadSos: mine?.sos ?? false,
        rideHadCrashAlert: mine?.crashAlert ?? false,
        rating: rating,
        completedRides: trips.trips.length,
        emergencyActive: emergencyActive,
        lastEmergencyMs: lastEmergency,
      ));
      if (verdict != ReviewPromptReason.show || !context.mounted) return;
      // Not over another sheet or screen the rider opened meanwhile.
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      // Counted as asked before it opens: it never comes back sooner, whatever happens next.
      if (!await ReviewPromptStore.markShown(nowMs: now)) return;
      if (!context.mounted) return;
      final choice = await show(context, appStore: defaultTargetPlatform == TargetPlatform.iOS);
      if (choice == ReviewPromptChoice.never) await ReviewPromptStore.neverAskAgain();
      if (choice == ReviewPromptChoice.rate) await openStore(uris);
    } catch (_) {
      // Never in the way of the rider.
    } finally {
      _busy = false;
    }
  }

  static bool _emergencyActive(BuildContext context) {
    try {
      final safety = context.read<SafetyService>();
      if (safety.alarm != null) return true;
    } catch (_) {}
    try {
      final convoys = context.read<ConvoyService>();
      if (convoys.pendingSos != null || convoys.myOpenSosAlertId != null) return true;
    } catch (_) {}
    return false;
  }

  /// Opens the first link that works (the Play Store app, then the web page).
  static Future<bool> openStore(List<Uri> uris) async {
    for (final u in uris) {
      try {
        if (await launchUrl(u, mode: LaunchMode.externalApplication)) return true;
      } catch (_) {
        // No store app for market://: try the next link.
      }
    }
    return false;
  }

  static Future<ReviewPromptChoice?> show(BuildContext context, {bool appStore = false}) {
    return showAppSheet<ReviewPromptChoice>(
      context,
      builder: (ctx) => _ReviewPromptSheet(appStore: appStore),
    );
  }
}

class _ReviewPromptSheet extends StatelessWidget {
  final bool appStore;
  const _ReviewPromptSheet({required this.appStore});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.favorite_rounded, size: 40, color: AppTheme.accentText),
          const SizedBox(height: Space.s12),
          Semantics(
            header: true,
            child: Text(AppReviewPrompt.title, textAlign: TextAlign.center, style: AppText.title),
          ),
          const SizedBox(height: Space.s8),
          Text(appStore ? AppReviewPrompt.messageAppStore : AppReviewPrompt.message, textAlign: TextAlign.center, style: AppText.label),
          const SizedBox(height: Space.s24),
          DsButton(
            key: const Key('rate_prompt_rate'),
            label: appStore ? 'Rate on the App Store' : 'Rate on Google Play',
            icon: Icons.star_rounded,
            onPressed: () => Navigator.pop(context, ReviewPromptChoice.rate),
          ),
          const SizedBox(height: Space.s12),
          DsButton(
            key: const Key('rate_prompt_later'),
            label: 'Not now',
            tone: DsButtonTone.outline,
            onPressed: () => Navigator.pop(context, ReviewPromptChoice.notNow),
          ),
          const SizedBox(height: Space.s4),
          TextButton(
            key: const Key('rate_prompt_never'),
            onPressed: () => Navigator.pop(context, ReviewPromptChoice.never),
            child: Text("Don't ask again", style: AppText.label),
          ),
        ],
      ),
    );
  }
}
