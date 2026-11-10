import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local/review_prompt_store.dart';
import '../../data/local/ride_stats_store.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/engagement_service.dart';
import '../../data/services/feature_flags_service.dart';
import '../../data/services/safety_service.dart';
import '../../data/services/trip_storage_service.dart';
import '../../domain/engagement/engagement_config.dart';
import '../../domain/engagement/rating_ask_scheduler.dart';

/// 3.55 "Rate CoRoute" asked by the app itself (docs/features_355/ratings_reviews.md).
///
/// Opens Google Play's own in-app review card (Play In-App Review API) when [RatingAskScheduler]
/// allows it: after the Nth clean ride, on the ride summary once it closed or at the next app open,
/// with a cooldown and a yearly cap from the admin's engagement config, never after a problem.
///
/// Google Play review policy: there is NO pre-question ("Enjoying CoRoute?") and the rider's trip
/// rating is not looked at, so every rider gets the same card (no gating); nothing is offered for a
/// rating (no incentive). The permanent "Rate CoRoute" rows are in Settings and Profile
/// (RateAndFeedback.rate) and do not count as asks.
class AppReviewPrompt {
  AppReviewPrompt._();

  static bool _busy = false;

  /// After the ride wrap-up / ride summary closed. Never throws.
  static Future<void> maybeAskAfterRide(BuildContext context) => _maybeAsk(context, RatingAskMoment.rideSummaryClosed);

  /// At app open (home screen), for a finished ride still waiting for its ask. Never throws.
  static Future<void> maybeAskAtAppOpen(BuildContext context) => _maybeAsk(context, RatingAskMoment.appOpen);

  static Future<void> _maybeAsk(BuildContext context, RatingAskMoment moment) async {
    if (_busy || !context.mounted) return;
    if (!FeatureFlagsService.on('reviewPrompt')) return; // 3.55 admin feature switch
    final svc = EngagementService.instance;
    if (svc == null) return;
    _busy = true;
    try {
      TripStorageService? trips;
      try {
        trips = context.read<TripStorageService>();
      } catch (_) {
        trips = null;
      }
      final rideActive = _rideActive(context);
      final emergencyActive = _emergencyActive(context);
      final st = await svc.askState();
      final stored = await ReviewPromptStore.read();
      // Completed rides on this phone without SOS or crash alarm.
      final stats = await RideStatsStore.loadAll();
      final emergencyGroups = {for (final s in stats) if (s.hadEmergency) s.groupId};
      final clean = trips == null ? 0 : trips.trips.where((t) => t.endTimeEpochMs > 0 && !emergencyGroups.contains(t.groupId)).length;
      final health = EngagementService.sessionHealth();
      final now = DateTime.now().millisecondsSinceEpoch;
      final rules = svc.config.ratingPrompt;
      final verdict = RatingAskScheduler.evaluate(RatingAskInput(
        nowMs: now,
        rules: stored.never ? const RatingPromptRules(enabled: false) : rules,
        moment: moment,
        askedAtMs: [...st.asks, if (stored.lastShown > 0) stored.lastShown],
        cleanRides: clean,
        pendingSinceMs: st.pendingSince,
        lastRideEndMs: st.lastRideEnd,
        lastRideHadProblem: st.lastRideProblem || health.safetyProblem,
        lastProblemMs: st.lastProblem,
        sessionErrors: health.errors,
        rideActive: rideActive,
        emergencyActive: emergencyActive,
        storeAvailable: EngagementService.storeUris().isNotEmpty,
        firstSeenMs: stored.firstSeen,
      ));
      if (verdict != RatingAskVerdict.ask || !context.mounted) return;
      // Not over another sheet or screen the rider opened meanwhile.
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      // Counted as asked before it opens: it never comes back sooner, whatever happens next.
      if (!await svc.markAsked(nowMs: now)) return;
      await EngagementService.launchInAppReview();
    } catch (_) {
      // Never in the way of the rider.
    } finally {
      _busy = false;
    }
  }

  static bool _rideActive(BuildContext context) {
    try {
      final c = context.read<ConvoyService>().activeConvoy;
      return c != null && (c.tripStatus == 'STARTED' || c.tripStatus == 'PAUSED');
    } catch (_) {
      return false;
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
}
