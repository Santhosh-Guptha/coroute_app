import 'package:coroute_app/domain/tracking/fix_gate.dart';
import 'package:flutter_test/flutter_test.dart';

/// 3.56 app audit G-01..G-04: the gate in front of the live position.
void main() {
  const t0 = 1800000000000;
  // 0.001 degrees of latitude is about 111 m.
  const lat = 17.4, lng = 78.5;
  late FixGate g;
  setUp(() => g = FixGate());

  FixReject fix(double la, double ln, int ts, {int? wall}) => g.check(lat: la, lng: ln, tsMs: ts, wallMs: wall ?? ts + 300);

  group('timestamps', () {
    test('time never runs backwards: replays and duplicates are dropped', () {
      expect(fix(lat, lng, t0), FixReject.none);
      expect(fix(lat, lng, t0 + 1000), FixReject.none);
      expect(fix(lat + 0.01, lng, t0 + 500, wall: t0 + 1500), FixReject.outOfOrder, reason: 'the cached fix of a re-subscribed stream');
      expect(fix(lat, lng, t0 + 1000, wall: t0 + 1600), FixReject.outOfOrder, reason: 'the same fix twice');
      expect(fix(lat, lng, t0 + 2000), FixReject.none);
      expect(g.lastAcceptedTs, t0 + 2000);
      expect(g.rejectedOutOfOrder, 2);
    });

    test('a cached fix from minutes ago is not "now"', () {
      expect(fix(lat, lng, t0 - 10 * 60000, wall: t0), FixReject.stale);
      expect(fix(lat, lng, t0, wall: t0 + 400), FixReject.none);
      expect(g.rejectedStale, 1);
    });

    test('a phone with a wrong clock keeps its position (the rule switches itself off)', () {
      // The phone's clock runs 10 minutes ahead of GPS time: every fix "looks" old.
      var rejected = 0;
      for (var i = 0; i < 8; i++) {
        final r = fix(lat + i * 0.0001, lng, t0 + i * 1000, wall: t0 + i * 1000 + 10 * 60000);
        if (r != FixReject.none) rejected++;
      }
      expect(rejected, FixGate.staleGiveUp - 1, reason: 'a few seconds at most, then every fix is used');
      expect(g.clockRuleOff, isTrue);
      expect(fix(lat + 0.001, lng, t0 + 9000, wall: t0 + 9000 + 10 * 60000), FixReject.none);
    });

    test('a clock running behind GPS time changes nothing', () {
      expect(fix(lat, lng, t0, wall: t0 - 5 * 60000), FixReject.none);
      expect(fix(lat, lng, t0 + 1000, wall: t0 - 5 * 60000 + 1000), FixReject.none);
    });
  });

  group('positions', () {
    test('invalid coordinates', () {
      expect(fix(double.nan, lng, t0), FixReject.invalid);
      expect(fix(0, 0, t0), FixReject.invalid);
      expect(fix(91, lng, t0), FixReject.invalid);
      expect(fix(lat, 181, t0), FixReject.invalid);
      expect(fix(lat, lng, 0, wall: t0), FixReject.invalid);
      expect(g.rejectedInvalid, 5);
      expect(fix(lat, lng, t0), FixReject.none);
    });

    test('one wild fix does not teleport the marker; riding on is unaffected', () {
      expect(fix(lat, lng, t0), FixReject.none);
      // 2.2 km away one second later.
      expect(fix(lat + 0.02, lng, t0 + 1000), FixReject.teleport);
      // Back near the real place: 30 m further in 1 s (108 km/h) is a ride.
      expect(fix(lat + 0.00027, lng, t0 + 2000), FixReject.none);
      expect(g.rejectedTeleport, 1);
    });

    test('a fast but possible motorcycle is never a teleport', () {
      expect(fix(lat, lng, t0), FixReject.none);
      // 180 km/h = 50 m/s, for 30 seconds.
      for (var i = 1; i <= 30; i++) {
        expect(fix(lat + i * 0.00045, lng, t0 + i * 1000), FixReject.none, reason: 'second $i');
      }
    });

    test('GPS comes back somewhere else (tunnel, ferry, phone restart): the third agreeing fix is used', () {
      expect(fix(lat, lng, t0), FixReject.none);
      expect(fix(lat + 0.05, lng, t0 + 1000), FixReject.teleport);
      expect(fix(lat + 0.0502, lng, t0 + 2000), FixReject.teleport);
      expect(fix(lat + 0.0504, lng, t0 + 3000), FixReject.none);
      expect(fix(lat + 0.0506, lng, t0 + 4000), FixReject.none);
    });

    test('wild fixes that do not agree with each other never re-anchor', () {
      expect(fix(lat, lng, t0), FixReject.none);
      expect(fix(lat + 0.05, lng, t0 + 1000), FixReject.teleport);
      expect(fix(lat - 0.05, lng, t0 + 2000), FixReject.teleport);
      expect(fix(lat + 0.09, lng + 0.09, t0 + 3000), FixReject.teleport);
      expect(fix(lat, lng + 0.0001, t0 + 4000), FixReject.none);
    });

    test('after a long gap a far fix is plain travel', () {
      expect(fix(lat, lng, t0), FixReject.none);
      // 5 km in 4 minutes (a tunnel): 75 km/h.
      expect(fix(lat + 0.045, lng, t0 + 240000), FixReject.none);
    });

    test('reset forgets everything (a new ride)', () {
      expect(fix(lat, lng, t0), FixReject.none);
      g.reset();
      expect(fix(lat + 1, lng, t0 - 5000, wall: t0), FixReject.none);
    });
  });

  group('stationary jitter and coarse fixes', () {
    test('a parked bike does not wander inside the GPS noise', () {
      expect(FixGate.holdPosition(moving: false, accuracyM: 8, distanceFromShownM: 9, msSinceShownMoved: 600000), isTrue);
      expect(FixGate.holdPosition(moving: false, accuracyM: 30, distanceFromShownM: 25, msSinceShownMoved: 600000), isTrue);
      // Pushed 40 m to the fuel pump (accuracy 10 m): the marker follows.
      expect(FixGate.holdPosition(moving: false, accuracyM: 10, distanceFromShownM: 40, msSinceShownMoved: 600000), isFalse);
    });

    test('riding: every good fix moves the marker', () {
      expect(FixGate.holdPosition(moving: true, accuracyM: 8, distanceFromShownM: 3, msSinceShownMoved: 1000), isFalse);
      expect(FixGate.holdPosition(moving: true, accuracyM: 60, distanceFromShownM: 20, msSinceShownMoved: 1000), isFalse);
    });

    test('a coarse fix does not replace a recent good position, but is used when it is all there is', () {
      expect(FixGate.holdPosition(moving: false, accuracyM: 800, distanceFromShownM: 600, msSinceShownMoved: 5000), isTrue);
      expect(FixGate.holdPosition(moving: false, accuracyM: 800, distanceFromShownM: 600, msSinceShownMoved: 31000), isFalse);
      expect(FixGate.holdPosition(moving: true, accuracyM: 300, distanceFromShownM: 200, msSinceShownMoved: 5000), isTrue);
      expect(FixGate.holdPosition(moving: true, accuracyM: 300, distanceFromShownM: 200, msSinceShownMoved: 11000), isFalse);
      expect(FixGate.holdPosition(moving: false, accuracyM: double.nan, distanceFromShownM: 5, msSinceShownMoved: 1000), isTrue);
    });

    test('distance', () {
      expect(FixGate.distanceM(17.4, 78.5, 17.401, 78.5), closeTo(111.2, 0.5));
      expect(FixGate.distanceM(17.4, 78.5, 17.4, 78.5), 0);
    });
  });

  group('position stream restart (G-07)', () {
    test('growing waits, capped at a minute, short again after a fix', () {
      final b = GpsRestartBackoff();
      expect([for (var i = 0; i < 7; i++) b.next().inSeconds], [2, 5, 15, 30, 60, 60, 60]);
      expect(b.attempts, 7);
      b.reset();
      expect(b.next().inSeconds, 2);
    });
  });

  group('battery exemption question (B-01)', () {
    const day = 24 * 3600 * 1000;
    test('never when already allowed; once a week otherwise; a clock set back does not silence it', () {
      expect(BatteryExemptionAsk.shouldAsk(nowMs: t0, lastAskedMs: 0, alreadyExempt: true), isFalse);
      expect(BatteryExemptionAsk.shouldAsk(nowMs: t0, lastAskedMs: 0, alreadyExempt: false), isTrue);
      expect(BatteryExemptionAsk.shouldAsk(nowMs: t0, lastAskedMs: t0 - 2 * day, alreadyExempt: false), isFalse);
      expect(BatteryExemptionAsk.shouldAsk(nowMs: t0, lastAskedMs: t0 - 7 * day, alreadyExempt: false), isTrue);
      expect(BatteryExemptionAsk.shouldAsk(nowMs: t0, lastAskedMs: t0 + day, alreadyExempt: false), isTrue);
    });
  });
}
