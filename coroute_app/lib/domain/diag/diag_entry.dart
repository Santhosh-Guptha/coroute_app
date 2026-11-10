// 3.55 diagnostics log (docs/features_355/diagnostics_logs.md): one structured log entry and its
// JSON-lines encoding. Pure Dart, no Flutter, so it is tested with plain `dart run` and shared by
// the writer (DiagLogService), the in-app viewer and the bundle that is sent to CoRoute.
//
// A line is small on purpose (short keys):
//   {"t":1731234567890,"m":123456,"l":"I","c":"sos","e":"raise","f":{"src":"manual"},
//    "b":"3.55.0+10020","s":"k3f9a2","r":"G-1234","n":42}
// t = wall clock ms, m = monotonic ms since the app started (ordering across clock changes),
// l = level, c = category, e = event, f = small key/value fields (already redacted),
// b = app build, s = session id (one per app start), r = ride id (only in a ride), n = sequence.

import 'dart:convert';

/// How important an entry is. Info and above are always kept; debug only while "Detailed logs"
/// is on (see DiagLevelGate).
enum DiagLevel {
  debug('D'),
  info('I'),
  warn('W'),
  error('E');

  const DiagLevel(this.code);
  final String code;

  static DiagLevel fromCode(String? c) => switch (c) {
        'D' => DiagLevel.debug,
        'W' => DiagLevel.warn,
        'E' => DiagLevel.error,
        _ => DiagLevel.info,
      };

  bool atLeast(DiagLevel other) => index >= other.index;
}

/// What part of the app wrote the entry. The wire name is what the viewer, the server and
/// tool/diag/analyze_logs.js filter on.
enum DiagCat {
  safety('safety'),
  sos('sos'),
  crash('crash'),
  alerts('alerts'),
  speed('speed'),
  location('location'),
  audio('audio'),
  siren('siren'),
  intercom('intercom'),
  network('network'),
  realtime('realtime'),
  push('push'),
  social('social'),
  ride('ride'),
  battery('battery'),
  permissions('permissions'),
  lifecycle('lifecycle'),
  errors('errors'),
  diag('diag');

  const DiagCat(this.wire);
  final String wire;

  static final Map<String, DiagCat> _byWire = {for (final c in DiagCat.values) c.wire: c};
  static DiagCat fromWire(String? w) => _byWire[w] ?? DiagCat.errors;

  /// Safety-relevant categories are written to disk at once (never waiting for the 2 s batch).
  bool get urgent => this == DiagCat.safety || this == DiagCat.sos || this == DiagCat.crash;
}

class DiagEntry {
  final int wallMs;
  final int monoMs;
  final DiagLevel level;
  final DiagCat cat;
  final String event;
  final Map<String, Object?> fields;
  final String build;
  final String session;
  final String? ride;
  final int seq;

  const DiagEntry({
    required this.wallMs,
    required this.monoMs,
    required this.level,
    required this.cat,
    required this.event,
    this.fields = const {},
    this.build = '',
    this.session = '',
    this.ride,
    this.seq = 0,
  });

  Map<String, Object?> toJson() => {
        't': wallMs,
        'm': monoMs,
        'l': level.code,
        'c': cat.wire,
        'e': event,
        if (fields.isNotEmpty) 'f': fields,
        if (build.isNotEmpty) 'b': build,
        if (session.isNotEmpty) 's': session,
        if (ride != null && ride!.isNotEmpty) 'r': ride,
        'n': seq,
      };

  /// One JSON line (no newline).
  String encode() => jsonEncode(toJson());

  /// Parses one line; null for anything that is not an entry (a torn last line after a crash,
  /// a meta header, garbage).
  static DiagEntry? decode(String line) {
    final s = line.trim();
    if (s.isEmpty || !s.startsWith('{')) return null;
    try {
      final d = jsonDecode(s);
      if (d is! Map) return null;
      final t = d['t'];
      final e = d['e'];
      if (t is! num || e is! String) return null;
      final f = d['f'];
      return DiagEntry(
        wallMs: t.toInt(),
        monoMs: d['m'] is num ? (d['m'] as num).toInt() : 0,
        level: DiagLevel.fromCode(d['l']?.toString()),
        cat: DiagCat.fromWire(d['c']?.toString()),
        event: e,
        fields: f is Map ? {for (final k in f.keys) k.toString(): f[k]} : const {},
        build: d['b']?.toString() ?? '',
        session: d['s']?.toString() ?? '',
        ride: d['r']?.toString(),
        seq: d['n'] is num ? (d['n'] as num).toInt() : 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// A short line for the in-app viewer: "14:03:22.120 W sos raise src=manual".
  String get display {
    final d = DateTime.fromMillisecondsSinceEpoch(wallMs);
    String two(int v) => v.toString().padLeft(2, '0');
    final ms = (wallMs % 1000).toString().padLeft(3, '0');
    final f = fields.entries.map((e) => '${e.key}=${e.value}').join(' ');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}.$ms ${level.code} ${cat.wire} $event${f.isEmpty ? '' : ' $f'}';
  }
}
