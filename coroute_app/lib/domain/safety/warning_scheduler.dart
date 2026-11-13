/// Advisory warnings, most urgent first. SOS, crash alarms and other riders' SOS are NOT here:
/// they are emergencies, they bypass this scheduler and silence it ([WarningScheduler.setEmergency]).
enum WarnKind {
  /// Hazard hotspot ahead (riders crashed / braked hard / skidded there).
  hazard,

  /// Sharp bend / hairpin / series of bends ahead.
  curve,

  /// Over the road's speed limit.
  speedLimit,

  /// A rider is falling behind (lead and sweep).
  fallingBehind,

  /// Rough road / potholes ahead.
  roughRoad,

  /// Break reminders, night riding, altitude.
  fatigue,

  /// "Twisty section ahead" and other road information.
  twisty,
}

class WarnRule {
  const WarnRule({required this.priority, required this.minGapMs, required this.ttlMs});

  /// Higher wins.
  final int priority;

  /// Least time between two spoken warnings of this kind.
  final int minGapMs;

  /// A warning that could not be spoken within this time is dropped (it would be late).
  final int ttlMs;
}

class AdvisoryWarning {
  const AdvisoryWarning({required this.kind, required this.key, required this.speech, this.title = '', this.estimatedSpeakMs});

  final WarnKind kind;

  /// Stable id: the same key is never spoken twice in a row within its kind's gap.
  final String key;
  final String speech;
  final String title;

  /// How long the speech takes (null: estimated from its length).
  final int? estimatedSpeakMs;

  int get speakMs => estimatedSpeakMs ?? (1200 + speech.length * 65).clamp(1500, 9000);
}

enum WarnOutcome {
  /// Say it now.
  speak,

  /// Say it now and stop the less urgent warning that is being spoken.
  speakInterrupting,

  /// Wait: [WarningScheduler.next] hands it out when the voice is free (unless it expires).
  queued,

  /// Not spoken (show it without sound if the caller wants to): rate limit, repeat, or less
  /// urgent than what is waiting.
  silent,

  /// Nothing at all: an emergency is open, or advisory warnings are muted.
  suppressed,
}

/// ONE scheduler for every advisory voice warning (round 7; pure, the caller owns the clock, the
/// voice and the cards):
///  * priority: hazard > curve > speed limit > falling behind > rough road > fatigue > twisty;
///  * never two voices at once: while one is spoken a new one waits, unless it is clearly more
///    urgent (two steps or more), which interrupts;
///  * a gap of [minVoiceGapMs] between two warnings, a gap per kind, at most [maxPerMinute] a minute;
///    a hazard or curve warning is never held back by the per-minute cap (they are rare and timed);
///  * a waiting warning expires (a bend warning after 3 s: later would be wrong);
///  * an emergency (my SOS / crash alarm, another rider's SOS) empties the queue at once and
///    nothing is spoken until it is over; [muted] silences advisories only.
class WarningScheduler {
  WarningScheduler({this.minVoiceGapMs = 2500, this.maxPerMinute = 4, Map<WarnKind, WarnRule>? rules}) : rules = rules ?? defaultRules;

  static const Map<WarnKind, WarnRule> defaultRules = {
    WarnKind.hazard: WarnRule(priority: 70, minGapMs: 8000, ttlMs: 6000),
    WarnKind.curve: WarnRule(priority: 60, minGapMs: 8000, ttlMs: 3000),
    WarnKind.speedLimit: WarnRule(priority: 50, minGapMs: 20000, ttlMs: 8000),
    WarnKind.fallingBehind: WarnRule(priority: 40, minGapMs: 30000, ttlMs: 20000),
    WarnKind.roughRoad: WarnRule(priority: 30, minGapMs: 30000, ttlMs: 6000),
    WarnKind.fatigue: WarnRule(priority: 20, minGapMs: 60000, ttlMs: 60000),
    WarnKind.twisty: WarnRule(priority: 10, minGapMs: 60000, ttlMs: 30000),
  };

  /// Kinds that the per-minute cap never holds back.
  static const Set<WarnKind> uncapped = {WarnKind.hazard, WarnKind.curve};

  final int minVoiceGapMs;
  final int maxPerMinute;
  final Map<WarnKind, WarnRule> rules;

  bool muted = false;
  bool _emergency = false;
  AdvisoryWarning? _speaking;
  int _speakingUntil = 0;
  final Map<WarnKind, int> _lastSpoken = <WarnKind, int>{};
  final Map<WarnKind, String> _lastKey = <WarnKind, String>{};
  final List<int> _spokenAt = <int>[];
  final List<({AdvisoryWarning w, int at})> _queue = <({AdvisoryWarning w, int at})>[];

  bool get emergency => _emergency;
  int get queued => _queue.length;
  AdvisoryWarning? speakingAt(int nowMs) => nowMs < _speakingUntil ? _speaking : null;

  int _prio(WarnKind k) => rules[k]!.priority;

  /// An emergency opened or closed. Returns true when the caller must stop the advisory voice
  /// now (something was being spoken or waiting).
  bool setEmergency(bool open, int nowMs) {
    if (_emergency == open) return false;
    _emergency = open;
    if (!open) return false;
    final had = _queue.isNotEmpty || nowMs < _speakingUntil;
    _queue.clear();
    _speaking = null;
    _speakingUntil = 0;
    return had;
  }

  void reset() {
    _queue.clear();
    _speaking = null;
    _speakingUntil = 0;
    _lastSpoken.clear();
    _lastKey.clear();
    _spokenAt.clear();
    _emergency = false;
  }

  bool _rateOk(AdvisoryWarning w, int nowMs) {
    final rule = rules[w.kind]!;
    final last = _lastSpoken[w.kind];
    if (last != null && nowMs - last < rule.minGapMs) return false;
    if (uncapped.contains(w.kind)) return true;
    _spokenAt.removeWhere((t) => nowMs - t >= 60000);
    return _spokenAt.length < maxPerMinute;
  }

  void _start(AdvisoryWarning w, int nowMs) {
    _speaking = w;
    _speakingUntil = nowMs + w.speakMs;
    _lastSpoken[w.kind] = nowMs;
    _lastKey[w.kind] = w.key;
    _spokenAt.add(nowMs);
  }

  /// A warning wants to be spoken now.
  WarnOutcome submit(AdvisoryWarning w, int nowMs) {
    if (_emergency || muted) return WarnOutcome.suppressed;
    if (_lastKey[w.kind] == w.key && _lastSpoken[w.kind] != null && nowMs - _lastSpoken[w.kind]! < 60000) return WarnOutcome.silent;
    if (!_rateOk(w, nowMs)) return WarnOutcome.silent;
    final cur = speakingAt(nowMs);
    if (cur != null) {
      if (_prio(w.kind) - _prio(cur.kind) >= 20) {
        _queue.removeWhere((q) => _prio(q.w.kind) <= _prio(w.kind));
        _start(w, nowMs);
        return WarnOutcome.speakInterrupting;
      }
      return _enqueue(w, nowMs);
    }
    // The voice is free: keep a short gap after the last warning unless this one is urgent.
    final sinceLast = nowMs - _speakingUntil;
    if (_speaking != null && sinceLast < minVoiceGapMs && !uncapped.contains(w.kind)) return _enqueue(w, nowMs);
    _start(w, nowMs);
    return WarnOutcome.speak;
  }

  WarnOutcome _enqueue(AdvisoryWarning w, int nowMs) {
    // One waiting warning per kind (the newer one), at most 3 waiting: the least urgent goes.
    _queue.removeWhere((q) => q.w.kind == w.kind);
    _queue.add((w: w, at: nowMs));
    _queue.sort((a, b) => _prio(b.w.kind).compareTo(_prio(a.w.kind)));
    if (_queue.length > 3) {
      final dropped = _queue.removeLast();
      if (identical(dropped.w, w)) return WarnOutcome.silent;
    }
    return WarnOutcome.queued;
  }

  /// The waiting warning to speak now, or null. Call it on a timer / with each fix.
  AdvisoryWarning? next(int nowMs) {
    if (_emergency || muted) {
      _queue.clear();
      return null;
    }
    _queue.removeWhere((q) => nowMs - q.at > rules[q.w.kind]!.ttlMs);
    if (_queue.isEmpty || nowMs < _speakingUntil) return null;
    final head = _queue.first;
    if (_speaking != null && nowMs - _speakingUntil < minVoiceGapMs && !uncapped.contains(head.w.kind)) return null;
    _queue.removeAt(0);
    if (!_rateOk(head.w, nowMs)) return next(nowMs);
    _start(head.w, nowMs);
    return head.w;
  }
}
