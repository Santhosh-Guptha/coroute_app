/// One acclimatisation reminder.
class AltitudeNotice {
  const AltitudeNotice({required this.kind, required this.title, required this.message, required this.speech});
  final AltitudeNoticeKind kind;
  final String title;
  final String message;
  final String speech;
}

enum AltitudeNoticeKind { high, veryHigh, fastClimb }

/// High-altitude care (3.55), pure and offline: GPS altitude and climb rate.
///
/// GPS altitude is noisy (tens of metres), so a fix counts only when its altitude is finite and
/// not exactly 0 (what many phones report when they have none), and the altitude used is the
/// median of the last [_window] fixes. A level is reached only after [holdFor] above it.
///
/// Rules (one ride):
///  * first time above [highM] (3,000 m): "You are above 3,000 m. Ride slower, drink water, watch
///    for headache or dizziness."
///  * first time above [veryHighM] (4,500 m): the stronger wording.
///  * a climb of more than [climbM] (800 m) within [climbWindow] (60 min), once above
///    [climbFromM] (2,500 m, where altitude sickness starts to matter): "Fast climb: take a
///    10-minute break." Again only after another full climb.
///  * at most one reminder every [repeatEvery] (45 min); a level reminder waits for it.
class AltitudeCare {
  AltitudeCare({
    this.repeatEvery = const Duration(minutes: 45),
    this.holdFor = const Duration(seconds: 30),
    this.climbWindow = const Duration(minutes: 60),
  });

  static const double highM = 3000;
  static const double veryHighM = 4500;
  static const double climbM = 800;
  static const double climbFromM = 2500;
  static const int _window = 5;

  final Duration repeatEvery;
  final Duration holdFor;
  final Duration climbWindow;

  final List<double> _recent = [];
  final List<(int, double)> _history = []; // (ts, smoothed alt), one per 30 s at most
  int _lastNoticeMs = -1 << 40;
  bool _saidHigh = false;
  bool _saidVeryHigh = false;
  int _aboveHighSince = 0;
  int _aboveVeryHighSince = 0;
  int _lastTs = 0;

  /// Smoothed altitude of the last fixes (null before any usable fix).
  double? altitudeM;

  void reset() {
    _recent.clear();
    _history.clear();
    _lastNoticeMs = -1 << 40;
    _saidHigh = _saidVeryHigh = false;
    _aboveHighSince = _aboveVeryHighSince = 0;
    _lastTs = 0;
    altitudeM = null;
  }

  static bool usable(double? altM) => altM != null && altM.isFinite && altM != 0 && altM > -500 && altM < 9000;

  AltitudeNotice? onFix({required int ts, required double? altM}) {
    if (!usable(altM) || ts < _lastTs) return null;
    _lastTs = ts;
    _recent.add(altM!);
    if (_recent.length > _window) _recent.removeAt(0);
    final sorted = [..._recent]..sort();
    final alt = sorted[sorted.length ~/ 2];
    altitudeM = alt;
    if (_history.isEmpty || ts - _history.last.$1 >= 30000) _history.add((ts, alt));
    final cutoff = ts - climbWindow.inMilliseconds;
    while (_history.isNotEmpty && _history.first.$1 < cutoff) {
      _history.removeAt(0);
    }

    _aboveHighSince = alt >= highM ? (_aboveHighSince == 0 ? ts : _aboveHighSince) : 0;
    _aboveVeryHighSince = alt >= veryHighM ? (_aboveVeryHighSince == 0 ? ts : _aboveVeryHighSince) : 0;
    final canSpeak = ts - _lastNoticeMs >= repeatEvery.inMilliseconds;
    if (!canSpeak) return null;

    if (!_saidVeryHigh && _aboveVeryHighSince != 0 && ts - _aboveVeryHighSince >= holdFor.inMilliseconds) {
      _saidVeryHigh = _saidHigh = true;
      return _notice(ts, const AltitudeNotice(
        kind: AltitudeNoticeKind.veryHigh,
        title: 'Above 4,500 m: thin air',
        message: 'Ride slowly, rest often, drink water. Headache, breathlessness or confusion: go lower.',
        speech: 'You are above 4,500 metres. The air is thin. Ride slowly, rest often and drink water. '
            'If you get a bad headache, feel breathless or confused, go lower.',
      ));
    }
    if (!_saidHigh && _aboveHighSince != 0 && ts - _aboveHighSince >= holdFor.inMilliseconds) {
      _saidHigh = true;
      return _notice(ts, const AltitudeNotice(
        kind: AltitudeNoticeKind.high,
        title: 'Above 3,000 m',
        message: 'Ride slower, drink water, watch for headache or dizziness.',
        speech: 'You are above 3,000 metres. Ride slower, drink water, watch for headache or dizziness.',
      ));
    }
    if (alt >= climbFromM && _history.length >= 2) {
      var low = alt;
      for (final h in _history) {
        if (h.$2 < low) low = h.$2;
      }
      if (alt - low > climbM) {
        // Start counting the next climb from here.
        _history
          ..clear()
          ..add((ts, alt));
        return _notice(ts, const AltitudeNotice(
          kind: AltitudeNoticeKind.fastClimb,
          title: 'Fast climb',
          message: 'Take a 10-minute break to let your body adjust.',
          speech: 'Fast climb. Take a 10-minute break.',
        ));
      }
    }
    return null;
  }

  AltitudeNotice _notice(int ts, AltitudeNotice n) {
    _lastNoticeMs = ts;
    return n;
  }
}
