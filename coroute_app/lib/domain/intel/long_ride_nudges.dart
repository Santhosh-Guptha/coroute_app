/// Feature 16: fatigue and night riding nudges (pure rules engine, phone only, no server).
///
///  * break reminder after [interval] of riding without a stop of 10 min or more (the stretch comes from the
///    existing FatigueTracker); interval 1.5-3 h, default 2 h. The always-on 2 h prompt (owner decision Nov 11)
///    already covers [baseRuleMin]: this engine adds an earlier one only when the interval is shorter;
///  * a stronger nudge after [strongAfter] (4 h), repeated every [strongRepeat] (30 min) until a real break;
///  * a night riding notice after [nightFor] (30 min) of riding between 23:00 and 05:00 (local time), once per
///    night, with a break reminder [nightBreakAfter] (1 h) later;
///  * the lead's group version: "Group riding 2 h 10 min. Suggest a break at (regroup point).";
///  * never during an SOS / crash alarm (the caller passes [emergency]; nothing is used up), [snooze] keeps it
///    quiet for [snoozeFor] (20 min).
enum NudgeKind { breakReminder, strongBreak, nightNotice, nightBreak, groupBreak }

class Nudge {
  const Nudge(this.kind, this.title, this.speech);
  final NudgeKind kind;
  final String title;
  final String speech;
}

class LongRideNudges {
  LongRideNudges({
    Duration interval = const Duration(hours: 2),
    this.baseRuleMin = 120,
    this.strongAfter = const Duration(hours: 4),
    this.strongRepeat = const Duration(minutes: 30),
    this.nightFor = const Duration(minutes: 30),
    this.nightBreakAfter = const Duration(hours: 1),
    this.snoozeFor = const Duration(minutes: 20),
  }) : interval = clampInterval(interval);

  /// 1.5 h to 3 h.
  static Duration clampInterval(Duration d) => Duration(minutes: d.inMinutes.clamp(90, 180));

  Duration interval;
  final int baseRuleMin;
  final Duration strongAfter;
  final Duration strongRepeat;
  final Duration nightFor;
  final Duration nightBreakAfter;
  final Duration snoozeFor;

  int? _breakFor; // stretch the break reminder was given for
  int? _strongAt;
  int? _strongFor;
  int? _nightSince;
  String? _nightNoticeFor; // date key of the night already noticed
  int? _nightBreakDue;
  int? _snoozedUntil;
  int? _groupFor;
  bool _groupStrong = false;

  void reset() {
    _breakFor = _strongAt = _strongFor = _nightSince = _nightBreakDue = _snoozedUntil = _groupFor = null;
    _nightNoticeFor = null;
    _groupStrong = false;
  }

  void snooze(int nowMs) => _snoozedUntil = nowMs + snoozeFor.inMilliseconds;

  static bool isNight(DateTime local) => local.hour >= 23 || local.hour < 5;

  static String hm(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60;
    if (h == 0) return '$m min';
    return m == 0 ? '$h h' : '$h h $m min';
  }

  /// One look (each fix, or every few seconds). [stretchStartMs]: start of riding without a 10 min stop (null
  /// on a break). [local]: the phone's local time. Returns at most one nudge.
  Nudge? update({required int nowMs, required int? stretchStartMs, required DateTime local, required bool moving, required bool emergency}) {
    // Night tracking runs even while snoozed (it measures riding at night).
    if (isNight(local) && moving) {
      _nightSince ??= nowMs;
    } else if (!isNight(local)) {
      _nightSince = null;
    }
    if (stretchStartMs == null) {
      // A real break: the stretch nudges start over (the night notice stays once per night).
      _breakFor = null;
      _strongFor = null;
      _strongAt = null;
      _nightBreakDue = null;
      return null;
    }
    if (emergency) return null;
    final sn = _snoozedUntil;
    if (sn != null && nowMs < sn) return null;
    final rode = Duration(milliseconds: nowMs - stretchStartMs);

    if (rode >= strongAfter && (_strongFor != stretchStartMs || nowMs - (_strongAt ?? 0) >= strongRepeat.inMilliseconds)) {
      _strongFor = stretchStartMs;
      _strongAt = nowMs;
      _breakFor = stretchStartMs;
      return Nudge(NudgeKind.strongBreak, 'Riding ${hm(rode)} without a real break', '${hm(rode)} without a real break. Please stop and rest at the next safe place.');
    }
    final nb = _nightBreakDue;
    if (nb != null && nowMs >= nb) {
      _nightBreakDue = null;
      return const Nudge(NudgeKind.nightBreak, 'Night riding: time for a short break', 'Night riding for over an hour. Time for a short break.');
    }
    final ns = _nightSince;
    final nightOf = local.subtract(const Duration(hours: 5)); // 23:00-05:00 belongs to the evening's date
    final nightKey = '${nightOf.year}-${nightOf.month}-${nightOf.day}';
    if (ns != null && nowMs - ns >= nightFor.inMilliseconds && _nightNoticeFor != nightKey) {
      _nightNoticeFor = nightKey;
      _nightBreakDue = nowMs + nightBreakAfter.inMilliseconds;
      return const Nudge(NudgeKind.nightNotice, 'Riding late at night', "Riding late at night. I'll remind you to take a break in one hour.");
    }
    if ((baseRuleMin <= 0 || interval.inMinutes < baseRuleMin) && rode >= interval && _breakFor != stretchStartMs) {
      _breakFor = stretchStartMs;
      return Nudge(NudgeKind.breakReminder, 'Time for a short break', "You've been riding for ${hm(rode)}. Time for a short break.");
    }
    return null;
  }

  /// The lead's group version (group rides only): once at [interval] and once at [strongAfter] per stretch.
  Nudge? groupUpdate({required int nowMs, required int? stretchStartMs, required bool emergency, String? regroupName}) {
    if (stretchStartMs == null) {
      _groupFor = null;
      _groupStrong = false;
      return null;
    }
    if (emergency) return null;
    final sn = _snoozedUntil;
    if (sn != null && nowMs < sn) return null;
    final rode = Duration(milliseconds: nowMs - stretchStartMs);
    final strong = rode >= strongAfter;
    if (rode < interval || (_groupFor == stretchStartMs && (!strong || _groupStrong))) return null;
    _groupFor = stretchStartMs;
    if (strong) _groupStrong = true;
    final where = regroupName == null || regroupName.trim().isEmpty ? 'the next safe stop' : regroupName.trim();
    return Nudge(NudgeKind.groupBreak, 'Group riding ${hm(rode)}', 'Group riding ${hm(rode)}. Suggest a break at $where.');
  }
}
