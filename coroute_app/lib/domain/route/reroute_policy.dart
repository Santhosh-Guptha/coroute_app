import '../../core/constants/route_constants.dart';

/// When a new route may be asked for. Pure: the caller passes the time and
/// asks on its next location fix; nothing here waits or polls.
///
/// * One request at a time.
/// * At most one per [RouteConstants.rerouteMinInterval], or per
///   [RouteConstants.rerouteMinIntervalLowData] with data saver on.
/// * None while offline.
/// * After a failure the wait doubles, up to [RouteConstants.rerouteMaxBackoff];
///   a success resets it.
class ReroutePolicy {
  int? _lastStartMs;
  int _failures = 0;
  bool _inFlight = false;

  bool get inFlight => _inFlight;
  int get failures => _failures;

  /// How long to wait after the last request before the next one.
  Duration waitFor({required bool lowData}) {
    final base = lowData ? RouteConstants.rerouteMinIntervalLowData : RouteConstants.rerouteMinInterval;
    if (_failures == 0) return base;
    final shift = _failures > 17 ? 16 : _failures - 1;
    var backoffMs = RouteConstants.rerouteMinInterval.inMilliseconds * (1 << shift);
    final cap = RouteConstants.rerouteMaxBackoff.inMilliseconds;
    if (backoffMs > cap) backoffMs = cap;
    return backoffMs > base.inMilliseconds ? Duration(milliseconds: backoffMs) : base;
  }

  /// True when a request may start now.
  bool canRequest({required int nowMs, required bool online, required bool lowData}) {
    if (_inFlight || !online) return false;
    final last = _lastStartMs;
    if (last == null) return true;
    return nowMs - last >= waitFor(lowData: lowData).inMilliseconds;
  }

  /// A request starts now.
  void started(int nowMs) {
    _lastStartMs = nowMs;
    _inFlight = true;
  }

  /// The request finished: [ok] false for no route (error, offline, timeout).
  void finished({required bool ok}) {
    _inFlight = false;
    _failures = ok ? 0 : _failures + 1;
  }

  /// Forget the history (a new ride).
  void reset() {
    _lastStartMs = null;
    _failures = 0;
    _inFlight = false;
  }
}
