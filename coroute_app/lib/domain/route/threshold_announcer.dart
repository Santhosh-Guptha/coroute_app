/// Says each distance threshold once, while getting closer.
///
/// * The first distance arms it silently: thresholds already passed (or
///   within [hysteresisM] above it) are never announced.
/// * Afterwards a threshold fires the first time the distance is at or
///   below it. When one fix jumps over several thresholds only the nearest
///   one is returned (the others are marked done).
/// * A fired threshold never fires again, so GPS jitter around a boundary
///   (980 m, 1020 m, 990 m) says "1 kilometer" once.
///
/// Pure: no timers, no clock.
class ThresholdAnnouncer {
  ThresholdAnnouncer(List<int> thresholdsM, {this.hysteresisM = 50})
      : _thresholds = (List<int>.of(thresholdsM)..sort((a, b) => b.compareTo(a)));

  final List<int> _thresholds;
  final double hysteresisM;
  final Set<int> _done = {};
  bool _armed = false;

  /// The thresholds, largest first.
  List<int> get thresholds => List.unmodifiable(_thresholds);

  /// True once every threshold was announced or skipped.
  bool get finished => _armed && _done.length >= _thresholds.length;

  /// The threshold just crossed (metres), or null.
  int? onDistance(double m) {
    if (!m.isFinite) return null;
    final d = m < 0 ? 0.0 : m;
    if (!_armed) {
      _armed = true;
      for (final t in _thresholds) {
        if (d <= t + hysteresisM) _done.add(t);
      }
      return null;
    }
    int? hit;
    for (final t in _thresholds) {
      if (_done.contains(t)) continue;
      if (d <= t) {
        _done.add(t);
        hit = t; // descending order: the last one set is the nearest
      }
    }
    return hit;
  }

  /// Starts over (a new target).
  void reset() {
    _done.clear();
    _armed = false;
  }
}
