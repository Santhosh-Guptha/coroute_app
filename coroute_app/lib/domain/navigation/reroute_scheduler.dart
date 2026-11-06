import 'reroute_rules.dart';

/// Why a new-route request may not start now.
enum RerouteGate {
  /// It may start.
  go,

  /// One is already on its way.
  inFlight,

  /// Too soon after the last one (minimum interval, or back-off after failures).
  tooSoon,

  /// No network: nothing is asked for.
  offline,

  /// Gave up after [RerouteRules.maxFailures] failures in a row.
  gaveUp,
}

/// When a new route may be asked for. Pure: the caller passes the time and
/// asks on its next fix; nothing here waits or polls.
///
/// * One request at a time (single flight); a request with no answer after
///   [RerouteRules.requestTimeout] counts as failed ([expire]).
/// * At most one per [RerouteRules.minRerouteInterval] from the last start;
///   after a failure the wait doubles (15 s, 15 s, 30 s).
/// * After [RerouteRules.maxFailures] failures in a row it gives up: no more
///   requests in this departure, except one quiet try per
///   [RerouteRules.retryAfterGiveUp]. A success, coming back to the route
///   ([newEpisode]) or a new group route ([reset]) starts over.
/// * Never while offline; going offline is not a failure.
class RerouteScheduler {
  int? _lastStartMs;
  int _failures = 0;
  bool _gaveUp = false;
  int? _gaveUpAtMs;
  int _ticket = 0;
  bool _inFlight = false;

  bool get inFlight => _inFlight;
  int get failures => _failures;
  bool get gaveUp => _gaveUp;

  /// The wait after the last start before the next request.
  Duration get wait {
    final base = RerouteRules.minRerouteInterval;
    if (_failures <= 1) return base;
    final shift = _failures - 1 > 4 ? 4 : _failures - 1;
    return base * (1 << shift);
  }

  /// Whether a request may start at [nowMs].
  RerouteGate check({required int nowMs, required bool online}) {
    expire(nowMs);
    if (_inFlight) return RerouteGate.inFlight;
    if (!online) return RerouteGate.offline;
    if (_gaveUp) {
      final at = _gaveUpAtMs ?? nowMs;
      if (nowMs - at < RerouteRules.retryAfterGiveUp.inMilliseconds) return RerouteGate.gaveUp;
    }
    final last = _lastStartMs;
    if (last != null && nowMs - last < wait.inMilliseconds) return RerouteGate.tooSoon;
    return RerouteGate.go;
  }

  /// A request starts now; returns its ticket for [finish].
  int start(int nowMs) {
    _lastStartMs = nowMs;
    _inFlight = true;
    if (_gaveUp) _gaveUpAtMs = nowMs; // the quiet retry: the next one waits again
    return ++_ticket;
  }

  /// The request with [ticket] finished. [ok] false for no route; [online]
  /// false when the network was gone (not counted as a failure). Returns
  /// true when this result is current (not timed out, not from before a reset).
  bool finish(int ticket, {required bool ok, bool online = true, required int nowMs}) {
    if (ticket != _ticket || !_inFlight) return false;
    _inFlight = false;
    if (ok) {
      _failures = 0;
      _gaveUp = false;
      _gaveUpAtMs = null;
    } else if (online) {
      _fail(nowMs);
    }
    return true;
  }

  /// A request on its way for longer than [RerouteRules.requestTimeout]
  /// counts as failed. Returns true when that just happened.
  bool expire(int nowMs) {
    final last = _lastStartMs;
    if (!_inFlight || last == null || nowMs - last < RerouteRules.requestTimeout.inMilliseconds) return false;
    _inFlight = false;
    _ticket++; // its late answer is ignored
    _fail(nowMs);
    return true;
  }

  void _fail(int nowMs) {
    _failures++;
    if (_failures >= RerouteRules.maxFailures && !_gaveUp) {
      _gaveUp = true;
      _gaveUpAtMs = nowMs;
    }
  }

  /// Drop the request on its way (not a failure); its answer is ignored.
  /// Keeps the time it started (the minimum interval still applies).
  void cancel() {
    if (!_inFlight) return;
    _inFlight = false;
    _ticket++;
  }

  /// Back on the route: the next departure starts with no failures. Keeps
  /// the time of the last request (the minimum interval still applies).
  void newEpisode() {
    _failures = 0;
    _gaveUp = false;
    _gaveUpAtMs = null;
  }

  /// Forget everything (a new group route, a new ride); a request on its
  /// way is ignored when it answers.
  void reset() {
    _lastStartMs = null;
    _failures = 0;
    _gaveUp = false;
    _gaveUpAtMs = null;
    _inFlight = false;
    _ticket++;
  }
}
