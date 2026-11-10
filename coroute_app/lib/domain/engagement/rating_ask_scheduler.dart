// 3.55 "Rate CoRoute": when the app may open Google Play's in-app review card on its own
// (docs/features_355/ratings_reviews.md). Pure Dart: no Flutter, no I/O.
//
// Google Play review policy, kept by design:
//  - No gating: the rider's trip rating, chips or note are NOT an input here. The app never asks
//    "Do you like CoRoute?" first, and every rider who reaches this point gets the same Play card.
//  - No incentive: nothing is offered for a rating.
// Owner rules (admin-configurable within hard limits, see RatingPromptRules):
//  - after the Nth completed ride without SOS / crash alarm (default 3rd),
//  - not within the cooldown of the last ask (default 30 days), at most 3 asks a year,
//  - never during a ride or right after it: only once the ride summary was closed, or at the next
//    app open when a finished ride is still waiting for its ask,
//  - never after a problem: a ride with SOS / crash alarm / failed SOS, a problem in the last days,
//    or an app session with many errors.
// The explicit "Rate CoRoute" rows (Settings, Profile) do not go through this and do not count.
import 'engagement_config.dart';

/// Where the app is when it considers asking.
enum RatingAskMoment {
  /// The after-ride wrap-up / ride summary was just closed.
  rideSummaryClosed,

  /// The app opened (home screen) with no ride running.
  appOpen,
}

enum RatingAskVerdict {
  ask,
  disabled,
  noStore,
  rideActive,
  emergencyActive,
  nothingPending,
  tooSoonAfterRide,
  problemRide,
  recentProblem,
  errorHeavySession,
  tooSoonAfterInstall,
  notEnoughRides,
  cooldown,
  yearlyCap,
}

class RatingAskInput {
  final int nowMs;
  final RatingPromptRules rules;
  final RatingAskMoment moment;

  /// Earlier automatic asks (ms since epoch), any order.
  final List<int> askedAtMs;

  /// Completed rides on this phone without SOS or crash alarm (the one that just ended included).
  final int cleanRides;

  /// A finished clean ride is waiting for its ask (set at the ride end, cleared once asked or
  /// after [RatingAskScheduler.pendingFor]). Needed for [RatingAskMoment.appOpen].
  final int pendingSinceMs;

  /// End of the latest ride (0: unknown).
  final int lastRideEndMs;

  /// The ride that just ended had an SOS, crash alarm or a failed SOS.
  final bool lastRideHadProblem;

  /// Latest problem of any kind (SOS, crash alarm, failed SOS) (0: none).
  final int lastProblemMs;

  /// Error entries in this app session's log.
  final int sessionErrors;

  final bool rideActive;
  final bool emergencyActive;
  final bool storeAvailable;

  /// First start of this install (0: unknown, treated as now).
  final int firstSeenMs;

  const RatingAskInput({
    required this.nowMs,
    this.rules = RatingPromptRules.defaults,
    required this.moment,
    this.askedAtMs = const [],
    required this.cleanRides,
    this.pendingSinceMs = 0,
    this.lastRideEndMs = 0,
    this.lastRideHadProblem = false,
    this.lastProblemMs = 0,
    this.sessionErrors = 0,
    this.rideActive = false,
    this.emergencyActive = false,
    this.storeAvailable = true,
    required this.firstSeenMs,
  });
}

class RatingAskScheduler {
  RatingAskScheduler._();

  static const Duration year = Duration(days: 365);

  /// No ask within this time of a ride ending (the rider is still parking, the summary is new).
  static const Duration quietAfterRide = Duration(seconds: 20);

  /// No ask for this long after any problem.
  static const Duration problemQuiet = Duration(days: 7);

  /// A ride waiting for its ask is forgotten after this long.
  static const Duration pendingFor = Duration(days: 3);

  /// Never in the first days after install.
  static const Duration installGrace = Duration(days: 2);

  /// An app session with this many error log entries is "error-heavy".
  static const int errorHeavy = 5;

  /// The first rule that stops the ask, or [RatingAskVerdict.ask].
  static RatingAskVerdict evaluate(RatingAskInput i) {
    final r = i.rules;
    if (!r.enabled) return RatingAskVerdict.disabled;
    if (!i.storeAvailable) return RatingAskVerdict.noStore;
    if (i.rideActive) return RatingAskVerdict.rideActive;
    if (i.emergencyActive) return RatingAskVerdict.emergencyActive;
    final pending = i.pendingSinceMs > 0 && i.nowMs - i.pendingSinceMs < pendingFor.inMilliseconds;
    if (!pending) return RatingAskVerdict.nothingPending;
    if (i.lastRideEndMs > 0 && i.nowMs - i.lastRideEndMs < quietAfterRide.inMilliseconds) return RatingAskVerdict.tooSoonAfterRide;
    if (i.lastRideHadProblem) return RatingAskVerdict.problemRide;
    if (i.lastProblemMs > 0 && i.nowMs - i.lastProblemMs < problemQuiet.inMilliseconds) return RatingAskVerdict.recentProblem;
    if (i.sessionErrors >= errorHeavy) return RatingAskVerdict.errorHeavySession;
    final firstSeen = i.firstSeenMs > 0 ? i.firstSeenMs : i.nowMs;
    if (i.nowMs - firstSeen < installGrace.inMilliseconds) return RatingAskVerdict.tooSoonAfterInstall;
    if (i.cleanRides < r.afterRides) return RatingAskVerdict.notEnoughRides;
    final asks = [for (final a in i.askedAtMs) if (a > 0 && a <= i.nowMs) a];
    final last = asks.isEmpty ? 0 : asks.reduce((a, b) => a > b ? a : b);
    final cooldownDays = r.cooldownDays < RatingPromptRules.minCooldownDays ? RatingPromptRules.minCooldownDays : r.cooldownDays;
    if (last > 0 && i.nowMs - last < Duration(days: cooldownDays).inMilliseconds) return RatingAskVerdict.cooldown;
    final cap = r.maxPerYear.clamp(1, RatingPromptRules.maxPerYearCap);
    final inYear = asks.where((a) => i.nowMs - a < year.inMilliseconds).length;
    if (inYear >= cap) return RatingAskVerdict.yearlyCap;
    return RatingAskVerdict.ask;
  }

  static bool shouldAsk(RatingAskInput i) => evaluate(i) == RatingAskVerdict.ask;

  /// The asks worth keeping (the last year), newest last, at most 10.
  static List<int> prune(List<int> asked, int nowMs) {
    final out = [for (final a in asked) if (a > 0 && nowMs - a < year.inMilliseconds) a]..sort();
    return out.length > 10 ? out.sublist(out.length - 10) : out;
  }

  /// The pending mark a finished ride leaves: the end time of a clean ride, 0 after a problem ride.
  static int pendingAfterRide({required bool hadProblem, required int endedAtMs}) => hadProblem ? 0 : endedAtMs;
}
