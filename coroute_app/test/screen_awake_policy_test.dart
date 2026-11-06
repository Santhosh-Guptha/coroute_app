import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/tracking/screen_awake_policy.dart';

const int t0 = 1700000000000;

ScreenAwakeDecision decide({
  bool riding = true,
  bool foreground = true,
  bool userKeepOn = true,
  int now = t0,
  int lastTouch = t0,
  int parkedSince = 0,
  int battery = 80,
  bool charging = false,
  bool emergency = false,
}) =>
    ScreenAwakePolicy.decide(
      riding: riding,
      foreground: foreground,
      userKeepOn: userKeepOn,
      nowMs: now,
      lastTouchMs: lastTouch,
      parkedSinceMs: parkedSince,
      batteryPercent: battery,
      charging: charging,
      emergencyOpen: emergency,
    );

void main() {
  group('ScreenAwakePolicy (always-on ride screen)', () {
    test('riding in front: kept on, dims after 30 s without a touch', () {
      expect(decide(), const ScreenAwakeDecision(keepOn: true, dim: false, reason: ScreenAwakeReason.riding));
      expect(decide(now: t0 + 29999).dim, isFalse);
      final dimmed = decide(now: t0 + 30000);
      expect(dimmed.keepOn, isTrue);
      expect(dimmed.dim, isTrue);
      expect(dimmed.notice, isNull);
      expect(decide(now: t0 + 60000, lastTouch: t0 + 59000).dim, isFalse, reason: 'a touch wakes it');
    });

    test('no ride, background or switched off: not kept on, never dimmed', () {
      for (final d in [decide(riding: false), decide(foreground: false), decide(userKeepOn: false)]) {
        expect(d.keepOn, isFalse);
        expect(d.dim, isFalse);
        expect(d.reason, ScreenAwakeReason.notRiding);
        expect(d.notice, isNull);
      }
    });

    test('parked over 5 min: the screen may sleep, with the reason', () {
      expect(decide(now: t0 + 5 * 60000, parkedSince: t0).keepOn, isTrue, reason: 'exactly 5 min');
      final parked = decide(now: t0 + 5 * 60000 + 1, parkedSince: t0, lastTouch: t0 + 5 * 60000);
      expect(parked.keepOn, isFalse);
      expect(parked.reason, ScreenAwakeReason.parked);
      expect(parked.notice, contains('parked over 5 min'));
    });

    test('battery below 15 % and not charging: may sleep; charging or unknown keeps it on', () {
      final low = decide(battery: 14);
      expect(low.keepOn, isFalse);
      expect(low.reason, ScreenAwakeReason.lowBattery);
      expect(low.notice, contains('15%'));
      expect(decide(battery: 15).keepOn, isTrue);
      expect(decide(battery: 5, charging: true).keepOn, isTrue);
      expect(decide(battery: -1).keepOn, isTrue);
    });

    test('an open emergency keeps the screen on at full brightness', () {
      final d = decide(now: t0 + 10 * 60000, parkedSince: t0, battery: 5, emergency: true);
      expect(d.keepOn, isTrue);
      expect(d.dim, isFalse);
    });

    test('nextChangeAt: one timer for the dim and the parked deadline', () {
      final d = decide(now: t0 + 1000, lastTouch: t0);
      expect(ScreenAwakePolicy.nextChangeAt(current: d, nowMs: t0 + 1000, lastTouchMs: t0, parkedSinceMs: 0), t0 + 30000);
      final parkedDim = decide(now: t0 + 40000, lastTouch: t0, parkedSince: t0);
      expect(parkedDim.dim, isTrue);
      expect(
        ScreenAwakePolicy.nextChangeAt(current: parkedDim, nowMs: t0 + 40000, lastTouchMs: t0, parkedSinceMs: t0),
        t0 + 5 * 60000 + 1,
      );
      expect(ScreenAwakePolicy.nextChangeAt(current: decide(riding: false), nowMs: t0, lastTouchMs: t0, parkedSinceMs: 0), isNull);
    });
  });
}
