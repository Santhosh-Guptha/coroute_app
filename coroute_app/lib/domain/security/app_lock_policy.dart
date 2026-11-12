/// Round 4: "Lock CoRoute with fingerprint or screen lock" (docs/features_355/sessions_and_security.md §10).
///
/// Pure rules, tested without a device:
///  * off by default; only when the phone has a secure lock screen (otherwise there is nothing to unlock with);
///  * locks on a cold start and after [AppLockPolicy.defaultDelay] (5 min, configurable) in the background;
///  * NEVER locks, and drops an existing lock at once, while a ride, a convoy, an SOS, a crash / rider-down
///    countdown or emergency texts are running (a rider must never fight a lock screen in an emergency);
///  * while locked, SOS, "Call 112" and the lock-screen Medical ID stay reachable without unlocking.
library;

import '../auth/session_policy.dart';

/// What the lock screen offers without unlocking.
enum LockedAction { unlock, sos, call112, medicalId }

class AppLockPolicy {
  AppLockPolicy._();

  static const Duration defaultDelay = Duration(minutes: 5);

  /// Delays offered in Settings (minutes); 0 = every time the app leaves the screen.
  static const List<int> delayChoices = [0, 1, 5, 15, 30];

  /// Safety first: nothing may be locked while any of these run.
  static bool exempt(RideSafetyState s) => s.rideActive || s.inConvoy || s.sosOrCountdown || s.pendingEmergencyTexts;

  /// The lock can work at all (switched on, a screen lock to unlock with, someone signed in).
  static bool armed({required bool enabled, required bool lockAvailable, required bool signedIn}) => enabled && lockAvailable && signedIn;

  /// Lock when the app starts from scratch.
  static bool lockOnColdStart({required bool enabled, required bool lockAvailable, required bool signedIn, required RideSafetyState state}) =>
      armed(enabled: enabled, lockAvailable: lockAvailable, signedIn: signedIn) && !exempt(state);

  /// Lock when the app comes back after [backgroundedAt] (null: it never went to the background).
  static bool lockOnResume({
    required bool enabled,
    required bool lockAvailable,
    required bool signedIn,
    required RideSafetyState state,
    required DateTime? backgroundedAt,
    required DateTime now,
    Duration delay = defaultDelay,
  }) {
    if (!armed(enabled: enabled, lockAvailable: lockAvailable, signedIn: signedIn) || exempt(state)) return false;
    if (backgroundedAt == null) return false;
    return !now.difference(backgroundedAt).isNegative && now.difference(backgroundedAt) >= delay;
  }

  /// An existing lock stays only while nothing safety related runs (a ride or SOS that starts unlocks at once).
  static bool stayLocked({required bool locked, required RideSafetyState state}) => locked && !exempt(state);

  /// Reachable from the lock screen without unlocking (the lock screen shows exactly these besides Unlock).
  static const Set<LockedAction> withoutUnlock = {LockedAction.sos, LockedAction.call112, LockedAction.medicalId};
  static bool allowedWhileLocked(LockedAction a) => withoutUnlock.contains(a);

  /// A delay in minutes from Settings, clamped to the offered range.
  static Duration delayOf(int? minutes) {
    final m = minutes ?? defaultDelay.inMinutes;
    if (m <= 0) return Duration.zero;
    return Duration(minutes: m > 30 ? 30 : m);
  }
}
