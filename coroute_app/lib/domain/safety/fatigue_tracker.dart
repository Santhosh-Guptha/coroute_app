import '../../core/constants/safety_constants.dart';
import '../tracking/track_point.dart';

/// "Time for a break": riding for 2 h without a stop of 10 min or more.
///
/// Pure, fed with the rider's own fixes (no timer). A stretch starts with the
/// first moving fix. A stop of [breakFor] or more (slow fixes, or no fixes at
/// all for that long, which is what a parked phone with a GPS distance filter
/// looks like) ends it. Shorter stops count as riding time. [onFix] returns
/// true once when the stretch reaches [rideFor], then again every [remindAgain]
/// until a real break.
class FatigueTracker {
  FatigueTracker({
    this.rideFor = SafetyConstants.fatigueRideFor,
    this.breakFor = SafetyConstants.fatigueBreakFor,
    this.remindAgain = SafetyConstants.fatigueRemindAgain,
    this.movingKmh = SafetyConstants.fatigueMovingKmh,
  });

  final Duration rideFor;
  final Duration breakFor;
  final Duration remindAgain;
  final double movingKmh;

  int? _stretchStart;
  int? _stopStart;
  int? _lastTs;
  int? _lastReminder;

  /// Start of the current riding stretch (null when on a break).
  int? get stretchStart => _stretchStart;

  bool onFix(TrackPoint p) {
    final t = p.ts;
    final last = _lastTs;
    if (last != null && t < last) return false; // out of order
    _lastTs = t;
    // A long gap without fixes: the phone sat still (or CoRoute was closed).
    if (last != null && t - last >= breakFor.inMilliseconds) _takeBreak();

    final moving = p.speedKmh >= movingKmh;
    if (moving) {
      _stopStart = null;
      _stretchStart ??= t;
    } else {
      _stopStart ??= t;
      if (t - _stopStart! >= breakFor.inMilliseconds) {
        _takeBreak();
        return false;
      }
    }
    final start = _stretchStart;
    if (start == null || t - start < rideFor.inMilliseconds) return false;
    final reminded = _lastReminder;
    if (reminded == null || t - reminded >= remindAgain.inMilliseconds) {
      _lastReminder = t;
      return true;
    }
    return false;
  }

  void _takeBreak() {
    _stretchStart = null;
    _lastReminder = null;
  }

  void reset() {
    _stretchStart = null;
    _stopStart = null;
    _lastTs = null;
    _lastReminder = null;
  }
}
