import '../../core/constants/safety_constants.dart';
import '../tracking/track_point.dart';
import 'accel_bucket.dart';

/// Counts hard stops for the rider's own post-ride summary. A bucket whose peak
/// is between [SafetyConstants.hardBrakePeakG] and [SafetyConstants.crashImpactG]
/// (a crash-level peak belongs to the crash detector) counts when the fixes show
/// a speed drop of at least [SafetyConstants.hardBrakeDropKmh] within
/// [SafetyConstants.hardBrakeWindow] that ends at or after the bucket. One count
/// per [SafetyConstants.hardBrakeDedupe]. Fed only while the crash detector
/// already has the sensor, so this switches nothing on. Pure, no timers.
class HardBrakeCounter {
  final List<TrackPoint> _fixes = [];
  final List<int> _at = [];
  int _lastCountAt = -1 << 40;

  /// A bucket waiting for fixes that may still show the drop (expires after the window).
  int? _candidateMs;

  int get count => _at.length;

  /// When each hard stop happened (epoch ms).
  List<int> get atMs => List.unmodifiable(_at);

  void onFix(TrackPoint p) {
    _fixes.add(p);
    final keepFrom = p.ts - SafetyConstants.hardBrakeFixWindow.inMilliseconds;
    while (_fixes.isNotEmpty && _fixes.first.ts < keepFrom) {
      _fixes.removeAt(0);
    }
    _evaluate(p.ts);
  }

  void onAccel(AccelBucket b) {
    if (b.peakG < SafetyConstants.hardBrakePeakG || b.peakG >= SafetyConstants.crashImpactG) {
      _evaluate(b.tMs);
      return;
    }
    if (b.tMs - _lastCountAt < SafetyConstants.hardBrakeDedupe.inMilliseconds) return;
    _candidateMs = b.tMs;
    _evaluate(b.tMs);
  }

  void _evaluate(int nowMs) {
    final c = _candidateMs;
    if (c == null) return;
    final window = SafetyConstants.hardBrakeWindow.inMilliseconds;
    if (nowMs - c > window + 1000) {
      _candidateMs = null; // no drop showed up in time
      return;
    }
    // A drop: an earlier fast fix, then a slow fix at or after the bucket, within the window,
    // and the speed was not already down before the bucket (a plateau is not a brake).
    for (var i = _fixes.length - 1; i >= 0; i--) {
      final after = _fixes[i];
      if (after.ts < c) break;
      for (var j = i - 1; j >= 0; j--) {
        final before = _fixes[j];
        if (after.ts - before.ts > window) break;
        if (before.speedKmh - after.speedKmh >= SafetyConstants.hardBrakeDropKmh) {
          _count(c);
          return;
        }
        if (before.ts <= c && before.speedKmh - after.speedKmh < SafetyConstants.hardBrakeDropKmh / 2) break;
      }
    }
  }

  void _count(int atMs) {
    _candidateMs = null;
    if (atMs - _lastCountAt < SafetyConstants.hardBrakeDedupe.inMilliseconds) return;
    _lastCountAt = atMs;
    _at.add(atMs);
  }

  void reset() {
    _fixes.clear();
    _at.clear();
    _lastCountAt = -1 << 40;
    _candidateMs = null;
  }
}
