// Round 10 rescue beacon: the victim-side state machine (start, escalation, duty cycle, battery,
// stops, pings) and the start gate (pure Dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/rescue/rescue_beacon_plan.dart';

/// Runs [plan] from [from] to [to] ms in [step] ms ticks with [env] (or [envAt]); returns the
/// outputs that carried a command or a flag.
List<(int, RescueOutput)> _run(RescueBeaconPlan plan, int from, int to, {RescueEnv env = const RescueEnv(), RescueEnv Function(int t)? envAt, int step = 250}) {
  final out = <(int, RescueOutput)>[];
  for (var t = from; t <= to; t += step) {
    final o = plan.tick(t, envAt?.call(t) ?? env);
    out.add((t, o));
  }
  return out;
}

Iterable<RescueAudioCommand> _audio(List<(int, RescueOutput)> o) => o.map((e) => e.$2.audio).whereType<RescueAudioCommand>();

void main() {
  group('start gate', () {
    RescueTrigger? decide({
      bool sosOpen = true,
      bool alarmOpen = false,
      bool alarmSent = false,
      bool unresponsive = false,
      bool checkExpired = false,
      bool already = false,
      bool riderOk = false,
    }) =>
        RescueStartGate.decide(
          sosOpen: sosOpen,
          alarmOpen: alarmOpen,
          alarmSent: alarmSent,
          alarmUnresponsive: unresponsive,
          responseCheckExpired: checkExpired,
          alreadyRanForSos: already,
          riderOkForSos: riderOk,
        );

    test('countdown ran out with no answer: starts (crashUnanswered)', () {
      expect(decide(alarmOpen: true, alarmSent: true, unresponsive: true), RescueTrigger.crashUnanswered);
    });

    test('never before the countdown ends, even with an SOS open', () {
      expect(decide(alarmOpen: true, alarmSent: false), isNull);
      expect(decide(alarmOpen: true, alarmSent: false, checkExpired: true), isNull);
    });

    test('"Need Help" pressed (rider responded): no start from the alarm', () {
      expect(decide(alarmOpen: true, alarmSent: true, unresponsive: false), isNull);
    });

    test('no SOS open: never (a normal ride)', () {
      expect(decide(sosOpen: false, alarmOpen: true, alarmSent: true, unresponsive: true), isNull);
      expect(decide(sosOpen: false, checkExpired: true), isNull);
      expect(decide(sosOpen: false), isNull);
    });

    test('unanswered "still able to respond?" check of an open SOS: starts (sosUnresponsive)', () {
      expect(decide(checkExpired: true), RescueTrigger.sosUnresponsive);
    });

    test('once per SOS; never after the rider said OK for this SOS', () {
      expect(decide(alarmOpen: true, alarmSent: true, unresponsive: true, already: true), isNull);
      expect(decide(checkExpired: true, riderOk: true), isNull);
    });
  });

  group('response check after an SOS', () {
    test('asks after 3 min, expires once after 60 s more; an answer cancels it', () {
      final c = SosResponseCheck();
      c.update('sos-1', 0);
      expect(c.asking(179000), isFalse);
      expect(c.asking(180000), isTrue);
      expect(c.secondsLeft(200000), 40);
      expect(c.takeExpired(239000), isFalse);
      expect(c.takeExpired(240000), isTrue);
      expect(c.takeExpired(250000), isFalse, reason: 'only once');
      final d = SosResponseCheck()..update('sos-2', 0);
      d.answer();
      expect(d.asking(200000), isFalse);
      expect(d.takeExpired(300000), isFalse);
    });

    test('a new SOS starts a new check; no SOS clears it', () {
      final c = SosResponseCheck()..update('a', 0);
      c.answer();
      c.update('b', 1000);
      expect(c.answered, isFalse);
      c.update(null, 2000);
      expect(c.asking(500000), isFalse);
      expect(c.takeExpired(500000), isFalse);
    });
  });

  group('plan: start and escalation', () {
    test('refuses to start without an open SOS', () {
      final p = RescueBeaconPlan();
      expect(p.start(RescueTrigger.crashUnanswered, 0, sosOpen: false), isFalse);
      expect(p.active, isFalse);
      expect(p.tick(1000, const RescueEnv(sosOpen: false)).audio, isNull);
    });

    test('idle plan never makes a sound (a normal ride)', () {
      final p = RescueBeaconPlan();
      final o = _run(p, 0, 600000, step: 1000);
      expect(_audio(o), isEmpty);
      expect(o.any((e) => e.$2.strobe || e.$2.vibrate || e.$2.ble != BleAdvMode.off), isFalse);
    });

    test('first 2 minutes: continuous siren in 10 s chunks, level and sweep rising', () {
      final p = RescueBeaconPlan();
      expect(p.start(RescueTrigger.crashUnanswered, 0, sosOpen: true), isTrue);
      final o = _run(p, 0, 119750);
      final sirens = _audio(o).where((a) => a.kind == RescueAudioKind.siren).toList();
      expect(sirens.length, 12);
      expect(sirens.first.level, 0.40);
      expect(sirens.last.level, 0.78);
      expect(sirens.first.sweepPeriodS, greaterThan(sirens.last.sweepPeriodS));
      for (var i = 1; i < sirens.length; i++) {
        expect(sirens[i].level, greaterThanOrEqualTo(sirens[i - 1].level));
      }
      expect(o.every((e) => e.$2.phase == RescuePhase.escalating), isTrue);
      expect(o.where((e) => e.$2.vibrate).length, 12, reason: 'a buzz with every chunk');
      expect(o.every((e) => e.$2.ble == BleAdvMode.balanced), isTrue);
    });
  });

  group('plan: duty cycle', () {
    test('2..15 min: one 10 s siren every 30 s, locator packets every 2 s in between', () {
      final p = RescueBeaconPlan(bandCount: 1)..start(RescueTrigger.crashUnanswered, 0, sosOpen: true);
      _run(p, 0, 119750);
      final o = _run(p, 120000, 239750); // 4 cycles of 30 s
      final sirens = _audio(o).where((a) => a.kind == RescueAudioKind.siren).toList();
      expect(sirens.length, 4);
      expect(sirens.every((s) => s.durationMs == 10000 && s.level == 0.78), isTrue);
      final beacons = _audio(o).where((a) => a.kind == RescueAudioKind.beacon).length;
      expect(beacons, inInclusiveRange(36, 44), reason: '20 s gap / 2 s per packet, 4 cycles');
      expect(o.every((e) => e.$2.phase == RescuePhase.dutyFast), isTrue);
    });

    test('after 15 min: one 10 s siren every 60 s', () {
      final p = RescueBeaconPlan(bandCount: 1)..start(RescueTrigger.crashUnanswered, 0, sosOpen: true);
      _run(p, 0, 900000 - 250, step: 250);
      final o = _run(p, 900000, 1139750);
      expect(_audio(o).where((a) => a.kind == RescueAudioKind.siren).length, 4);
      expect(o.every((e) => e.$2.phase == RescuePhase.dutySlow), isTrue);
    });

    test('two bands: packets alternate band 0 and 1 every second', () {
      final p = RescueBeaconPlan(bandCount: 2)..start(RescueTrigger.manualStart, 0, sosOpen: true);
      _run(p, 0, 129750);
      final o = _run(p, 130000, 145000);
      final b = _audio(o).where((a) => a.kind == RescueAudioKind.beacon).map((a) => a.bandIndex).toList();
      expect(b.length, inInclusiveRange(14, 16));
      expect(b.toSet(), {0, 1});
      for (var i = 1; i < b.length; i++) {
        expect(b[i], isNot(b[i - 1]));
      }
    });

    test('BLE goes to low power after 30 min', () {
      final p = RescueBeaconPlan()..start(RescueTrigger.crashUnanswered, 0, sosOpen: true);
      expect(p.tick(1000, const RescueEnv()).ble, BleAdvMode.balanced);
      expect(p.tick(1800001, const RescueEnv()).ble, BleAdvMode.lowPower);
    });
  });

  group('plan: battery (SMS / SOS keep priority)', () {
    test('battery reserve: siren and locator stop at once, BLE low power', () {
      final p = RescueBeaconPlan()..start(RescueTrigger.crashUnanswered, 0, sosOpen: true);
      _run(p, 0, 5000);
      final o = _run(p, 5250, 60000, env: const RescueEnv(batteryPercent: 9));
      expect(o.first.$2.audio?.kind, RescueAudioKind.stop);
      expect(_audio(o).skip(1), isEmpty);
      expect(o.every((e) => e.$2.phase == RescuePhase.reserve && e.$2.ble == BleAdvMode.lowPower), isTrue);
      expect(o.any((e) => e.$2.strobe || e.$2.vibrate), isFalse);
    });

    test('the SOS battery reserve switch alone (even at 12 %) means reserve', () {
      final p = RescueBeaconPlan()..start(RescueTrigger.crashUnanswered, 0, sosOpen: true);
      expect(p.tick(1000, const RescueEnv(batteryPercent: 12, reserveActive: true)).phase, RescuePhase.reserve);
    });

    test('charging lifts the reserve; <= 4 % is critical', () {
      final p = RescueBeaconPlan()..start(RescueTrigger.crashUnanswered, 0, sosOpen: true);
      expect(p.tick(1000, const RescueEnv(batteryPercent: 8, charging: true)).phase, RescuePhase.escalating);
      expect(p.tick(2000, const RescueEnv(batteryPercent: 4)).phase, RescuePhase.critical);
    });

    test('pings in reserve: 5 s bursts at most one a minute; critical: one every 3 min', () {
      final p = RescueBeaconPlan()..start(RescueTrigger.crashUnanswered, 0, sosOpen: true);
      const low = RescueEnv(batteryPercent: 8);
      expect(p.ping(1000, low), PingResult.accepted);
      final o = p.tick(1000, low);
      expect(o.audio?.kind, RescueAudioKind.siren);
      expect(o.audio?.durationMs, 5000);
      expect(p.ping(30000, low), PingResult.throttled);
      expect(p.ping(61001, low), PingResult.accepted);
      const crit = RescueEnv(batteryPercent: 3);
      expect(p.ping(130000, crit), PingResult.throttled);
      expect(p.ping(241002, crit), PingResult.accepted);
    });
  });

  group('plan: stops', () {
    test('rider OK: everything stops (one stop command, then silence, BLE off)', () {
      final p = RescueBeaconPlan()..start(RescueTrigger.crashUnanswered, 0, sosOpen: true);
      _run(p, 0, 15000);
      p.stop(RescueStopReason.riderOk);
      final o = _run(p, 15250, 200000);
      expect(_audio(o).map((a) => a.kind).toList(), [RescueAudioKind.stop]);
      expect(o.every((e) => e.$2.ble == BleAdvMode.off && !e.$2.strobe), isTrue);
      expect(p.active, isFalse);
    });

    test('resolver: the SOS closes anywhere -> stops by itself', () {
      final p = RescueBeaconPlan()..start(RescueTrigger.crashUnanswered, 0, sosOpen: true);
      _run(p, 0, 15000);
      final o = p.tick(15250, const RescueEnv(sosOpen: false));
      expect(o.audio?.kind, RescueAudioKind.stop);
      expect(p.stopReason, RescueStopReason.resolved);
      expect(p.active, isFalse);
    });

    test('bystander: siren, light and vibration stop; locator packets and BLE continue; SOS stays open', () {
      final p = RescueBeaconPlan(bandCount: 1)..start(RescueTrigger.crashUnanswered, 0, sosOpen: true);
      _run(p, 0, 5000, env: const RescueEnv(flashOk: true));
      expect(p.bystanderStop(5100), isTrue);
      expect(p.bystanderStop(5200), isFalse, reason: 'once');
      final o = _run(p, 5250, 400000, env: const RescueEnv(flashOk: true));
      expect(o.first.$2.audio?.kind, RescueAudioKind.stop);
      final kinds = _audio(o).skip(1).map((a) => a.kind).toSet();
      expect(kinds, {RescueAudioKind.beacon});
      expect(o.any((e) => e.$2.strobe || e.$2.vibrate), isFalse);
      expect(o.every((e) => e.$2.ble != BleAdvMode.off), isTrue);
      expect(p.active, isTrue);
      expect(p.bystanderAt, 5100);
    });

    test('a responder ping still plays after the bystander stop (deliberate, rate limited)', () {
      final p = RescueBeaconPlan()..start(RescueTrigger.crashUnanswered, 0, sosOpen: true);
      p.bystanderStop(1000);
      expect(p.ping(200000, const RescueEnv()), PingResult.accepted);
      expect(p.tick(200000, const RescueEnv()).audio?.ping, isTrue);
      expect(p.ping(205000, const RescueEnv()), PingResult.throttled);
    });

    test('a touch on the screen pauses all sound; ping refused while someone holds it', () {
      final p = RescueBeaconPlan()..start(RescueTrigger.crashUnanswered, 0, sosOpen: true);
      _run(p, 0, 3000);
      final o = p.tick(3250, const RescueEnv(touchedRecently: true));
      expect(o.audio?.kind, RescueAudioKind.stop);
      expect(_audio(_run(p, 3500, 10000, env: const RescueEnv(touchedRecently: true))), isEmpty);
      expect(p.ping(10000, const RescueEnv(touchedRecently: true)), PingResult.paused);
      // Released: the siren comes back.
      expect(_audio(_run(p, 10250, 12000)).first.kind, RescueAudioKind.siren);
    });
  });

  group('plan: light, screen, pings without the beacon', () {
    test('strobe only during siren windows and only when flashOk', () {
      final p = RescueBeaconPlan()..start(RescueTrigger.crashUnanswered, 0, sosOpen: true);
      expect(p.tick(1000, const RescueEnv(flashOk: false)).strobe, isFalse);
      expect(p.tick(1250, const RescueEnv(flashOk: true)).strobe, isTrue);
      _run(p, 1500, 129750);
      // In the duty gap (20..30 s of the cycle) no strobe.
      expect(p.tick(145000, const RescueEnv(flashOk: true)).strobe, isFalse);
    });

    test('screen wakes in siren windows in the first 15 min, never when covered', () {
      final p = RescueBeaconPlan()..start(RescueTrigger.crashUnanswered, 0, sosOpen: true);
      expect(p.tick(1000, const RescueEnv()).screenWake, isTrue);
      expect(p.tick(1250, const RescueEnv(covered: true)).screenWake, isFalse);
      expect(p.tick(960000, const RescueEnv()).screenWake, isFalse);
    });

    test('ping with an open SOS but no beacon: one burst, then silence again', () {
      final p = RescueBeaconPlan();
      expect(p.ping(0, const RescueEnv(sosOpen: false)), PingResult.noSos);
      expect(p.ping(1000, const RescueEnv()), PingResult.accepted);
      final o = _run(p, 1000, 20000);
      final a = _audio(o).toList();
      expect(a.first.kind, RescueAudioKind.siren);
      expect(a.first.durationMs, 10000);
      expect(a.last.kind, RescueAudioKind.stop);
      expect(a.length, 2);
    });
  });
}
