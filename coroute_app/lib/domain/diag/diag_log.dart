// 3.55 diagnostics log: the one call every part of the app uses (pure Dart, no Flutter, no I/O).
//
//   DiagLog.info(DiagCat.sos, 'raise', {'src': 'manual', 'queued': true});
//   DiagLog.warn(DiagCat.realtime, 'disconnect', {'code': 1006});
//
// An entry is redacted here (DiagRedact.fields), stamped with the build, session and ride ids,
// kept in a small memory ring (the in-app viewer) and handed to [sink] (DiagLogService: an async
// write queue to rotating files). Calling it never throws, never awaits and never blocks: it is
// safe on alert and SOS paths. Before the writer is ready, entries wait in the ring and are
// handed over when [sink] is set ([drainEarly]).
//
// Privacy rules: docs/features_355/diagnostics_logs.md#privacy (enforced in DiagRedact).

import 'diag_entry.dart';
import 'diag_policy.dart';
import 'diag_redact.dart';

export 'diag_entry.dart';

class DiagLog {
  DiagLog._();

  /// Entries kept in memory for the in-app viewer (oldest dropped first).
  static const int ringSize = 500;

  /// App build, e.g. '3.55.0+10020' (main.dart, after the package info is read).
  static String build = '';

  /// One id per app start.
  static String session = _newSession();

  /// The ride id while a ride runs (group id, or `solo-<ms>` for an offline solo ride).
  static String? rideId;

  /// Detailed (debug) logs on until this time (ms since epoch); 0 = off.
  static int detailedUntilMs = 0;

  /// Salt for [userHash] (random per install, set by DiagLogService; empty = ids are dropped).
  static String salt = '';

  /// Where entries go once the writer is ready. Null: memory ring only.
  static void Function(DiagEntry e)? sink;

  /// Clocks (tests).
  static int Function() clock = () => DateTime.now().millisecondsSinceEpoch;
  static final Stopwatch _mono = Stopwatch()..start();
  static int Function() monoClock = () => _mono.elapsedMilliseconds;

  /// Called for every warn / error entry (the service remembers the last error).
  static void Function(DiagEntry e)? onProblem;

  static final List<DiagEntry> _ring = [];
  static final List<DiagEntry> _early = [];
  static int _seq = 0;
  static bool _inLog = false;

  /// GPS cadence / accuracy summary (one entry per 30 s of fixes).
  static final GpsDiagSummary gps = GpsDiagSummary();

  /// Shared sampler for noisy events.
  static final DiagSampler sampler = DiagSampler();

  static String _newSession() {
    final t = DateTime.now().microsecondsSinceEpoch;
    return (t ^ (t >> 17) ^ 0x5f3759df).toUnsigned(32).toRadixString(36);
  }

  /// True while detailed (debug) logs are written.
  static bool get detailed => DiagLevelGate.allows(DiagLevel.debug, detailedUntilMs: detailedUntilMs, nowMs: clock());

  static DiagEntry? debug(DiagCat cat, String event, [Map<String, Object?>? fields]) => log(DiagLevel.debug, cat, event, fields);
  static DiagEntry? info(DiagCat cat, String event, [Map<String, Object?>? fields]) => log(DiagLevel.info, cat, event, fields);
  static DiagEntry? warn(DiagCat cat, String event, [Map<String, Object?>? fields]) => log(DiagLevel.warn, cat, event, fields);
  static DiagEntry? error(DiagCat cat, String event, [Map<String, Object?>? fields]) => log(DiagLevel.error, cat, event, fields);

  /// Writes one entry (redacted). Returns it, or null when the level is filtered out.
  static DiagEntry? log(DiagLevel level, DiagCat cat, String event, [Map<String, Object?>? fields]) {
    if (_inLog) return null; // a sink that logs again must not recurse
    _inLog = true;
    try {
      final now = clock();
      if (!DiagLevelGate.allows(level, detailedUntilMs: detailedUntilMs, nowMs: now)) return null;
      var f = DiagRedact.fields(fields);
      final ride = rideId;
      if (ride == null && (f.containsKey('lat') || f.containsKey('lng') || f.containsKey('lon'))) {
        // Location only during a ride.
        f = Map<String, Object?>.from(f)
          ..remove('lat')
          ..remove('lng')
          ..remove('lon');
      }
      final e = DiagEntry(
        wallMs: now,
        monoMs: monoClock(),
        level: level,
        cat: cat,
        event: DiagRedact.event(event),
        fields: f,
        build: build,
        session: session,
        ride: ride,
        seq: ++_seq,
      );
      _ring.add(e);
      if (_ring.length > ringSize) _ring.removeRange(0, _ring.length - ringSize);
      final s = sink;
      if (s == null) {
        _early.add(e);
        if (_early.length > ringSize) _early.removeRange(0, _early.length - ringSize);
      } else {
        s(e);
      }
      if (level.atLeast(DiagLevel.warn)) onProblem?.call(e);
      return e;
    } catch (_) {
      return null;
    } finally {
      _inLog = false;
    }
  }

  /// Hands entries written before the writer was ready to [sink] (once).
  static void drainEarly() {
    final s = sink;
    if (s == null || _early.isEmpty) return;
    final items = List<DiagEntry>.from(_early);
    _early.clear();
    for (final e in items) {
      try {
        s(e);
      } catch (_) {}
    }
  }

  /// The last entries, oldest first (in-app viewer).
  static List<DiagEntry> get recent => List.unmodifiable(_ring);

  /// Clears the memory ring ("Clear logs").
  static void clearRecent() {
    _ring.clear();
    _early.clear();
  }

  /// A user id as a short salted hash ('' when no salt yet: then no id is written at all).
  static String userHash(String? userId) => (userId == null || userId.isEmpty || salt.isEmpty) ? '' : DiagRedact.hashId(userId, salt);

  /// One GPS fix for the 30 s summary (location: rounded, ride only; see [log]).
  static void gpsFix({required int tMs, required double accuracyM, required bool rejected, required double kmh, double? lat, double? lng}) {
    final s = gps.add(tMs: tMs, accuracyM: accuracyM, rejected: rejected, kmh: kmh);
    if (s == null) return;
    info(DiagCat.location, 'gps_summary', {...s, 'lat': ?lat, 'lng': ?lng});
  }

  /// A caught error with its type and top frames (never the full message when it may hold data:
  /// the message is scrubbed by DiagRedact.text).
  static void caught(DiagCat cat, String event, Object error, [StackTrace? stack, Map<String, Object?>? extra]) {
    log(DiagLevel.error, cat, event, {
      'type': error.runtimeType.toString(),
      'what': error.toString(),
      if (stack != null) 'stack': DiagRedact.stackTop(stack),
      ...?extra,
    });
  }

  /// Tests: back to a clean state.
  static void resetForTest() {
    _ring.clear();
    _early.clear();
    _seq = 0;
    sink = null;
    onProblem = null;
    rideId = null;
    detailedUntilMs = 0;
    salt = '';
    build = '';
    gps.reset();
  }
}
