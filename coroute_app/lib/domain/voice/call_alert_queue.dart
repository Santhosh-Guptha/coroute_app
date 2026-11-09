/// 3.55 call-aware alerts (admin switch `callAwareAlerts`): what CoRoute does with its spoken lines
/// while the phone rings or a call is active. Pure logic, unit tested (test/call_alert_queue_test.dart);
/// AudioPriorityManager applies it.
///
///  * Ordinary lines (road warnings, group alerts, updates) are not spoken over a call: they are
///    held here, the latest per kind ([HeldAlert.kind]: "Asha fell behind" replaces an older
///    "Asha fell behind").
///  * Navigation directions are not held ([worthHolding]): after the call they are stale and the
///    navigation says the next one anyway.
///  * Critical lines (P0 / P1) still get through during the call as a short tone plus a very short
///    phrase ([shortPhrase]) on the in-call stream; they are also kept here for a full replay.
///  * When the call ends, [summarize] builds at most two lines and empties the queue:
///    "Safety alert during your call: (text)" for critical ones, and
///    "While you were on the call: 2 road warnings, Asha fell behind." for the rest. Ordinary lines
///    older than [maxAgeMs] (60 s) are dropped as stale; critical ones are kept [criticalMaxAgeMs].
library;

class HeldAlert {
  /// Latest per kind is kept.
  final String kind;
  final String text;

  /// AudioPriority level: 0 emergency, 1 safety confirmation, 2 hazard, 3 navigation,
  /// 4 convoy / group, 5 informational.
  final int priority;
  final int atMs;

  const HeldAlert({required this.kind, required this.text, required this.priority, required this.atMs});

  bool get critical => priority <= 1;
}

class CallSummary {
  /// "Safety alert during your call: ..." (null when no critical line was held).
  final String? criticalLine;

  /// "While you were on the call: ..." (null when nothing ordinary is left).
  final String? ordinaryLine;
  final int criticalCount;
  final int ordinaryCount;

  const CallSummary({this.criticalLine, this.ordinaryLine, this.criticalCount = 0, this.ordinaryCount = 0});

  bool get isEmpty => criticalLine == null && ordinaryLine == null;
}

class CallAlertQueue {
  CallAlertQueue({this.maxAgeMs = 60000, this.criticalMaxAgeMs = 300000, this.maxItems = 12});

  final int maxAgeMs;
  final int criticalMaxAgeMs;
  final int maxItems;

  final Map<String, HeldAlert> _held = <String, HeldAlert>{};

  int get length => _held.length;
  bool get isEmpty => _held.isEmpty;
  List<HeldAlert> get items => List.unmodifiable(_held.values);

  /// Navigation (P3) is never held: stale after a call.
  static bool worthHolding(int priority) => priority != 3;

  /// The kind of a line from its dedupe key: a trailing time bucket is dropped, so
  /// 'overspeed_29034811' and 'overspeed_29034812' are the same kind.
  static String kindOf(String key) {
    final k = key.trim();
    final m = RegExp(r'^(.*?)[_:\-]\d{4,}$').firstMatch(k);
    final base = m?.group(1);
    return (base == null || base.isEmpty) ? k : base;
  }

  /// Holds [a] (replacing an older line of the same kind). False when it is not worth holding.
  bool hold(HeldAlert a) {
    if (!worthHolding(a.priority) || a.text.trim().isEmpty) return false;
    _held.remove(a.kind);
    _held[a.kind] = a;
    while (_held.length > maxItems) {
      // Drop the least important, oldest line.
      HeldAlert? worst;
      for (final h in _held.values) {
        if (worst == null || h.priority > worst.priority || (h.priority == worst.priority && h.atMs < worst.atMs)) worst = h;
      }
      _held.remove(worst!.kind);
    }
    return true;
  }

  void clear() => _held.clear();

  /// Lines still worth saying at [nowMs], most important first, newest first within a priority.
  List<HeldAlert> fresh(int nowMs) {
    final out = _held.values.where((h) => nowMs - h.atMs <= (h.critical ? criticalMaxAgeMs : maxAgeMs)).toList()
      ..sort((a, b) => a.priority != b.priority ? a.priority.compareTo(b.priority) : b.atMs.compareTo(a.atMs));
    return out;
  }

  static String _category(int priority, int count) => switch (priority) {
        2 => count == 1 ? 'road warning' : 'road warnings',
        4 => count == 1 ? 'group alert' : 'group alerts',
        _ => count == 1 ? 'update' : 'updates',
      };

  static String _clean(String s) {
    var t = s.trim();
    while (t.endsWith('.') || t.endsWith('!') || t.endsWith(',')) {
      t = t.substring(0, t.length - 1).trimRight();
    }
    return t;
  }

  /// Builds the after-call lines and empties the queue. Empty summary when nothing fresh is left.
  CallSummary summarize(int nowMs, {int maxCriticalInFull = 2}) {
    final list = fresh(nowMs);
    _held.clear();
    final critical = list.where((h) => h.critical).toList();
    final ordinary = list.where((h) => !h.critical).toList();

    String? criticalLine;
    if (critical.isNotEmpty) {
      final full = critical.take(maxCriticalInFull).map((h) => _clean(h.text)).join('. ');
      final rest = critical.length - maxCriticalInFull;
      criticalLine = 'Safety alert during your call: $full${rest > 0 ? '. And $rest more safety ${rest == 1 ? 'alert' : 'alerts'}' : ''}.';
    }

    String? ordinaryLine;
    if (ordinary.isNotEmpty) {
      final byPriority = <int, List<HeldAlert>>{};
      for (final h in ordinary) {
        // Informational lines count with the updates.
        final p = h.priority == 2 || h.priority == 4 ? h.priority : 5;
        byPriority.putIfAbsent(p, () => <HeldAlert>[]).add(h);
      }
      final parts = <String>[];
      for (final p in (byPriority.keys.toList()..sort())) {
        final group = byPriority[p]!;
        parts.add(group.length == 1 ? _clean(group.single.text) : '${group.length} ${_category(p, group.length)}');
      }
      ordinaryLine = 'While you were on the call: ${parts.join(', ')}.';
    }

    return CallSummary(
      criticalLine: criticalLine,
      ordinaryLine: ordinaryLine,
      criticalCount: critical.length,
      ordinaryCount: ordinary.length,
    );
  }

  /// A very short version of a critical line for the in-call stream: the first sentence (two when
  /// the first is a one-word "Emergency."), cut at a word boundary to [maxChars].
  static String shortPhrase(String text, {int maxChars = 70}) {
    final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.isEmpty) return t;
    // A sentence ends at . ! ? followed by a space (so "4.8 km" stays whole).
    final sentences = t.split(RegExp(r'(?<=[.!?])\s+')).where((s) => s.isNotEmpty).toList();
    var out = sentences.isEmpty ? t : sentences.first;
    if (sentences.length > 1 && out.length < 15) out = '$out ${sentences[1]}';
    if (out.length <= maxChars) return out;
    final cut = out.substring(0, maxChars);
    final space = cut.lastIndexOf(' ');
    return (space > maxChars ~/ 2 ? cut.substring(0, space) : cut).trimRight();
  }
}
