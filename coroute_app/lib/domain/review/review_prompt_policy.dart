/// When CoRoute may ask the rider for a store rating. Pure Dart, no I/O.
///
/// Only after a good, completed ride: at least [minRideKm], no SOS or crash
/// alert on it, and the rider either rated the trip [minRating]+ in the
/// post-trip feedback or has finished [minCompletedRides] rides. Never more
/// than once every [cooldown], never in the first [installGrace] after
/// install, never during or within [emergencyQuiet] of an emergency, never
/// after "Don't ask again", and never where there is no store to open.
library;

enum ReviewPromptReason {
  show,
  noStore,
  optedOut,
  tooSoonAfterInstall,
  askedRecently,
  emergencyActive,
  recentEmergency,
  rideHadEmergency,
  rideTooShort,
  lowRating,
  notEnoughRides,
}

class ReviewPromptInput {
  final int nowMs;

  /// First time this install was seen (0: unknown, treated as now).
  final int firstSeenMs;

  /// Last time the prompt was shown (0: never).
  final int lastShownMs;
  final bool neverAsk;

  /// A store page exists for this platform (Play Store on Android, a configured App Store URL on iOS).
  final bool storeAvailable;

  /// The ride that just finished.
  final double rideKm;
  final bool rideHadSos;
  final bool rideHadCrashAlert;

  /// The trip rating from the post-trip feedback (1..5), null when not rated.
  final int? rating;

  /// Completed rides on this phone, the one that just finished included.
  final int completedRides;

  /// An SOS, crash countdown or emergency screen is open right now.
  final bool emergencyActive;

  /// End of the latest ride with an SOS or crash alert (0: none).
  final int lastEmergencyMs;

  const ReviewPromptInput({
    required this.nowMs,
    required this.firstSeenMs,
    this.lastShownMs = 0,
    this.neverAsk = false,
    this.storeAvailable = true,
    required this.rideKm,
    this.rideHadSos = false,
    this.rideHadCrashAlert = false,
    this.rating,
    this.completedRides = 0,
    this.emergencyActive = false,
    this.lastEmergencyMs = 0,
  });
}

class ReviewPromptPolicy {
  ReviewPromptPolicy._();

  static const double minRideKm = 20;
  static const int minRating = 4;
  static const int minCompletedRides = 3;
  static const Duration cooldown = Duration(days: 120);
  static const Duration installGrace = Duration(days: 2);
  static const Duration emergencyQuiet = Duration(days: 3);

  /// The first rule that stops the prompt, or [ReviewPromptReason.show].
  static ReviewPromptReason evaluate(ReviewPromptInput i) {
    if (!i.storeAvailable) return ReviewPromptReason.noStore;
    if (i.neverAsk) return ReviewPromptReason.optedOut;
    final firstSeen = i.firstSeenMs > 0 ? i.firstSeenMs : i.nowMs;
    if (i.nowMs - firstSeen < installGrace.inMilliseconds) return ReviewPromptReason.tooSoonAfterInstall;
    if (i.lastShownMs > 0 && i.nowMs - i.lastShownMs < cooldown.inMilliseconds) return ReviewPromptReason.askedRecently;
    if (i.emergencyActive) return ReviewPromptReason.emergencyActive;
    if (i.rideHadSos || i.rideHadCrashAlert) return ReviewPromptReason.rideHadEmergency;
    if (i.lastEmergencyMs > 0 && i.nowMs - i.lastEmergencyMs < emergencyQuiet.inMilliseconds) return ReviewPromptReason.recentEmergency;
    if (!i.rideKm.isFinite || i.rideKm < minRideKm) return ReviewPromptReason.rideTooShort;
    final r = i.rating;
    if (r != null && r > 0) return r >= minRating ? ReviewPromptReason.show : ReviewPromptReason.lowRating;
    return i.completedRides >= minCompletedRides ? ReviewPromptReason.show : ReviewPromptReason.notEnoughRides;
  }

  static bool shouldShow(ReviewPromptInput i) => evaluate(i) == ReviewPromptReason.show;

  /// The Play Store app link first, then the web page (url_launcher tries them in order).
  static List<Uri> playStoreUris(String packageId) => [
        Uri.parse('market://details?id=$packageId'),
        Uri.parse('https://play.google.com/store/apps/details?id=$packageId'),
      ];
}
