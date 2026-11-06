import 'dart:math' as math;

/// When to open the realtime socket again. Pure logic: no timers, no sockets.
///
/// * After an unexpected close or a failed connect: a quick first retry
///   ([quickMin] to [quickMax], random), then exponential backoff with full jitter
///   (random between [quickMin] and min([cap], [base] x 2^n)). Riders whose gateway
///   failed come back within about a second, and a long outage costs little battery.
/// * [reset] once the server has taken the rider back (the SNAPSHOT of the ride, or HELLO
///   when not in a ride): the next drop starts with the quick retry again.
/// * A move the server asked for (RECONNECT: handback or shutdown) waits the server's delay
///   plus a small local jitter (at most [serverJitterMax]) and is not a failure: the backoff
///   stays where it was.
class ReconnectPolicy {
  ReconnectPolicy({math.Random? random}) : _random = random ?? math.Random();

  static const Duration quickMin = Duration(milliseconds: 300);
  static const Duration quickMax = Duration(milliseconds: 1000);
  static const Duration base = Duration(milliseconds: 1000);
  static const Duration cap = Duration(seconds: 10);
  static const Duration serverJitterMax = Duration(milliseconds: 500);

  /// A server delay beyond this is treated as this (a bad value must not park the phone).
  static const Duration serverDelayMax = Duration(minutes: 2);

  final math.Random _random;
  int _failures = 0;

  /// Unexpected closes or failed connects since the last [reset].
  int get failures => _failures;

  /// The wait before the next attempt after an unexpected close or a failed connect.
  /// Counts one failure.
  Duration nextAfterFailure() {
    final n = _failures;
    _failures++;
    if (n == 0) return _between(quickMin.inMilliseconds, quickMax.inMilliseconds);
    final ceiling = math.min(cap.inMilliseconds, base.inMilliseconds * (1 << math.min(n, 16)));
    return _between(quickMin.inMilliseconds, ceiling);
  }

  /// The wait before reconnecting when the server asked for it ([delayMs] from RECONNECT).
  /// Not a failure: [failures] does not change.
  Duration afterServerRequest(int? delayMs) {
    final d = (delayMs ?? 0).clamp(0, serverDelayMax.inMilliseconds).toInt();
    return Duration(milliseconds: d + _random.nextInt(serverJitterMax.inMilliseconds + 1));
  }

  /// The server has the rider back: the next drop retries quickly again.
  void reset() => _failures = 0;

  Duration _between(int lo, int hi) => Duration(milliseconds: hi <= lo ? lo : lo + _random.nextInt(hi - lo + 1));
}
