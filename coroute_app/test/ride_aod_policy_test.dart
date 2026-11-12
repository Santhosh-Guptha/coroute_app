// Ride AOD and the ride screen's idle rules (docs/features_355/lock_screen_cockpit.md §2a, §3).
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/tracking/screen_awake_policy.dart';

const int t0 = 1700000000000;

ScreenAwakeDecision decide({
  int now = t0,
  int lastTouch = t0,
  int parkedSince = 0,
  int battery = 80,
  bool charging = false,
  bool emergency = false,
  RideIdleMode idle = RideIdleMode.aod,
  KeepScreenOnMode keepOn = KeepScreenOnMode.whileMoving,
  int lastAlert = 0,
  int thermal = 0,
}) =>
    ScreenAwakePolicy.decide(
      riding: true,
      foreground: true,
      userKeepOn: true,
      nowMs: now,
      lastTouchMs: lastTouch,
      parkedSinceMs: parkedSince,
      batteryPercent: battery,
      charging: charging,
      emergencyOpen: emergency,
      idleMode: idle,
      keepOnMode: keepOn,
      lastAlertMs: lastAlert,
      thermalStatus: thermal,
    );

void main() {
  group('idle display after 30 s without a touch', () {
    test('Ride AOD (default): black view at very low brightness, screen kept on', () {
      final full = decide(now: t0 + 29999);
      expect(full.display, RideDisplay.full);
      expect(full.brightness, isNull);
      final aod = decide(now: t0 + 30000);
      expect(aod.display, RideDisplay.aod);
      expect(aod.keepOn, isTrue);
      expect(aod.brightness, ScreenAwakePolicy.aodBrightness);
      expect(aod.notice, isNull);
    });

    test('Dim: the cockpit at low brightness', () {
      final d = decide(now: t0 + 30000, idle: RideIdleMode.dim);
      expect(d.display, RideDisplay.dim);
      expect(d.keepOn, isTrue);
      expect(d.brightness, ScreenAwakePolicy.dimBrightness);
    });

    test('Let the screen sleep: keep-on released, the phone timeout takes over', () {
      final d = decide(now: t0 + 30000, idle: RideIdleMode.sleep);
      expect(d.display, RideDisplay.off);
      expect(d.keepOn, isFalse);
      expect(d.reason, ScreenAwakeReason.riding, reason: 'not a warning, the rider chose it');
    });

    test('a touch brings the full cockpit back and restarts the 30 s', () {
      expect(decide(now: t0 + 60000, lastTouch: t0 + 59000).display, RideDisplay.full);
      expect(decide(now: t0 + 89000, lastTouch: t0 + 59000).display, RideDisplay.aod);
    });

    test('settings ids round-trip, unknown ids fall back to the defaults', () {
      for (final m in RideIdleMode.values) {
        expect(RideIdleMode.fromId(m.id), m);
      }
      for (final m in KeepScreenOnMode.values) {
        expect(KeepScreenOnMode.fromId(m.id), m);
      }
      expect(RideIdleMode.fromId(null), RideIdleMode.aod);
      expect(RideIdleMode.fromId('weird'), RideIdleMode.aod);
      expect(KeepScreenOnMode.fromId(null), KeepScreenOnMode.whileMoving);
    });
  });

  group('alerts wake the full cockpit', () {
    test('a new alert (siren, off-route, regroup) counts like a touch', () {
      expect(decide(now: t0 + 40000).display, RideDisplay.aod);
      final woken = decide(now: t0 + 40000, lastAlert: t0 + 39000);
      expect(woken.display, RideDisplay.full);
      expect(woken.brightness, isNull, reason: 'normal brightness');
      expect(decide(now: t0 + 69000, lastAlert: t0 + 39000).display, RideDisplay.aod, reason: '30 s after the alert');
    });

    test('an open emergency (SOS of others, crash countdown) is always full, even with low battery or heat', () {
      final d = decide(now: t0 + 10 * 60000, parkedSince: t0, battery: 5, thermal: 5, emergency: true);
      expect(d.display, RideDisplay.full);
      expect(d.keepOn, isTrue);
    });
  });

  group('keep screen on', () {
    test('only while moving (default): sleeps after 2 min stopped, with the reason', () {
      expect(decide(now: t0 + 2 * 60000, parkedSince: t0, lastTouch: t0 + 2 * 60000).keepOn, isTrue, reason: 'exactly 2 min');
      final d = decide(now: t0 + 2 * 60000 + 1, parkedSince: t0, lastTouch: t0 + 2 * 60000);
      expect(d.keepOn, isFalse);
      expect(d.reason, ScreenAwakeReason.stopped);
      expect(d.notice, contains('Press power'));
    });

    test('always during a ride: stays on at stops; the parked rule (5 min) still applies', () {
      expect(decide(now: t0 + 4 * 60000, parkedSince: t0, lastTouch: t0 + 4 * 60000, keepOn: KeepScreenOnMode.always).keepOn, isTrue);
      final parked = decide(now: t0 + 5 * 60000 + 1, parkedSince: t0, lastTouch: t0 + 5 * 60000, keepOn: KeepScreenOnMode.always);
      expect(parked.keepOn, isFalse);
      expect(parked.reason, ScreenAwakeReason.parked);
    });
  });

  group('battery and heat fall back', () {
    test('battery below 15 % and not charging: sleep with the notice (charging keeps the AOD)', () {
      final low = decide(now: t0 + 30000, battery: 14);
      expect(low.keepOn, isFalse);
      expect(low.reason, ScreenAwakeReason.lowBattery);
      expect(low.notice, contains('15%'));
      expect(decide(now: t0 + 30000, battery: 14, charging: true).display, RideDisplay.aod);
    });

    test('severe heat: the AOD after 10 s (dim becomes AOD), and says why', () {
      final hot = decide(now: t0 + 10000, thermal: ScreenAwakePolicy.thermalSevere, idle: RideIdleMode.dim);
      expect(hot.display, RideDisplay.aod);
      expect(hot.keepOn, isTrue);
      expect(hot.reason, ScreenAwakeReason.hot);
      expect(hot.notice, contains('hot'));
      expect(decide(now: t0 + 9999, thermal: ScreenAwakePolicy.thermalSevere).display, RideDisplay.full);
      expect(decide(now: t0 + 10000, thermal: ScreenAwakePolicy.thermalSevere, idle: RideIdleMode.sleep).keepOn, isFalse);
    });

    test('critical heat or worse: sleep, and says why', () {
      for (final s in [4, 5, 6]) {
        final d = decide(thermal: s);
        expect(d.keepOn, isFalse, reason: 'status $s');
        expect(d.reason, ScreenAwakeReason.tooHot);
        expect(d.notice, contains('too hot'));
      }
      expect(decide(thermal: 2).reason, ScreenAwakeReason.riding, reason: 'moderate: nothing changes');
    });
  });

  group('timers', () {
    test('nextChangeAt: the idle deadline counts from the last touch or alert, and the 2 min stop', () {
      final d = decide(now: t0 + 1000, lastAlert: t0 + 500);
      expect(
        ScreenAwakePolicy.nextChangeAt(current: d, nowMs: t0 + 1000, lastTouchMs: t0, parkedSinceMs: 0, lastAlertMs: t0 + 500),
        t0 + 500 + 30000,
      );
      final aodStopped = decide(now: t0 + 40000, parkedSince: t0);
      expect(aodStopped.display, RideDisplay.aod);
      expect(
        ScreenAwakePolicy.nextChangeAt(
            current: aodStopped, nowMs: t0 + 40000, lastTouchMs: t0, parkedSinceMs: t0, keepOnMode: KeepScreenOnMode.whileMoving),
        t0 + 2 * 60000 + 1,
      );
      final hot = decide(now: t0 + 1000, thermal: 3);
      expect(ScreenAwakePolicy.nextChangeAt(current: hot, nowMs: t0 + 1000, lastTouchMs: t0, parkedSinceMs: 0), t0 + 10000);
    });
  });

  group('burn-in shift', () {
    test('moves once every 60 s, never more than 6 px, and repeats', () {
      final seen = <({int dx, int dy})>{};
      for (var m = 0; m < 30; m++) {
        final at = t0 + m * 60000;
        final s = ScreenAwakePolicy.burnInShift(at);
        expect(s.dx.abs(), lessThanOrEqualTo(ScreenAwakePolicy.burnInMaxPx));
        expect(s.dy.abs(), lessThanOrEqualTo(ScreenAwakePolicy.burnInMaxPx));
        expect(ScreenAwakePolicy.burnInShift(at + 59999 - (at % 60000)), s, reason: 'same within the minute');
        seen.add(s);
      }
      expect(seen.length, greaterThan(5), reason: 'it really moves');
      expect(ScreenAwakePolicy.burnInShift(t0), ScreenAwakePolicy.burnInShift(t0), reason: 'deterministic');
    });

    test('nextShiftAt is the next minute boundary', () {
      expect(ScreenAwakePolicy.nextShiftAt(120000), 180000);
      expect(ScreenAwakePolicy.nextShiftAt(120001), 180000);
      expect(ScreenAwakePolicy.nextShiftAt(179999), 180000);
    });
  });

  test('battery estimates are in the setting hints', () {
    expect(RideScreenBattery.screenOn, 'about 6–10% per hour with the screen on');
    expect(RideScreenBattery.keepOnHint(KeepScreenOnMode.whileMoving), contains(RideScreenBattery.screenOn));
    expect(RideScreenBattery.idleHint(RideIdleMode.aod), contains(RideScreenBattery.aod));
    expect(RideScreenBattery.idleHint(RideIdleMode.sleep), contains('Let the screen sleep'));
  });
}
