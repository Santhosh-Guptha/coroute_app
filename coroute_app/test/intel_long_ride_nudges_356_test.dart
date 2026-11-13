import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/intel/long_ride_nudges.dart';

/// Round 4 fatigue and night riding rules (feature 16, lib/domain/intel/long_ride_nudges.dart).
void main() {
  const min = 60000;
  final day = DateTime(2026, 11, 12, 9); // 09:00 local

  /// Rides from [start] for [minutes], one look per minute; returns (minute, nudge) pairs.
  List<(int, Nudge)> ride(LongRideNudges n, {int minutes = 300, DateTime? startLocal, bool Function(int m)? emergencyAt, int? breakAtMin}) {
    final out = <(int, Nudge)>[];
    final s = startLocal ?? day;
    int? stretch = 0;
    for (var m = 0; m <= minutes; m++) {
      final now = m * min;
      if (breakAtMin != null && m == breakAtMin) stretch = null; // a 10 min stop ended the stretch
      if (breakAtMin != null && m == breakAtMin + 10) stretch = now;
      final x = n.update(nowMs: now, stretchStartMs: stretch, local: s.add(Duration(minutes: m)), moving: stretch != null, emergency: emergencyAt?.call(m) ?? false);
      if (x != null) out.add((m, x));
    }
    return out;
  }

  test('interval is 1.5-3 h; the always-on 2 h prompt covers 2 h and longer', () {
    expect(LongRideNudges.clampInterval(const Duration(minutes: 30)).inMinutes, 90);
    expect(LongRideNudges.clampInterval(const Duration(hours: 5)).inMinutes, 180);
    final two = ride(LongRideNudges(), minutes: 230);
    expect(two.where((x) => x.$2.kind == NudgeKind.breakReminder), isEmpty, reason: 'SafetyService shows the 2 h prompt');
    final early = ride(LongRideNudges(interval: const Duration(minutes: 90)), minutes: 230);
    final b = early.where((x) => x.$2.kind == NudgeKind.breakReminder).toList();
    expect(b.map((x) => x.$1), [90]);
    expect(b.single.$2.speech, "You've been riding for 1 h 30 min. Time for a short break.");
    // Without the always-on rule (unit level): the engine itself fires at any interval in range.
    final pure = ride(LongRideNudges(interval: const Duration(hours: 3), baseRuleMin: 0), minutes: 200);
    expect(pure.where((x) => x.$2.kind == NudgeKind.breakReminder).map((x) => x.$1), [180]);
  });

  test('a stronger nudge after 4 h, again every 30 min until a real break', () {
    final got = ride(LongRideNudges(), minutes: 320).where((x) => x.$2.kind == NudgeKind.strongBreak).map((x) => x.$1).toList();
    expect(got, [240, 270, 300]);
    final withBreak = ride(LongRideNudges(), minutes: 320, breakAtMin: 200).where((x) => x.$2.kind == NudgeKind.strongBreak);
    expect(withBreak, isEmpty, reason: 'a 10 minute stop at 3 h 20 starts a new stretch');
  });

  test('night riding: a notice after 30 min between 23:00 and 05:00, then a break reminder 1 h later; once per night', () {
    final got = ride(LongRideNudges(), minutes: 200, startLocal: DateTime(2026, 11, 12, 22, 40));
    final notice = got.where((x) => x.$2.kind == NudgeKind.nightNotice).toList();
    expect(notice.map((x) => x.$1), [50], reason: '23:00 + 30 min');
    expect(notice.single.$2.speech, contains('remind you to take a break in one hour'));
    expect(got.where((x) => x.$2.kind == NudgeKind.nightBreak).map((x) => x.$1), [110]);
    final dayRide = ride(LongRideNudges(), minutes: 200, startLocal: DateTime(2026, 11, 12, 15));
    expect(dayRide.where((x) => x.$2.kind == NudgeKind.nightNotice), isEmpty);
  });

  test('never during an SOS / crash alarm (nothing used up); snooze keeps it quiet for 20 min', () {
    final quiet = ride(LongRideNudges(), minutes: 260, emergencyAt: (m) => m >= 235 && m <= 250);
    expect(quiet.where((x) => x.$2.kind == NudgeKind.strongBreak).map((x) => x.$1), [251], reason: 'given right after the emergency');
    final n = LongRideNudges();
    n.snooze(239 * min);
    final s = <int>[];
    for (var m = 239; m <= 265; m++) {
      if (n.update(nowMs: m * min, stretchStartMs: 0, local: day.add(Duration(minutes: m)), moving: true, emergency: false) != null) s.add(m);
    }
    expect(s, [259]);
  });

  test('group version for the lead: at the interval and at 4 h, with the regroup point', () {
    final n = LongRideNudges();
    final out = <(int, Nudge)>[];
    for (var m = 0; m <= 260; m++) {
      final g = n.groupUpdate(nowMs: m * min, stretchStartMs: 0, emergency: false, regroupName: m < 200 ? 'Indian Oil Kurnool' : null);
      if (g != null) out.add((m, g));
    }
    expect(out.map((x) => x.$1), [120, 240]);
    expect(out.first.$2.speech, 'Group riding 2 h. Suggest a break at Indian Oil Kurnool.');
    expect(out.last.$2.speech, 'Group riding 4 h. Suggest a break at the next safe stop.');
    expect(n.groupUpdate(nowMs: 130 * min, stretchStartMs: 0, emergency: true), isNull);
    expect(LongRideNudges.hm(const Duration(minutes: 130)), '2 h 10 min');
  });
}
