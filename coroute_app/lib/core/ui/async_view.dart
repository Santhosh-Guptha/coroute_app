import 'dart:async';

import 'package:flutter/material.dart';

import 'app_motion.dart';
import 'empty_state.dart';
import 'optimistic.dart';
import 'skeleton.dart';

/// Stale-while-revalidate for one screen: the last known value is shown at
/// once (from [SwrCache]), a fresh one is fetched in the background and
/// swapped in place. Back navigation within [ttl] does not fetch again.
///
///     late final _c = SwrController<List<Crew>>(cacheKey: 'crews', fetch: api.crews)..load();
///     SwrView<List<Crew>>(controller: _c, skeleton: (_) => const SkeletonList(), builder: (_, crews) => ...)
class SwrController<T> extends ChangeNotifier {
  SwrController({required this.cacheKey, required this.fetch, SwrCache? cache, this.ttl = const Duration(seconds: 45), T? initial})
      : cache = cache ?? SwrCache.shared {
    _data = initial ?? this.cache.peek<T>(cacheKey);
  }

  final String cacheKey;
  final Future<T> Function() fetch;
  final SwrCache cache;
  final Duration ttl;

  T? _data;
  Object? _error;
  bool _loading = false;
  bool _disposed = false;
  int _seq = 0;

  T? get data => _data;
  bool get hasData => _data != null;
  Object? get error => _error;

  /// A fetch is running.
  bool get loading => _loading;

  /// First load: nothing to show yet (skeleton).
  bool get firstLoad => _loading && _data == null;

  /// Refresh in place: old data on screen (top progress line).
  bool get refreshing => _loading && _data != null;

  /// Shows the cached value and fetches unless it is fresh. [force] always fetches.
  Future<void> load({bool force = false}) async {
    final cached = cache.peek<T>(cacheKey);
    if (cached != null && _data == null) _data = cached;
    if (!force && _data != null && cache.isFresh(cacheKey, ttl)) {
      _notify();
      return;
    }
    final ticket = ++_seq;
    _loading = true;
    _error = null;
    _notify();
    try {
      final v = force ? await fetch() : await cache.load<T>(cacheKey, fetch);
      if (force) cache.put<T>(cacheKey, v);
      if (ticket != _seq) return;
      _data = v;
    } catch (e) {
      if (ticket != _seq) return;
      _error = e;
    } finally {
      if (ticket == _seq) {
        _loading = false;
        _notify();
      }
    }
  }

  /// Pull-to-refresh / Retry.
  Future<void> refresh() => load(force: true);

  /// Change the shown value locally (optimistic UI); also updates the cache.
  void mutate(T Function(T current) change) {
    final d = _data;
    if (d == null) return;
    final next = change(d);
    _data = next;
    cache.put<T>(cacheKey, next);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _seq++;
    super.dispose();
  }
}

/// The screen body for a [SwrController]: skeleton on first load, content
/// with a thin top line while refreshing, pull-to-refresh, an error state
/// with Retry when there is nothing to show, an empty state when [isEmpty].
class SwrView<T> extends StatelessWidget {
  final SwrController<T> controller;
  final WidgetBuilder skeleton;
  final Widget Function(BuildContext context, T data) builder;
  final bool Function(T data)? isEmpty;
  final WidgetBuilder? empty;
  final String errorTitle;
  final String errorMessage;

  /// Wraps the content in a RefreshIndicator (the content must scroll).
  final bool pullToRefresh;

  const SwrView({
    super.key,
    required this.controller,
    required this.skeleton,
    required this.builder,
    this.isEmpty,
    this.empty,
    this.errorTitle = 'Could not load',
    this.errorMessage = 'Check your connection and try again.',
    this.pullToRefresh = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final data = controller.data;
        final Widget body;
        final String state;
        if (data == null) {
          if (controller.error != null && !controller.loading) {
            state = 'error';
            body = ErrorState(title: errorTitle, message: errorMessage, onRetry: controller.refresh);
          } else {
            state = 'skeleton';
            body = Builder(builder: skeleton);
          }
        } else if (isEmpty != null && isEmpty!(data) && empty != null) {
          state = 'empty';
          body = Builder(builder: empty!);
        } else {
          state = 'content';
          final content = builder(context, data);
          body = pullToRefresh ? AppRefresh(onRefresh: controller.refresh, child: content) : content;
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            FadeThroughSwitcher(child: KeyedSubtree(key: ValueKey<String>(state), child: body)),
            Positioned(top: 0, left: 0, right: 0, child: TopProgressLine(active: controller.refreshing)),
          ],
        );
      },
    );
  }
}

/// Pull-to-refresh with the app's colours and a haptic when it triggers.
class AppRefresh extends StatelessWidget {
  final Future<void> Function() onRefresh;
  final Widget child;
  const AppRefresh({super.key, required this.onRefresh, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      color: scheme.primary,
      backgroundColor: scheme.surface,
      strokeWidth: 2.5,
      displacement: 28,
      onRefresh: () {
        AppHaptics.medium();
        return onRefresh();
      },
      child: child,
    );
  }
}

/// Runs [work] when the app has been idle for a moment after the current
/// frame (start-up precaching). Never throws.
void runWhenIdle(FutureOr<void> Function() work, {Duration delay = const Duration(milliseconds: 600)}) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Timer(delay, () async {
      try {
        await work();
      } catch (_) {}
    });
  });
}
