import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/review/review_prompt_policy.dart';

const int day = 86400000;
final int now = DateTime.utc(2026, 11, 7, 12).millisecondsSinceEpoch;

/// A good ride by a rider who installed 30 days ago and was never asked.
ReviewPromptInput good({
  int? firstSeenMs,
  int lastShownMs = 0,
  bool neverAsk = false,
  bool storeAvailable = true,
  double rideKm = 64,
  bool rideHadSos = false,
  bool rideHadCrashAlert = false,
  int? rating = 5,
  int completedRides = 1,
  bool emergencyActive = false,
  int lastEmergencyMs = 0,
}) =>
    ReviewPromptInput(
      nowMs: now,
      firstSeenMs: firstSeenMs ?? now - 30 * day,
      lastShownMs: lastShownMs,
      neverAsk: neverAsk,
      storeAvailable: storeAvailable,
      rideKm: rideKm,
      rideHadSos: rideHadSos,
      rideHadCrashAlert: rideHadCrashAlert,
      rating: rating,
      completedRides: completedRides,
      emergencyActive: emergencyActive,
      lastEmergencyMs: lastEmergencyMs,
    );

ReviewPromptReason eval(ReviewPromptInput i) => ReviewPromptPolicy.evaluate(i);

void main() {
  test('a good ride rated 4 or 5 shows the prompt', () {
    expect(eval(good(rating: 5)), ReviewPromptReason.show);
    expect(eval(good(rating: 4)), ReviewPromptReason.show);
    expect(ReviewPromptPolicy.shouldShow(good()), isTrue);
  });

  test('ride distance: at least 20 km', () {
    expect(eval(good(rideKm: 19.9)), ReviewPromptReason.rideTooShort);
    expect(eval(good(rideKm: 20)), ReviewPromptReason.show);
    expect(eval(good(rideKm: double.nan)), ReviewPromptReason.rideTooShort);
  });

  test('rating below 4 never shows, even after many rides', () {
    expect(eval(good(rating: 3)), ReviewPromptReason.lowRating);
    expect(eval(good(rating: 1, completedRides: 10)), ReviewPromptReason.lowRating);
  });

  test('not rated: from the 3rd completed ride', () {
    expect(eval(good(rating: null, completedRides: 2)), ReviewPromptReason.notEnoughRides);
    expect(eval(good(rating: null, completedRides: 3)), ReviewPromptReason.show);
    expect(eval(good(rating: 0, completedRides: 3)), ReviewPromptReason.show, reason: '0 = not rated');
  });

  test('a ride with an SOS or crash alert never shows', () {
    expect(eval(good(rideHadSos: true)), ReviewPromptReason.rideHadEmergency);
    expect(eval(good(rideHadCrashAlert: true)), ReviewPromptReason.rideHadEmergency);
  });

  test('never during or just after an emergency', () {
    expect(eval(good(emergencyActive: true)), ReviewPromptReason.emergencyActive);
    expect(eval(good(lastEmergencyMs: now - 2 * day)), ReviewPromptReason.recentEmergency);
    expect(eval(good(lastEmergencyMs: now - 4 * day)), ReviewPromptReason.show);
  });

  test('at most once every 120 days', () {
    expect(eval(good(lastShownMs: now - 119 * day)), ReviewPromptReason.askedRecently);
    expect(eval(good(lastShownMs: now - 120 * day)), ReviewPromptReason.show);
  });

  test('never in the first 2 days after install', () {
    expect(eval(good(firstSeenMs: now - day)), ReviewPromptReason.tooSoonAfterInstall);
    expect(eval(good(firstSeenMs: now - 2 * day + 1)), ReviewPromptReason.tooSoonAfterInstall);
    expect(eval(good(firstSeenMs: now - 2 * day)), ReviewPromptReason.show);
    expect(eval(good(firstSeenMs: 0)), ReviewPromptReason.tooSoonAfterInstall, reason: 'unknown install time counts as now');
  });

  test("Don't ask again and no store always win", () {
    expect(eval(good(neverAsk: true)), ReviewPromptReason.optedOut);
    expect(eval(good(storeAvailable: false)), ReviewPromptReason.noStore);
  });

  test('Play Store app link first, then the web page', () {
    final uris = ReviewPromptPolicy.playStoreUris('space.devmonks.coroute_app');
    expect(uris.map((u) => u.toString()), [
      'market://details?id=space.devmonks.coroute_app',
      'https://play.google.com/store/apps/details?id=space.devmonks.coroute_app',
    ]);
  });
}
