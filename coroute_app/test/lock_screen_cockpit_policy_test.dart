// Cockpit on the lock screen while riding (docs/features_355/lock_screen_cockpit.md): pure rules.
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/auth/session_policy.dart';
import 'package:coroute_app/domain/security/app_lock_policy.dart';
import 'package:coroute_app/domain/security/lock_screen_cockpit_policy.dart';

const _riding = RideSafetyState(rideActive: true);
const _convoy = RideSafetyState(inConvoy: true);
const _idle = RideSafetyState();

bool _over({RideSafetyState ride = _riding, bool signedIn = true, bool setting = true, bool front = true}) =>
    LockScreenCockpitPolicy.showOverKeyguard(ride: ride, signedIn: signedIn, settingOn: setting, cockpitInFront: front);

void main() {
  group('over the keyguard', () {
    test('only during a ride (solo or group), signed in, setting on, cockpit in front', () {
      expect(_over(), isTrue, reason: 'solo ride being recorded');
      expect(_over(ride: _convoy), isTrue, reason: 'group ride (convoy)');
    });

    test('never without a ride, after the ride ended, after sign-out or with the setting off', () {
      expect(_over(ride: _idle), isFalse, reason: 'no ride / ride ended');
      expect(_over(ride: const RideSafetyState(sosOrCountdown: true)), isFalse, reason: 'an SOS alone is not a ride');
      expect(_over(signedIn: false), isFalse, reason: 'signed out');
      expect(_over(setting: false), isFalse, reason: 'setting off');
      expect(_over(front: false), isFalse, reason: 'a private screen in front (or another tab)');
    });

    test('locked mode needs both: over the keyguard and the keyguard still locked', () {
      expect(LockScreenCockpitPolicy.lockedMode(overKeyguard: true, keyguardLocked: true), isTrue);
      expect(LockScreenCockpitPolicy.lockedMode(overKeyguard: true, keyguardLocked: false), isFalse);
      expect(LockScreenCockpitPolicy.lockedMode(overKeyguard: false, keyguardLocked: true), isFalse);
    });

    test('never fights the app lock: whenever the cockpit is over the keyguard, the app lock is exempt', () {
      for (final ride in [_riding, _convoy, _idle, const RideSafetyState(pendingEmergencyTexts: true)]) {
        for (final signedIn in [true, false]) {
          if (_over(ride: ride, signedIn: signedIn)) {
            expect(AppLockPolicy.exempt(ride), isTrue, reason: '$ride');
            expect(AppLockPolicy.stayLocked(locked: true, state: ride), isFalse);
          }
        }
      }
      // After the ride the app lock applies again (and the cockpit is gone from the lock screen).
      expect(_over(ride: _idle), isFalse);
      expect(AppLockPolicy.exempt(_idle), isFalse);
    });
  });

  group('allowed actions while locked', () {
    test('the live cockpit and the safety actions need no unlock', () {
      for (final a in [
        CockpitAction.viewCockpit,
        CockpitAction.sosHold,
        CockpitAction.imOk,
        CockpitAction.call112,
        CockpitAction.medicalId,
        CockpitAction.muteVoice,
        CockpitAction.crashCountdown,
        CockpitAction.othersSos,
        CockpitAction.chatPreview,
      ]) {
        expect(LockScreenCockpitPolicy.allowedWhileLocked(a), isTrue, reason: '$a');
        expect(LockScreenCockpitPolicy.needsUnlock(locked: true, action: a), isFalse, reason: '$a');
      }
    });

    test('anything that leaves the cockpit or shows private data needs the unlock', () {
      for (final a in [
        CockpitAction.openChat,
        CockpitAction.openProfile,
        CockpitAction.openSettings,
        CockpitAction.openRideHistory,
        CockpitAction.openClubs,
        CockpitAction.openAccount,
        CockpitAction.searchOrEditRoute,
        CockpitAction.endRide,
        CockpitAction.leaveRide,
        CockpitAction.openAdmin,
        CockpitAction.dialContact,
        CockpitAction.shareLiveLink,
        CockpitAction.shareInvite,
        CockpitAction.openOther,
      ]) {
        expect(LockScreenCockpitPolicy.needsUnlock(locked: true, action: a), isTrue, reason: '$a');
        expect(LockScreenCockpitPolicy.needsUnlock(locked: false, action: a), isFalse, reason: 'unlocked: $a runs at once');
      }
    });

    test('every action is classified (a new one must be decided on purpose)', () {
      final allowed = CockpitAction.values.where(LockScreenCockpitPolicy.allowedWhileLocked).toSet();
      expect(allowed, LockScreenCockpitPolicy.withoutUnlock);
      expect(allowed.length, lessThan(CockpitAction.values.length));
    });

    test('screens: safety screens by name or inside an open SOS flow; others wait for the unlock', () {
      for (final n in LockScreenCockpitPolicy.allowedRouteNames) {
        expect(LockScreenCockpitPolicy.routeWhileLocked(routeName: n, safetyFlowOpen: false), LockedRouteDecision.allowed);
      }
      expect(LockScreenCockpitPolicy.routeWhileLocked(routeName: null, safetyFlowOpen: true), LockedRouteDecision.allowed);
      expect(LockScreenCockpitPolicy.routeWhileLocked(routeName: null, safetyFlowOpen: false), LockedRouteDecision.needsUnlock);
      expect(LockScreenCockpitPolicy.routeWhileLocked(routeName: 'settings', safetyFlowOpen: false), LockedRouteDecision.needsUnlock);
    });

    test('the unlock is asked at once only for the rider\'s own tap', () {
      const t = 1700000000000;
      expect(LockScreenCockpitPolicy.askUnlockAtOnce(nowMs: t, lastTapMs: t - 500), isTrue);
      expect(LockScreenCockpitPolicy.askUnlockAtOnce(nowMs: t, lastTapMs: t - 2000), isTrue);
      expect(LockScreenCockpitPolicy.askUnlockAtOnce(nowMs: t, lastTapMs: t - 2001), isFalse, reason: 'opened by itself');
      expect(LockScreenCockpitPolicy.askUnlockAtOnce(nowMs: t, lastTapMs: 0), isFalse);
    });

    test('Back never navigates while locked; end-of-ride prompts wait for the unlock', () {
      expect(LockScreenCockpitPolicy.backNavigates(locked: true), isFalse);
      expect(LockScreenCockpitPolicy.backNavigates(locked: false), isTrue);
      expect(LockScreenCockpitPolicy.deferEndOfRidePrompt(locked: true), isTrue);
      expect(LockScreenCockpitPolicy.deferEndOfRidePrompt(locked: false), isFalse);
    });
  });

  group('group chat while locked', () {
    test('"New message from <name>" and no text', () {
      final locked = LockScreenCockpitPolicy.chatBanner(locked: true, senderName: 'Arjun', text: 'meet at the dhaba');
      expect(locked.title, 'New message from Arjun');
      expect(locked.message, isNull);
      expect(LockScreenCockpitPolicy.chatBanner(locked: true, senderName: ' ', text: 'x').title, 'New message from a rider');
    });

    test('unlocked: the name and the text as before', () {
      final open = LockScreenCockpitPolicy.chatBanner(locked: false, senderName: 'Arjun', text: 'meet at the dhaba');
      expect(open.title, 'Arjun');
      expect(open.message, 'meet at the dhaba');
      expect(LockScreenCockpitPolicy.chatBanner(locked: false, senderName: '', text: 'hi').title, 'Message');
    });
  });

  test('texts', () {
    expect(LockScreenCockpitPolicy.chipText, 'Locked: unlock to open more');
    expect(LockScreenCockpitPolicy.settingTitle, 'Show cockpit on lock screen while riding');
    expect(LockScreenCockpitPolicy.settingHint, contains('without unlocking'));
    expect(LockScreenCockpitPolicy.settingHint, contains('fingerprint or PIN'));
  });
}
