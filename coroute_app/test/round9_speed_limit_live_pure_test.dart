// Round 9 (docs/quality/ROUND9_SETTINGS_NOTES.md): a speed limit changed during a ride applies within
// one position update, and is heard; fewer settings with safe defaults. Pure Dart:
//   DART=/opt/dartpkg/bin/dart tool/pure_dart_test/run.sh test/round9_speed_limit_live_pure_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/road/road_ahead_engine.dart';
import 'package:coroute_app/domain/road/speed_limit_resolver.dart';
import 'package:coroute_app/domain/safety/effective_speed_limit.dart';
import 'package:coroute_app/domain/safety/overspeed_gate.dart';
import 'package:coroute_app/domain/safety/overspeed_voice.dart';
import 'package:coroute_app/domain/safety/ride_warning_mute.dart';
import 'package:coroute_app/domain/safety/settings_round9.dart';

/// The voice's duplicate filter as AudioPriorityManager applies it: a key spoken within its window is dropped.
class _Dedupe {
  final Map<String, (int, int)> _seen = {};
  bool admit(String key, Duration window, int nowMs) {
    final h = _seen[key];
    if (h != null && nowMs - h.$1 < h.$2) return false;
    _seen[key] = (nowMs, window.inMilliseconds);
    return true;
  }
}

/// SafetyService's speed path, reduced to its pure parts: on every fix the limit is read again from the
/// current settings / group meta ([personal], [group]), judged by [OverspeedGate], and a warning is spoken
/// through the voice's duplicate filter with [OverspeedVoice]'s key.
class _Rider {
  int personal = 0;
  int group = 0;
  int now = 1731500000000; // a minute boundary is not special any more
  final OverspeedGate gate = OverspeedGate();
  final _Dedupe voice = _Dedupe();
  final List<String> spoken = [];
  final List<OverspeedStep> steps = [];
  int lastLimit = 0;

  OverspeedStep fix(double speedKmh, {int stepMs = 1000}) {
    now += stepMs;
    final limit = effectiveSpeedLimit(groupKmh: group, personalKmh: personal);
    lastLimit = limit;
    final step = gate.update(speedKmh: speedKmh, limitKmh: limit, nowMs: now);
    steps.add(step);
    if (step == OverspeedStep.warn) {
      final far = OverspeedVoice.farOver(currentSpeedKmh: speedKmh.round(), limitKmh: limit);
      final key = OverspeedVoice.key(limitKmh: limit, nowMs: now, far: far);
      if (voice.admit(key, OverspeedVoice.dedupeWindow, now)) spoken.add(OverspeedVoice.text(currentSpeedKmh: speedKmh.round(), limitKmh: limit));
    }
    return step;
  }
}

void main() {
  group('own speed warning changed mid-ride (Settings)', () {
    test('lowered: warned within two fixes (about 1-2 s) at the new limit, and the voice says it', () {
      final r = _Rider()..personal = 100;
      for (var i = 0; i < 5; i++) {
        expect(r.fix(85), OverspeedStep.none);
      }
      r.personal = 80; // the rider taps 80 in Settings during the ride
      final a = r.fix(85), b = r.fix(85);
      expect([a, b], contains(OverspeedStep.warn), reason: 'the new limit applies within two fixes');
      expect(r.lastLimit, 80);
      expect(r.spoken.last, contains('limit 80'));
    });

    test('lowered again within the same minute: a second warning is still spoken (the old minute key dropped it)', () {
      final r = _Rider()..personal = 80;
      r.fix(95);
      r.fix(95);
      expect(r.spoken, hasLength(1));
      r.personal = 60;
      r.fix(95);
      r.fix(95);
      expect(r.spoken, hasLength(2), reason: 'new limit, new key: not a duplicate');
      expect(r.spoken.last, contains('limit 60'));
    });

    test('raised above my speed: the warning clears on the next fix', () {
      final r = _Rider()..personal = 60;
      r.fix(75);
      r.fix(75);
      expect(r.gate.showing, isTrue);
      r.personal = 100;
      expect(r.fix(75), OverspeedStep.clear);
      expect(r.gate.showing, isFalse);
    });

    test('the old minute key really was the bug: two limits in one minute collide', () {
      String oldKey(int nowMs) => 'overspeed_${nowMs ~/ 60000}';
      final d = _Dedupe();
      const tenMinutes = Duration(minutes: 10);
      const t = 1731500010000;
      expect(d.admit(oldKey(t), tenMinutes, t), isTrue);
      expect(d.admit(oldKey(t + 20000), tenMinutes, t + 20000), isFalse, reason: 'before: the new limit was silent');
      final n = _Dedupe();
      expect(n.admit(OverspeedVoice.key(limitKmh: 80, nowMs: t), OverspeedVoice.dedupeWindow, t), isTrue);
      expect(n.admit(OverspeedVoice.key(limitKmh: 60, nowMs: t + 20000), OverspeedVoice.dedupeWindow, t + 20000), isTrue);
    });

    test('a double submit of the same warning is still dropped', () {
      final d = _Dedupe();
      const t = 1731500010000;
      final k = OverspeedVoice.key(limitKmh: 80, nowMs: t);
      expect(d.admit(k, OverspeedVoice.dedupeWindow, t), isTrue);
      expect(d.admit(OverspeedVoice.key(limitKmh: 80, nowMs: t + 300), OverspeedVoice.dedupeWindow, t + 300), isFalse);
    });

    test('far over the limit the line is the critical one and names the limit', () {
      expect(OverspeedVoice.farOver(currentSpeedKmh: 120, limitKmh: 80), isTrue);
      expect(OverspeedVoice.text(currentSpeedKmh: 120, limitKmh: 80), 'Slow down. 120 km/h, limit 80.');
      expect(OverspeedVoice.text(currentSpeedKmh: 90, limitKmh: 80), 'Over limit. 90 km/h, limit 80.');
      expect(OverspeedVoice.key(limitKmh: 80, nowMs: 1731500010000, far: true), startsWith('overspeed_far_l80_'));
    });
  });

  group('group limit changed by the lead mid-ride (CONFIG)', () {
    test('lowered by the lead: every member is judged at the new limit on the next fixes', () {
      final member = _Rider()..group = 100;
      member.fix(90);
      member.group = 80; // CONFIG {speedLimitKmh: 80} arrived
      member.fix(90);
      member.fix(90);
      expect(member.steps, contains(OverspeedStep.warn));
      expect(member.spoken.last, contains('limit 80'));
    });

    test('switched off by the lead: the card goes at once', () {
      final member = _Rider()..group = 60;
      member.fix(80);
      member.fix(80);
      expect(member.gate.showing, isTrue);
      member.group = 0;
      expect(member.fix(80), OverspeedStep.clear);
    });

    test('the stricter limit always wins; Settings says which one applies now', () {
      expect(effectiveSpeedLimit(groupKmh: 80, personalKmh: 100), 80);
      expect(speedLimitSource(groupKmh: 80, personalKmh: 100), SpeedLimitSource.group);
      expect(speedLimitSource(groupKmh: 80, personalKmh: 60), SpeedLimitSource.personal);
      expect(speedLimitSource(groupKmh: 0, personalKmh: 0), SpeedLimitSource.none);
      expect(speedWarningLine(groupKmh: 80, personalKmh: 100, inRide: true), contains('group limit 80'));
      expect(speedWarningLine(groupKmh: 80, personalKmh: 100, inRide: true), contains('stricter than yours'));
      expect(speedWarningLine(groupKmh: 80, personalKmh: 60, inRide: true), contains('your limit 60'));
      expect(speedWarningLine(groupKmh: 0, personalKmh: 60, inRide: true), 'Now: your limit 60 km/h.');
      expect(speedWarningLine(groupKmh: 70, personalKmh: 0, inRide: true), 'Now: group limit 70 km/h.');
      expect(speedWarningLine(groupKmh: 70, personalKmh: 0, inRide: false), isNot(contains('70')), reason: 'no ride: no group limit');
      expect(speedWarningLine(groupKmh: 0, personalKmh: 0, inRide: true), contains('Road limits'));
    });
  });

  group('road limits (round 7) with the automatic margin', () {
    test('the fixed margin is +10 %, never less than 5 km/h, and none near schools', () {
      expect(SettingsRound9.overspeedTolerancePct, OverspeedPolicy.defaultTolerancePct);
      expect(OverspeedPolicy.thresholdKmh(30, tolerancePct: SettingsRound9.overspeedTolerancePct), 35, reason: 'min 5 km/h');
      expect(OverspeedPolicy.thresholdKmh(80, tolerancePct: SettingsRound9.overspeedTolerancePct), 88);
      expect(OverspeedPolicy.thresholdKmh(30, tolerancePct: SettingsRound9.overspeedTolerancePct, zone: true), 30);
    });

    test('default prefs have bends, the limit sign and the overspeed warning on', () {
      const p = RoadAheadPrefs();
      expect(p.curveWarnings && p.limitDisplay && p.overspeedWarning, isTrue);
      expect(p.tolerancePct, SettingsRound9.overspeedTolerancePct);
    });
  });

  group('migration step 3 (pure plan)', () {
    test('stored "off" switches are written back on; retired choices are deleted', () {
      final plan = SettingsRound9.plan({
        SettingsRound9.keyCurveWarnings: false,
        SettingsRound9.keyRoadLimitDisplay: false,
        SettingsRound9.keyRoadOverspeedWarning: true,
        SettingsRound9.keyLowerMusicWhenSpeeding: false,
        SettingsRound9.keyRoadOverspeedTolerancePct: 20,
        SettingsRound9.keyRideIdleMode: 'sleep',
        SettingsRound9.keyNoiseReduction: 'off',
      });
      expect(plan.writes, {
        SettingsRound9.keyCurveWarnings: true,
        SettingsRound9.keyRoadLimitDisplay: true,
        SettingsRound9.keyLowerMusicWhenSpeeding: true,
        SettingsRound9.keyWindNoiseMode: true,
      });
      expect(plan.deletes, unorderedEquals([SettingsRound9.keyRoadOverspeedTolerancePct, SettingsRound9.keyRideIdleMode, SettingsRound9.keyNoiseReduction]));
    });

    test('only ever writes "on", never touches consent, privacy or the rider\'s own choices', () {
      final everything = <String, Object?>{
        for (final k in SettingsRound9.neverTouched) k: false,
        for (final k in SettingsRound9.alwaysOnKeys) k: false,
        for (final k in SettingsRound9.retiredKeys) k: 'x',
      };
      final plan = SettingsRound9.plan(everything);
      expect(plan.writes.values.every((v) => v), isTrue);
      for (final k in SettingsRound9.neverTouched) {
        expect(plan.writes.containsKey(k), isFalse, reason: k);
        expect(plan.deletes, isNot(contains(k)), reason: k);
      }
    });

    test('a fresh install: nothing to delete, the switches are written on', () {
      final plan = SettingsRound9.plan(const {});
      expect(plan.deletes, isEmpty);
      expect(plan.writes.keys, unorderedEquals(SettingsRound9.alwaysOnKeys));
    });
  });

  group('"Mute this ride" for rough road, twisty road and nudges', () {
    test('only the low-priority road warnings can be muted; never hazards, bends or limits', () {
      expect(RideWarningMute.kindOf('INTEL:ROUGH:abc'), MutableWarning.roughRoad);
      expect(RideWarningMute.kindOf('intel_ROUGH:abc'), MutableWarning.roughRoad);
      expect(RideWarningMute.kindOf('INTEL:TWISTY:120'), MutableWarning.twisty);
      expect(RideWarningMute.kindOf('INTEL:NUDGE:strongBreak:9'), MutableWarning.nudges);
      for (final k in ['INTEL:HAZARD:x', 'intel_HAZARD:x', 'ROADCARE:BEND:120', 'ROADCARE:LIMIT:road:60', 'ROADCARE:NIGHT_BREAK:1', 'MY_SOS', 'ROUGH:x']) {
        expect(RideWarningMute.kindOf(k), isNull, reason: k);
      }
    });

    test('muted for this ride (card and voice), back on at the next ride', () {
      final m = RideWarningMute();
      expect(m.blocks('INTEL:ROUGH:a'), isFalse);
      expect(m.muteKindOf('INTEL:ROUGH:a'), isTrue);
      expect(m.blocks('INTEL:ROUGH:b'), isTrue, reason: 'every rough road card of this ride');
      expect(m.blocks('intel_ROUGH:b'), isTrue, reason: 'and its voice line');
      expect(m.blocks('INTEL:TWISTY:1'), isFalse);
      expect(m.muteKindOf('INTEL:HAZARD:a'), isFalse);
      m.reset();
      expect(m.blocks('INTEL:ROUGH:b'), isFalse);
    });
  });
}
