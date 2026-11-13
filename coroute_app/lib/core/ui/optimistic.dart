/// Optimistic updates and small async helpers (pure Dart).
/// docs/features_355/motion_and_loading.md
library;

import 'dart:async';

/// Result of an optimistic action.
enum OptimisticResult { committed, rolledBack, skipped }

/// Apply a cheap change at once, send it, and undo it when the send fails.
///
///     await Optimistic.run<bool>(
///       read: () => liked,
///       apply: (v) => setState(() => liked = v),
///       next: !liked,
///       commit: (v) => api.setLiked(id, v),
///       onError: (e) => showAppToast(context, 'Could not save. Try again.'),
///     );
///
/// A second call with the same [key] while the first is in flight is skipped,
/// so a double tap does not send twice or roll back to the wrong value.
abstract final class Optimistic {
  static final Set<Object> _inFlight = <Object>{};

  static bool busy(Object key) => _inFlight.contains(key);

  static Future<OptimisticResult> run<T>({
    required T Function() read,
    required void Function(T value) apply,
    required T next,
    required Future<Object?> Function(T value) commit,
    void Function(Object error)? onError,
    Object? key,
  }) async {
    if (key != null && !_inFlight.add(key)) return OptimisticResult.skipped;
    final before = read();
    apply(next);
    try {
      final ok = await commit(next);
      // A commit that answers `false` is a refusal (many services return bool).
      if (ok == false) throw const OptimisticRefused();
      return OptimisticResult.committed;
    } catch (e) {
      // Roll back only if nobody changed the value in the meantime.
      if (read() == next) apply(before);
      onError?.call(e);
      return OptimisticResult.rolledBack;
    } finally {
      if (key != null) _inFlight.remove(key);
    }
  }
}

/// The commit answered `false`.
class OptimisticRefused implements Exception {
  const OptimisticRefused();
  @override
  String toString() => 'OptimisticRefused';
}

/// Runs the last call after [ms] of quiet (search fields, filters).
class Debouncer {
  final int ms;
  Timer? _timer;
  Debouncer({this.ms = 280});

  bool get pending => _timer?.isActive ?? false;

  void call(void Function() action) {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: ms), action);
  }

  /// Runs a waiting call now (the rider pressed Search).
  void flush(void Function() action) {
    _timer?.cancel();
    _timer = null;
    action();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Keeps only the newest answer: `final t = gate.next(); ...await...; if (!gate.isCurrent(t)) return;`
/// (a slow first search must not overwrite a fast second one).
class LatestGate {
  int _seq = 0;
  int next() => ++_seq;
  bool isCurrent(int ticket) => ticket == _seq;
  void invalidate() => _seq++;
}

/// A value kept in memory with its age, for stale-while-revalidate screens.
class SwrEntry<T> {
  final T value;
  final DateTime at;
  const SwrEntry(this.value, this.at);
}

/// In-memory cache: screens show the last value at once and refresh in place.
/// Nothing is written to disk here; cleared on sign-out ([clear]).
class SwrCache {
  SwrCache({this.maxEntries = 64, DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// The app-wide cache.
  static final SwrCache shared = SwrCache();

  final int maxEntries;
  final DateTime Function() _now;
  final Map<String, SwrEntry<Object?>> _map = <String, SwrEntry<Object?>>{};
  final Map<String, Future<Object?>> _loading = <String, Future<Object?>>{};

  int get length => _map.length;

  T? peek<T>(String key) {
    final e = _map[key];
    final v = e?.value;
    return v is T ? v : null;
  }

  Duration? age(String key) {
    final e = _map[key];
    return e == null ? null : _now().difference(e.at);
  }

  /// Fresh = younger than [ttl]: no refetch needed (back navigation).
  bool isFresh(String key, Duration ttl) {
    final a = age(key);
    return a != null && a < ttl;
  }

  void put<T>(String key, T value) {
    _map.remove(key);
    _map[key] = SwrEntry<Object?>(value, _now());
    while (_map.length > maxEntries) {
      _map.remove(_map.keys.first);
    }
  }

  void remove(String key) => _map.remove(key);

  void removeWhere(bool Function(String key) test) => _map.removeWhere((k, _) => test(k));

  void clear() {
    _map.clear();
    _loading.clear();
  }

  /// Loads [key] once even when several screens ask at the same time, and
  /// stores the answer. Errors are passed on and nothing is stored.
  Future<T> load<T>(String key, Future<T> Function() fetch) {
    final running = _loading[key];
    if (running != null) return running.then((v) => v as T);
    final f = fetch().then<Object?>((v) {
      put<T>(key, v);
      return v;
    }).whenComplete(() {
      _loading.remove(key); // block body: the removed future must not be returned (it would wait on itself)
    });
    _loading[key] = f;
    return f.then((v) => v as T);
  }

  /// Fetch for a screen that is likely next; never throws, never refetches a
  /// fresh entry.
  Future<void> warm<T>(String key, Future<T> Function() fetch, {Duration ttl = const Duration(minutes: 2)}) async {
    if (isFresh(key, ttl)) return;
    try {
      await load<T>(key, fetch);
    } catch (_) {}
  }
}
