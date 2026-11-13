/// Cockpit on the lock screen while riding (docs/features_355/lock_screen_cockpit.md).
///
/// Pure rules, tested without a device (test/lock_screen_cockpit_policy_test.dart):
///  * MainActivity is shown over the keyguard (setShowWhenLocked) ONLY while a ride is on (solo or group), someone
///    is signed in, the rider's setting "Show cockpit on lock screen while riding" is on (default) and the cockpit
///    is the screen in front (or a safety screen opened from it, or a private screen waiting for the unlock).
///    Never with no ride, never after sign-out.
///  * Shown over a locked keyguard the app is in "locked mode": the live cockpit and the safety actions work,
///    everything that leaves the cockpit or shows private data asks for the phone's unlock first
///    (KeyguardManager.requestDismissKeyguard) and continues when the unlock succeeds.
///  * A ride that is on is exactly what keeps the fingerprint app lock away ([AppLockPolicy.exempt]), so the
///    locked cockpit and the app lock never cover each other; after the ride the app lock applies again.
library;

import '../auth/session_policy.dart';

/// What a rider can do from the cockpit, for the locked-mode check.
enum CockpitAction {
  // ---- Allowed over the keyguard (no unlock).
  /// The live cockpit itself: speed, navigation, ETA, group on the map, convoy status, alerts.
  viewCockpit,
  sosHold,
  imOk,
  call112,
  medicalId,
  muteVoice,

  /// Hands-free / hold-to-talk: audio only, the ride notification offers it on the lock screen too.
  talk,

  /// The crash countdown and another rider's SOS (they come to the rider, nothing private opens).
  crashCountdown,
  othersSos,

  /// "New message from `name`" (no text).
  chatPreview,

  // ---- Need the unlock.
  openChat,
  openProfile,
  openSettings,
  openRideHistory,
  openClubs,
  openAccount,
  searchOrEditRoute,
  endRide,
  leaveRide,
  openAdmin,

  /// Calling anyone but the emergency number (contacts, riders, helplines).
  dialContact,
  shareLiveLink,
  shareInvite,

  /// Any other screen, sheet or dialog opened from the cockpit.
  openOther,
}

/// What a newly opened screen (route) gets while the cockpit is locked.
enum LockedRouteDecision {
  /// A safety screen (SOS hold, crash alarm, the SOS sheet and its dialogs): shown at once.
  allowed,

  /// Private: covered until the phone is unlocked; removed again when the unlock is cancelled.
  needsUnlock,
}

class LockScreenCockpitPolicy {
  LockScreenCockpitPolicy._();

  // ---- Texts (short on purpose).
  static const String settingTitle = 'Show cockpit on lock screen while riding';
  static const String settingHint =
      'Your ride screen comes back when you wake the phone, without unlocking. Private things need your fingerprint or PIN.';
  static const String chipText = 'Locked: unlock to open more';
  static const String shieldTitle = 'Unlock to open this';
  static const String shieldBody = 'Private things need your fingerprint or PIN. Your ride keeps running.';
  static const String unlockLabel = 'Unlock';
  static const String backToRideLabel = 'Back to ride';
  static const String unlockFailed = 'Still locked. Your ride screen stays here.';

  /// Route names of the safety screens that open over the keyguard without unlocking.
  static const String routeSosHold = 'safety/sos_hold';
  static const String routeCrashAlarm = 'safety/crash_alarm';
  static const String routeEmergencySos = 'safety/emergency_sos';
  // Round 10 rescue beacon: the victim's beacon screen (bystander stop, Medical ID) and the responders'
  // finder are safety screens too.
  static const String routeRescueBeacon = 'safety/rescue_beacon';
  static const String routeRescueFinder = 'safety/rescue_finder';
  static const Set<String> allowedRouteNames = {routeSosHold, routeCrashAlarm, routeEmergencySos, routeRescueBeacon, routeRescueFinder};

  /// A tap this recent before a screen opens counts as the rider's own tap: the unlock is asked at once.
  /// Screens that open by themselves (no recent tap) are covered and wait for the rider.
  static const Duration userTapWindow = Duration(seconds: 2);

  static const Set<CockpitAction> withoutUnlock = {
    CockpitAction.viewCockpit,
    CockpitAction.sosHold,
    CockpitAction.imOk,
    CockpitAction.call112,
    CockpitAction.medicalId,
    CockpitAction.muteVoice,
    CockpitAction.talk,
    CockpitAction.crashCountdown,
    CockpitAction.othersSos,
    CockpitAction.chatPreview,
  };

  /// A ride (solo or group) is on: the same reading of [RideSafetyState] that keeps the app lock away.
  static bool rideOn(RideSafetyState s) => s.rideActive || s.inConvoy;

  /// Whether MainActivity may be shown over the keyguard right now.
  ///
  /// [cockpitInFront]: the ride screen is the visible screen of the app, or only safety screens / screens waiting
  /// for the unlock are above it. A private screen the rider opened after unlocking turns it off, so locking the
  /// phone there shows the normal keyguard.
  static bool showOverKeyguard({
    required RideSafetyState ride,
    required bool signedIn,
    required bool settingOn,
    required bool cockpitInFront,
  }) =>
      rideOn(ride) && signedIn && settingOn && cockpitInFront;

  /// Locked mode: shown over a keyguard that is still locked.
  static bool lockedMode({required bool overKeyguard, required bool keyguardLocked}) => overKeyguard && keyguardLocked;

  static bool allowedWhileLocked(CockpitAction a) => withoutUnlock.contains(a);

  /// The action must wait for the phone's unlock.
  static bool needsUnlock({required bool locked, required CockpitAction action}) => locked && !allowedWhileLocked(action);

  /// A screen opened while locked: safety screens by name, or anything opened while an SOS / crash screen is open
  /// (their own dialogs and sheets); everything else waits for the unlock.
  static LockedRouteDecision routeWhileLocked({required String? routeName, required bool safetyFlowOpen}) {
    if (routeName != null && allowedRouteNames.contains(routeName)) return LockedRouteDecision.allowed;
    if (safetyFlowOpen) return LockedRouteDecision.allowed;
    return LockedRouteDecision.needsUnlock;
  }

  /// Ask for the unlock at once only for the rider's own tap ([lastTapMs] within [userTapWindow] of [nowMs]).
  static bool askUnlockAtOnce({required int nowMs, required int lastTapMs}) =>
      lastTapMs > 0 && nowMs - lastTapMs >= 0 && nowMs - lastTapMs <= userTapWindow.inMilliseconds;

  /// The chat banner line. Locked: "New message from `name`" and no text (same rule as the lock-screen notification).
  static ({String title, String? message}) chatBanner({required bool locked, required String senderName, required String text}) {
    final name = senderName.trim().isEmpty ? 'a rider' : senderName.trim();
    if (locked) return (title: 'New message from $name', message: null);
    return (title: senderName.trim().isEmpty ? 'Message' : senderName.trim(), message: text);
  }

  /// 3.56 (round 6): calling from the locked cockpit. The ride safety cards, the incident banner, the
  /// safety card and the rider card all offer "Call"; before, they dialled straight from a locked phone.
  ///
  /// The rule, in one line: **a locked phone calls emergency services, and the rider's own emergency
  /// contact while the rider's own SOS or crash alarm is open; every other number waits for the unlock.**
  ///
  ///  * Public emergency lines ([emergencyNumbers]: 112 and the ambulance / police / highway lines):
  ///    always, like the phone's own lock screen. They reveal nothing about the rider.
  ///  * The rider's OWN emergency contact while the rider's OWN SOS / crash alarm is open
  ///    ([ownEmergencyOpen]): a hurt rider, or a bystander holding the phone, must reach the family
  ///    without a fingerprint. Outside an emergency the same number waits for the unlock, so a found
  ///    or stolen phone can not be used to ring the owner's family.
  ///  * Everything else (another rider, another rider's emergency contact, a place, a helpline that is
  ///    not a public emergency line) asks for the phone's unlock first and dials when it succeeds. The
  ///    numbers belong to other people; a locked phone must not hand them out or ring them.
  ///
  /// Not locked: never asks.
  static bool callNeedsUnlock({
    required bool locked,
    required String number,
    required List<String> emergencyNumbers,
    required String? ownEmergencyContact,
    required bool ownEmergencyOpen,
  }) {
    if (!locked) return false;
    final n = _digits(number);
    if (n.isEmpty) return true;
    for (final e in emergencyNumbers) {
      if (_digits(e) == n) return false;
    }
    if (ownEmergencyOpen && samePhone(number, ownEmergencyContact)) return false;
    return true;
  }

  /// Same subscriber number: compared on the last 10 digits ("+91 98765 43210" = "09876543210"), at
  /// least 7 digits on both sides (short codes are never "the same" as a contact).
  static bool samePhone(String? a, String? b) {
    final x = _digits(a ?? ''), y = _digits(b ?? '');
    if (x.length < 7 || y.length < 7) return false;
    String tail(String v) => v.length > 10 ? v.substring(v.length - 10) : v;
    return tail(x) == tail(y);
  }

  static String _digits(String v) => v.replaceAll(RegExp(r'[^0-9]'), '');

  /// Android Back while locked never navigates (it stays on the cockpit).
  static bool backNavigates({required bool locked}) => !locked;

  /// Wrap-up / review prompts after the ride wait until the phone is unlocked.
  static bool deferEndOfRidePrompt({required bool locked}) => locked;
}
