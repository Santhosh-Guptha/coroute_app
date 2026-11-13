// Round 7 (UX / performance): pure-logic tests for the motion tokens, the adaptive layout rules,
// optimistic updates, the debouncer and the stale-while-revalidate cache. No Flutter import, so it
// also runs with tool/pure_dart_test/run.sh.
import 'dart:async';

import 'package:coroute_app/core/ui/adaptive_spec.dart';
import 'package:coroute_app/core/ui/motion_spec.dart';
import 'package:coroute_app/core/ui/optimistic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('motion tokens', () {
    test('the three durations are 120 / 200 / 300 ms', () {
      expect(MotionMs.fast, 120);
      expect(MotionMs.medium, 200);
      expect(MotionMs.slow, 300);
      expect(MotionMs.page, inInclusiveRange(300, 400));
    });

    test('the system setting wins over battery saver', () {
      expect(MotionSpec.level(disableAnimations: false, batterySaver: false), MotionLevel.full);
      expect(MotionSpec.level(disableAnimations: false, batterySaver: true), MotionLevel.reduced);
      expect(MotionSpec.level(disableAnimations: true, batterySaver: false), MotionLevel.none);
      expect(MotionSpec.level(disableAnimations: true, batterySaver: true), MotionLevel.none);
    });

    test('durations: full as given, reduced capped at 120 ms, none zero', () {
      expect(MotionSpec.scaledMs(300, MotionLevel.full), 300);
      expect(MotionSpec.scaledMs(300, MotionLevel.reduced), 120);
      expect(MotionSpec.scaledMs(80, MotionLevel.reduced), 80);
      expect(MotionSpec.scaledMs(300, MotionLevel.none), 0);
      expect(MotionSpec.scaledMs(0, MotionLevel.full), 0);
      expect(MotionSpec.scaledMs(-5, MotionLevel.full), 0);
    });

    test('looping and decorative motion only at full', () {
      expect(MotionSpec.loops(MotionLevel.full), isTrue);
      expect(MotionSpec.loops(MotionLevel.reduced), isFalse);
      expect(MotionSpec.loops(MotionLevel.none), isFalse);
      expect(MotionSpec.decorative(MotionLevel.reduced), isFalse);
    });

    test('pressed scale: small controls shrink more than big cards, never below 0.96', () {
      expect(MotionSpec.pressedScale(44), 0.96);
      expect(MotionSpec.pressedScale(400), 0.985);
      final mid = MotionSpec.pressedScale(148);
      expect(mid, greaterThan(0.96));
      expect(mid, lessThan(0.985));
    });

    test('springs settle without a visible bounce', () {
      for (final s in [SpringSpec.sheet, SpringSpec.dragRelease, SpringSpec.press]) {
        expect(s.dampingRatio, inInclusiveRange(0.8, 1.2));
      }
    });

    test('counter, skeleton rows and loader timing', () {
      expect(MotionSpec.counterValue(10, 20, 0), 10);
      expect(MotionSpec.counterValue(10, 20, 0.5), 15);
      expect(MotionSpec.counterValue(10, 20, 2), 20);
      expect(MotionSpec.skeletonRows(720, 72), 10);
      expect(MotionSpec.skeletonRows(100, 72), 3);
      expect(MotionSpec.skeletonRows(5000, 72), 12);
      expect(MotionSpec.skeletonRows(0, 72), 3);
      expect(MotionSpec.showLoader(10), isFalse);
      expect(MotionSpec.showLoader(MotionMs.loaderDelay), isTrue);
      expect(MotionSpec.loaderHoldMs(100), MotionMs.loaderMinVisible - 100);
      expect(MotionSpec.loaderHoldMs(1000), 0);
    });
  });

  group('adaptive layout rules', () {
    test('window classes at the test sizes', () {
      expect(AdaptiveSpec.classFor(320), WindowClass.compact);
      expect(AdaptiveSpec.classFor(359.9), WindowClass.compact);
      expect(AdaptiveSpec.classFor(360), WindowClass.normal);
      expect(AdaptiveSpec.classFor(412), WindowClass.normal);
      expect(AdaptiveSpec.classFor(599), WindowClass.normal);
      expect(AdaptiveSpec.classFor(600), WindowClass.large);
      expect(AdaptiveSpec.classFor(800), WindowClass.large);
      expect(AdaptiveSpec.classFor(915), WindowClass.large); // 412x915 phone in landscape
    });

    test('gutters, two panes and list pane width', () {
      expect(AdaptiveSpec.gutter(320), 12);
      expect(AdaptiveSpec.gutter(400), 16);
      expect(AdaptiveSpec.gutter(800), 24);
      expect(AdaptiveSpec.twoPane(600), isFalse);
      expect(AdaptiveSpec.twoPane(800), isTrue);
      expect(AdaptiveSpec.listPaneWidth(720), 300);
      expect(AdaptiveSpec.listPaneWidth(900), closeTo(342, 0.01));
      expect(AdaptiveSpec.listPaneWidth(1600), 400);
      // The detail pane always keeps at least 400 dp.
      for (final w in [720.0, 800.0, 1024.0, 1280.0]) {
        expect(w - AdaptiveSpec.listPaneWidth(w) - 1, greaterThanOrEqualTo(400));
      }
    });

    test('columns never leave a tile narrower than asked', () {
      expect(AdaptiveSpec.columns(320), 1);
      expect(AdaptiveSpec.columns(360), 2);
      expect(AdaptiveSpec.columns(412), 2);
      expect(AdaptiveSpec.columns(800), 4);
      expect(AdaptiveSpec.columns(4000), 6);
      for (final w in [320.0, 360.0, 412.0, 600.0, 800.0, 1280.0]) {
        final n = AdaptiveSpec.columns(w);
        final usable = w - 2 * AdaptiveSpec.gutter(w);
        if (n > 1) expect((usable - (n - 1) * 12) / n, greaterThanOrEqualTo(156));
      }
    });

    test('text scale is honoured up to 1.3', () {
      expect(AdaptiveSpec.clampTextScale(1.0), 1.0);
      expect(AdaptiveSpec.clampTextScale(2.0), 1.3);
      expect(AdaptiveSpec.clampTextScale(0.5), 0.85);
      expect(AdaptiveSpec.clampTextScale(double.nan), 1.0);
      expect(AdaptiveSpec.softScale(40, 1.3), closeTo(46, 0.001));
      expect(AdaptiveSpec.softScale(40, 3.0), closeTo(46, 0.001));
    });

    test('trailing parts stack on narrow windows and with big text', () {
      expect(AdaptiveSpec.stackTrailing(320, 1.0), isTrue);
      expect(AdaptiveSpec.stackTrailing(360, 1.0), isFalse);
      expect(AdaptiveSpec.stackTrailing(360, 1.3), isTrue);
      expect(AdaptiveSpec.stackTrailing(412, 1.3), isFalse);
    });

    test('landscape, short height, centred column, tap target', () {
      expect(AdaptiveSpec.landscape(800, 360), isTrue);
      expect(AdaptiveSpec.landscape(360, 800), isFalse);
      expect(AdaptiveSpec.shortHeight(360), isTrue);
      expect(AdaptiveSpec.shortHeight(800), isFalse);
      expect(AdaptiveSpec.centeredInset(360), 16);
      expect(AdaptiveSpec.centeredInset(1280), 320);
      expect(AdaptiveSpec.minTap, 48);
    });
  });

  group('optimistic updates', () {
    test('commit keeps the new value', () async {
      var v = false;
      final r = await Optimistic.run<bool>(read: () => v, apply: (x) => v = x, next: true, commit: (_) async => null);
      expect(r, OptimisticResult.committed);
      expect(v, isTrue);
    });

    test('the value changes before the commit finishes', () async {
      var v = false;
      final gate = Completer<void>();
      final f = Optimistic.run<bool>(read: () => v, apply: (x) => v = x, next: true, commit: (_) => gate.future);
      expect(v, isTrue);
      gate.complete();
      expect(await f, OptimisticResult.committed);
    });

    test('a failed commit rolls back and reports the error', () async {
      var v = 3;
      Object? seen;
      final r = await Optimistic.run<int>(
        read: () => v,
        apply: (x) => v = x,
        next: 4,
        commit: (_) async => throw StateError('offline'),
        onError: (e) => seen = e,
      );
      expect(r, OptimisticResult.rolledBack);
      expect(v, 3);
      expect(seen, isA<StateError>());
    });

    test('a commit answering false is a refusal', () async {
      var v = 'a';
      Object? seen;
      final r = await Optimistic.run<String>(read: () => v, apply: (x) => v = x, next: 'b', commit: (_) async => false, onError: (e) => seen = e);
      expect(r, OptimisticResult.rolledBack);
      expect(v, 'a');
      expect(seen, isA<OptimisticRefused>());
    });

    test('no roll-back over a newer value', () async {
      var v = 1;
      final gate = Completer<void>();
      final f = Optimistic.run<int>(read: () => v, apply: (x) => v = x, next: 2, commit: (_) => gate.future);
      v = 9; // changed by someone else while the commit was in flight
      gate.completeError(StateError('x'));
      expect(await f, OptimisticResult.rolledBack);
      expect(v, 9);
    });

    test('a double tap with the same key is skipped', () async {
      var v = false;
      var commits = 0;
      final gate = Completer<void>();
      Future<Object?> commit(bool _) {
        commits++;
        return gate.future;
      }

      final a = Optimistic.run<bool>(read: () => v, apply: (x) => v = x, next: true, commit: commit, key: 'k');
      expect(Optimistic.busy('k'), isTrue);
      final b = await Optimistic.run<bool>(read: () => v, apply: (x) => v = x, next: false, commit: commit, key: 'k');
      expect(b, OptimisticResult.skipped);
      expect(v, isTrue);
      gate.complete();
      expect(await a, OptimisticResult.committed);
      expect(commits, 1);
      expect(Optimistic.busy('k'), isFalse);
    });
  });

  group('debouncer and latest gate', () {
    test('only the last call runs', () async {
      final d = Debouncer(ms: 20);
      final seen = <int>[];
      d(() => seen.add(1));
      d(() => seen.add(2));
      d(() => seen.add(3));
      expect(d.pending, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(seen, [3]);
      expect(d.pending, isFalse);
    });

    test('flush runs now, cancel drops', () async {
      final d = Debouncer(ms: 20);
      final seen = <String>[];
      d(() => seen.add('late'));
      d.flush(() => seen.add('now'));
      d(() => seen.add('dropped'));
      d.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen, ['now']);
    });

    test('a slow first answer does not replace a fast second one', () {
      final g = LatestGate();
      final first = g.next();
      final second = g.next();
      expect(g.isCurrent(first), isFalse);
      expect(g.isCurrent(second), isTrue);
      g.invalidate();
      expect(g.isCurrent(second), isFalse);
    });
  });

  group('stale-while-revalidate cache', () {
    test('peek, freshness and age', () {
      var now = DateTime(2026, 1, 1, 12);
      final c = SwrCache(now: () => now);
      expect(c.peek<String>('k'), isNull);
      expect(c.isFresh('k', const Duration(minutes: 1)), isFalse);
      c.put<String>('k', 'v');
      expect(c.peek<String>('k'), 'v');
      expect(c.peek<int>('k'), isNull); // wrong type is not handed out
      expect(c.isFresh('k', const Duration(minutes: 1)), isTrue);
      now = now.add(const Duration(minutes: 2));
      expect(c.isFresh('k', const Duration(minutes: 1)), isFalse);
      expect(c.peek<String>('k'), 'v'); // stale data is still shown
      expect(c.age('k'), const Duration(minutes: 2));
    });

    test('concurrent loads share one fetch; errors store nothing', () async {
      final c = SwrCache();
      var fetches = 0;
      final gate = Completer<int>();
      Future<int> fetch() {
        fetches++;
        return gate.future;
      }

      final a = c.load<int>('n', fetch);
      final b = c.load<int>('n', fetch);
      gate.complete(7);
      expect(await a, 7);
      expect(await b, 7);
      expect(fetches, 1);
      expect(c.peek<int>('n'), 7);

      Object? err;
      try {
        await c.load<int>('bad', () async => throw StateError('x'));
      } catch (e) {
        err = e;
      }
      expect(err, isA<StateError>());
      expect(c.peek<int>('bad'), isNull);
      // After the failure the key can be loaded again.
      expect(await c.load<int>('bad', () async => 1), 1);
    });

    test('warm never throws and skips fresh entries', () async {
      final c = SwrCache();
      var fetches = 0;
      await c.warm<int>('w', () async {
        fetches++;
        return 1;
      });
      await c.warm<int>('w', () async {
        fetches++;
        return 2;
      });
      expect(fetches, 1);
      expect(c.peek<int>('w'), 1);
      await c.warm<int>('e', () async => throw StateError('offline'));
      expect(c.peek<int>('e'), isNull);
    });

    test('oldest entries go first; clear and removeWhere', () {
      final c = SwrCache(maxEntries: 2);
      c.put<int>('a', 1);
      c.put<int>('b', 2);
      c.put<int>('a', 3); // touched: now the newest
      c.put<int>('c', 4);
      expect(c.length, 2);
      expect(c.peek<int>('b'), isNull);
      expect(c.peek<int>('a'), 3);
      c.removeWhere((k) => k.startsWith('a'));
      expect(c.peek<int>('a'), isNull);
      c.clear();
      expect(c.length, 0);
    });
  });
}
