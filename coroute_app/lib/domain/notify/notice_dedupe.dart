// 3.55 follow-up: one notice per event, whichever way it arrives.
//
// With two gateway nodes a rider may get the same friend request / crew invite / poll / ride
// invite twice: as the in-app socket message and as an FCM push (the push service decides
// "connected" from both nodes, but the presence list can lag a heartbeat). The gateway gives both
// the same `eventId` (gateway/src/push.js stampEvent: TYPE:requestId / inviteId / pollId); the app
// shows the first one and ignores a second one with the same id within [window].
//
// Pure Dart: no Flutter, no I/O (test/notice_dedupe_355_test.dart).

class NoticeDedupe {
  NoticeDedupe({int Function()? clock, this.window = const Duration(minutes: 10), this.maxIds = 200}) : _clock = clock ?? _wall;

  static int _wall() => DateTime.now().millisecondsSinceEpoch;

  /// The app-wide instance (socket handlers and the foreground push snackbar share it).
  static final NoticeDedupe shared = NoticeDedupe();

  static final RegExp _id = RegExp(r'^[A-Za-z0-9_\-:.]{1,80}$');

  final int Function() _clock;
  final Duration window;
  final int maxIds;
  final Map<String, int> _seen = {};

  /// The event id of a socket message or push payload, or null (older gateways send none).
  static String? idOf(Object? raw) {
    if (raw is! String) return null;
    final s = raw.trim();
    return _id.hasMatch(s) ? s : null;
  }

  /// True when a notice for [eventId] should be shown now (and remembers it); false when the
  /// same event was shown less than [window] ago. A missing or bad id is always shown.
  bool firstTime(Object? eventId) {
    final id = idOf(eventId);
    if (id == null) return true;
    final now = _clock();
    _seen.removeWhere((_, at) => now - at >= window.inMilliseconds);
    final at = _seen[id];
    if (at != null) return false;
    _seen[id] = now;
    while (_seen.length > maxIds) {
      _seen.remove(_seen.keys.first);
    }
    return true;
  }

  /// Seen within [window] (does not remember anything).
  bool seen(Object? eventId) {
    final id = idOf(eventId);
    if (id == null) return false;
    final at = _seen[id];
    return at != null && _clock() - at < window.inMilliseconds;
  }

  void clear() => _seen.clear();
}
