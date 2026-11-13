import 'dart:async';

/// A position for an SOS and where it came from.
typedef SosPosition = ({double lat, double lng, String source});

/// What the fast path did (for the diagnostics log and the latency tests).
class SosSendTiming {
  const SosSendTiming({required this.source, required this.waitedMs, required this.hadPosition});
  final String source;

  /// Time from the hold completing to the send call.
  final int waitedMs;
  final bool hadPosition;
}

/// The order in which an SOS finds its position (round 7; pure). The rule: NEVER wait when a
/// position is already known.
///
///  1. Positions the app already holds (my rider record, the safety service's last fix): the
///     SOS is sent in the same call, before any await. This is the normal case in a ride.
///  2. No position in memory (the ride just started, GPS not yet locked): the system's last
///     known position, waited for at most [quick] (300 ms). It is usually seconds old and far
///     better than waiting.
///  3. Still nothing: a fresh fix, waited for at most [slow] (5 s, the 3.55 behaviour), then the
///     SOS goes out whatever happened (with 0,0 the gateway and the group still learn that the
///     rider needs help; the ride's telemetry carries the position once GPS locks).
///
/// Before round 7 step 2 did not exist and step 1 looked at the rider record only: a rider with
/// a fresh fix in the safety service but no telemetry echo yet waited up to 5 s.
class SosFastPath {
  SosFastPath._();

  static const Duration quick = Duration(milliseconds: 300);
  static const Duration slow = Duration(seconds: 5);

  static bool usable(double? lat, double? lng) => lat != null && lng != null && lat.isFinite && lng.isFinite && (lat != 0 || lng != 0) && lat.abs() <= 90 && lng.abs() <= 180;

  /// The first usable position of [sources] (tried in order; a throwing source is skipped).
  static SosPosition? cached(List<SosPosition? Function()> sources) {
    for (final s in sources) {
      try {
        final p = s();
        if (p != null && usable(p.lat, p.lng)) return p;
      } catch (_) {}
    }
    return null;
  }

  static Future<SosPosition?> _bounded(Future<SosPosition?> Function() f, Duration max) async {
    try {
      final p = await f().timeout(max, onTimeout: () => null);
      return p != null && usable(p.lat, p.lng) ? p : null;
    } catch (_) {
      return null;
    }
  }

  /// Sends the SOS through [send] as early as the rules above allow. With a cached position
  /// [send] has been called when this function RETURNS its future (no await before it).
  static Future<SosSendTiming> run({
    required List<SosPosition? Function()> cachedSources,
    required Future<SosPosition?> Function() lastKnown,
    required Future<SosPosition?> Function() current,
    required void Function(double lat, double lng) send,
    int Function()? now,
    Duration quick = SosFastPath.quick,
    Duration slow = SosFastPath.slow,
  }) {
    final clock = now ?? () => DateTime.now().millisecondsSinceEpoch;
    final t0 = clock();
    final c = cached(cachedSources);
    if (c != null) {
      send(c.lat, c.lng);
      return Future<SosSendTiming>.value(SosSendTiming(source: c.source, waitedMs: clock() - t0, hadPosition: true));
    }
    return () async {
      final p = await _bounded(lastKnown, quick) ?? await _bounded(current, slow);
      send(p?.lat ?? 0.0, p?.lng ?? 0.0);
      return SosSendTiming(source: p?.source ?? 'none', waitedMs: clock() - t0, hadPosition: p != null);
    }();
  }
}
