/// 3.55 group break planner (pure).
///
/// Each phone shares only a fatigue level 0..3 ([FatigueBuckets.bucketOf] of its own 0-100 fatigue
/// score). The lead's phone suggests ONE group break when at least [minTired] riders, or at least
/// [tiredShare] of the fresh riders, are at level [tiredLevel] or more, for [holdFor]. Shown again
/// at most every [quietFor] after it was shown (or planned / dismissed). The card names nobody:
/// it carries a count only.
class GroupBreakPlanner {
  GroupBreakPlanner({
    this.minTired = 2,
    this.tiredShare = 0.3,
    this.tiredLevel = 2,
    this.holdFor = const Duration(seconds: 60),
    this.quietFor = const Duration(minutes: 30),
  });

  final int minTired;
  final double tiredShare;
  final int tiredLevel;
  final Duration holdFor;
  final Duration quietFor;

  int? _since;
  int? _shownAt;
  bool _showing = false;
  int _tired = 0;

  bool get showing => _showing;

  /// Riders at [tiredLevel] or more at the last update (count only).
  int get tiredCount => _tired;

  /// Whether these levels call for a group break (no timing).
  bool needsBreak(List<int> levels) {
    if (levels.isEmpty) return false;
    final tired = levels.where((l) => l >= tiredLevel).length;
    return tired >= minTired || (tired > 0 && tired >= levels.length * tiredShare);
  }

  /// [levels]: one level per fresh rider (the lead's own included). True when the card should be
  /// shown now (first time, or again after [quietFor]); false otherwise.
  bool update({required int nowMs, required List<int> levels}) {
    _tired = levels.where((l) => l >= tiredLevel).length;
    if (!needsBreak(levels)) {
      _since = null;
      _showing = false;
      return false;
    }
    _since ??= nowMs;
    if (_showing || nowMs - _since! < holdFor.inMilliseconds) return false;
    if (_shownAt != null && nowMs - _shownAt! < quietFor.inMilliseconds) return false;
    _showing = true;
    _shownAt = nowMs;
    return true;
  }

  /// The lead planned the stop or dismissed the card: quiet for [quietFor].
  void done(int nowMs) {
    _showing = false;
    _shownAt = nowMs;
  }

  void reset() {
    _since = null;
    _shownAt = null;
    _showing = false;
    _tired = 0;
  }

  static const String title = 'Several riders need a break. Plan a stop?';

  static String message(int tired) => tired <= 1 ? 'A rider is getting tired.' : '$tired riders are getting tired.';
}

/// The shared fatigue level 0..3 from the phone's own 0-100 fatigue score (the score itself and
/// the signals behind it never leave the phone).
class FatigueBuckets {
  FatigueBuckets._();

  /// 0: under 40, 1: 40-69, 2: 70-84 (break advised), 3: 85 and over.
  static int bucketOf(int? score) {
    if (score == null || score < 40) return 0;
    if (score < 70) return 1;
    if (score < 85) return 2;
    return 3;
  }
}
