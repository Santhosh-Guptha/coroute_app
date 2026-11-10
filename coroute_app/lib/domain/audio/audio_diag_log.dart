// 3.55 audio diagnostics: a small in-memory ride log of what the audio output did (alert decided,
// line handed to the speech engine, speech started, audio focus result, music volume changes,
// fallbacks), so a device test can see what happened. Pure Dart, no Flutter.
//
// Nothing personal is ever written: no spoken text, no names, no places. Only priorities, keys
// with their numbers stripped, timings, focus / volume results and route kinds
// ('speaker' / 'bt' / 'wired'). The native side writes the same kind of lines to logcat
// (`adb logcat -s CoRouteAudio`).

/// One diagnostic line.
class AudioDiagEntry {
  final int atMs;
  final String line;
  const AudioDiagEntry(this.atMs, this.line);

  @override
  String toString() => '${DateTime.fromMillisecondsSinceEpoch(atMs).toIso8601String().substring(11, 23)} $line';
}

class AudioDiagLog {
  AudioDiagLog._();

  /// Lines kept (oldest dropped first).
  static const int capacity = 300;

  static final List<AudioDiagEntry> _entries = [];

  /// Optional sink (main.dart may forward lines to debugPrint / a ride log). Null = memory only.
  static void Function(String line)? sink;

  /// Clock (tests).
  static int Function() clock = () => DateTime.now().millisecondsSinceEpoch;

  /// The kept lines, oldest first.
  static List<AudioDiagEntry> get entries => List.unmodifiable(_entries);

  /// Adds a line. Callers pass no free text from users or places.
  static void add(String line) {
    final e = AudioDiagEntry(clock(), line);
    _entries.add(e);
    if (_entries.length > capacity) _entries.removeRange(0, _entries.length - capacity);
    final s = sink;
    if (s != null) {
      try {
        s('audio: $line');
      } catch (_) {}
    }
  }

  /// A dedupe key without its private parts (a key that is the spoken text is not logged at all):
  /// only what comes before the first ':' is kept, with
  /// digits replaced ('road_limit_road:50' -> 'road_limit_road:*', 'SOS:id' -> 'SOS:*',
  /// 'siren_newEpisode_12' -> 'siren_newEpisode_#').
  static String safeKey(String key) {
    if (key.contains(' ')) return '(text)'; // the line itself was the key: never logged
    final i = key.indexOf(':');
    var head = i < 0 ? key : key.substring(0, i);
    if (head.length > 32) head = head.substring(0, 32);
    head = head.replaceAll(RegExp(r'[0-9]+'), '#');
    return i < 0 ? head : '$head:*';
  }

  static void clear() => _entries.clear();

  /// The log as text (for a support screen / export).
  static String dump() => _entries.join('\n');
}
