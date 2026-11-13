// Round 7 (UX / performance): widget tests for the motion system, the loaders and optimistic UI.
// docs/features_355/motion_and_loading.md. Needs the Flutter SDK (`flutter test`).
import 'dart:async';

import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/ui/ui.dart';
import 'package:coroute_app/data/services/crews_service.dart';
import 'package:coroute_app/presentation/social/crew_detail_screen.dart';
import 'package:flutter/cupertino.dart' show CupertinoFullscreenDialogTransition, CupertinoPageTransition;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var haptics = <String>[];
  setUp(() {
    haptics = <String>[];
    AppMotion.batterySaver.value = false;
    AppMotion.debugLevelOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add('${call.arguments}');
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    AppMotion.batterySaver.value = false;
    AppMotion.debugLevelOverride = null;
    AppTheme.use(AppPalette.dark);
  });

  Widget app(Widget home, {bool reduceMotion = false}) => MaterialApp(
        theme: AppTheme.themeFor(AppPalette.dark),
        scrollBehavior: const AppScrollBehavior(),
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion), child: child!),
        home: home,
      );

  Widget page(String text) => Scaffold(body: Align(alignment: Alignment.topLeft, child: Text(text)));

  NavigatorState nav(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator));

  group('page transitions', () {
    test('the theme uses the app builder on every platform', () {
      final t = AppTheme.themeFor(AppPalette.dark).pageTransitionsTheme;
      for (final p in TargetPlatform.values) {
        expect(t.builders[p], isA<AppPageTransitionsBuilder>());
      }
      expect(const AppPageTransitionsBuilder().transitionDuration, AppMotion.page);
      expect(AppTheme.themeFor(AppPalette.light).pageTransitionsTheme.builders[TargetPlatform.android], isA<AppPageTransitionsBuilder>());
    });

    testWidgets('a normal page slides in from the right and comes to rest', (tester) async {
      await tester.pumpWidget(app(page('A')));
      nav(tester).push(MaterialPageRoute<void>(builder: (_) => page('B')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.ancestor(of: find.text('B'), matching: find.byType(CupertinoPageTransition)), findsOneWidget);
      expect(tester.getTopLeft(find.text('B')).dx, greaterThan(0));
      // Parallax: the page below moves left a little.
      expect(tester.getTopLeft(find.text('A')).dx, lessThan(0));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('B')).dx, 0);
    });

    testWidgets('edge-swipe from the left goes back', (tester) async {
      await tester.pumpWidget(app(page('A')));
      nav(tester).push(MaterialPageRoute<void>(builder: (_) => page('B')));
      await tester.pumpAndSettle();
      final g = await tester.startGesture(const Offset(5, 300));
      await g.moveBy(const Offset(60, 0));
      await tester.pump();
      await g.moveBy(const Offset(400, 0));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(find.text('B'), findsNothing);
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('safety routes are on screen at once: no slide, no fade, no transition widget', (tester) async {
      await tester.pumpWidget(app(page('A')));
      for (final name in ['safety/crash_alarm', 'safety/sos_hold', 'safety/emergency_sos']) {
        expect(AppMotion.isInstantRoute(name), isTrue);
        nav(tester).push(MaterialPageRoute<void>(
          fullscreenDialog: true,
          settings: RouteSettings(name: name),
          builder: (_) => page('ALARM'),
        ));
        await tester.pump(); // the very first frame
        expect(tester.getTopLeft(find.text('ALARM')), Offset.zero);
        expect(find.ancestor(of: find.text('ALARM'), matching: find.byType(CupertinoFullscreenDialogTransition)), findsNothing);
        expect(find.ancestor(of: find.text('ALARM'), matching: find.byType(CupertinoPageTransition)), findsNothing);
        // It takes taps on that first frame too.
        expect(find.text('ALARM').hitTestable(), findsOneWidget);
        await tester.pumpAndSettle();
        nav(tester).pop();
        await tester.pumpAndSettle();
      }
      expect(AppMotion.isInstantRoute('profile'), isFalse);
      expect(AppMotion.isInstantRoute(null), isFalse);
    });

    testWidgets('reduce motion: pages appear in place', (tester) async {
      await tester.pumpWidget(app(page('A'), reduceMotion: true));
      nav(tester).push(MaterialPageRoute<void>(builder: (_) => page('B')));
      await tester.pump();
      expect(tester.getTopLeft(find.text('B')).dx, 0);
      expect(find.ancestor(of: find.text('B'), matching: find.byType(CupertinoPageTransition)), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('battery saver: a short fade, no slide', (tester) async {
      AppMotion.batterySaver.value = true;
      await tester.pumpWidget(app(page('A')));
      nav(tester).push(MaterialPageRoute<void>(builder: (_) => page('B')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(tester.getTopLeft(find.text('B')).dx, 0);
      expect(find.ancestor(of: find.text('B'), matching: find.byType(CupertinoPageTransition)), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('tabs: fade-through, built on first visit, kept alive', (tester) async {
      final built = <int>[];
      Widget stack(int i) => app(Scaffold(
            body: FadeThroughIndexedStack(index: i, builders: [
              for (var n = 0; n < 3; n++)
                (_) {
                  built.add(n);
                  return TextField(key: ValueKey('field$n'));
                },
            ]),
          ));
      await tester.pumpWidget(stack(0));
      expect(built, [0]);
      await tester.enterText(find.byKey(const ValueKey('field0')), 'kept');
      await tester.pumpWidget(stack(1));
      await tester.pump(const Duration(milliseconds: 50));
      expect(built.contains(1), isTrue);
      expect(built.contains(2), isFalse);
      await tester.pumpAndSettle();
      await tester.pumpWidget(stack(0));
      await tester.pumpAndSettle();
      expect(find.text('kept'), findsOneWidget); // the first tab's state survived
    });

    testWidgets('lists bounce the same way everywhere', (tester) async {
      await tester.pumpWidget(app(Scaffold(body: ListView(children: const [SizedBox(height: 40, child: Text('row'))]))));
      ScrollPhysics? p = tester.state<ScrollableState>(find.byType(Scrollable)).position.physics;
      var bouncing = false;
      while (p != null) {
        if (p is BouncingScrollPhysics) bouncing = true;
        p = p.parent;
      }
      expect(bouncing, isTrue);
    });
  });

  group('skeletons and loading', () {
    testWidgets('skeleton -> content swap without an exception', (tester) async {
      final gate = Completer<List<String>>();
      final c = SwrController<List<String>>(cacheKey: 'riders', cache: SwrCache(), fetch: () => gate.future);
      addTearDown(c.dispose);
      await tester.pumpWidget(app(Scaffold(
        body: SwrView<List<String>>(
          controller: c,
          skeleton: (_) => const SkeletonList(count: 4),
          builder: (_, riders) => ListView(children: [for (final r in riders) ListTile(title: Text(r))]),
        ),
      )));
      unawaited(c.load());
      await tester.pump();
      expect(c.firstLoad, isTrue);
      expect(find.byType(SkeletonListTile), findsNWidgets(4));
      expect(find.bySemanticsLabel('Loading'), findsWidgets);
      expect(find.text('Asha'), findsNothing);

      gate.complete(['Asha', 'Vikram']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Asha'), findsOneWidget);
      expect(find.byType(SkeletonListTile), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('stale-while-revalidate: cached data at once, fresh data in place', (tester) async {
      final cache = SwrCache()..put<List<String>>('riders', ['Old']);
      final gate = Completer<List<String>>();
      final c = SwrController<List<String>>(cacheKey: 'riders', cache: cache, ttl: Duration.zero, fetch: () => gate.future);
      addTearDown(c.dispose);
      await tester.pumpWidget(app(Scaffold(
        body: SwrView<List<String>>(
          controller: c,
          skeleton: (_) => const SkeletonList(count: 4),
          builder: (_, riders) => ListView(children: [for (final r in riders) ListTile(title: Text(r))]),
        ),
      )));
      unawaited(c.load());
      await tester.pump();
      expect(find.text('Old'), findsOneWidget); // no skeleton, no blank screen
      expect(find.byType(SkeletonListTile), findsNothing);
      expect(c.refreshing, isTrue);
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byType(LinearProgressIndicator), findsOneWidget); // the thin top line
      gate.complete(['New']);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.text('New'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(cache.peek<List<String>>('riders'), ['New']);
    });

    testWidgets('error with nothing to show: message and Retry; retry loads', (tester) async {
      var calls = 0;
      final c = SwrController<String>(
        cacheKey: 'x',
        cache: SwrCache(),
        fetch: () async {
          calls++;
          if (calls == 1) throw StateError('offline');
          return 'Loaded';
        },
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(app(Scaffold(
        body: SwrView<String>(controller: c, skeleton: (_) => const SkeletonCards(count: 2), builder: (_, s) => Center(child: Text(s)), pullToRefresh: false),
      )));
      await c.load();
      await tester.pumpAndSettle();
      expect(find.text('Could not load'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Loaded'), findsOneWidget);
      expect(calls, 2);
    });

    testWidgets('a failed refresh keeps the old data on screen', (tester) async {
      final cache = SwrCache()..put<String>('x', 'Old');
      final c = SwrController<String>(cacheKey: 'x', cache: cache, fetch: () async => throw StateError('offline'));
      addTearDown(c.dispose);
      await tester.pumpWidget(app(Scaffold(
        body: SwrView<String>(controller: c, skeleton: (_) => const SkeletonCards(count: 2), builder: (_, s) => Center(child: Text(s)), pullToRefresh: false),
      )));
      await c.refresh();
      await tester.pumpAndSettle();
      expect(find.text('Old'), findsOneWidget);
      expect(c.error, isNotNull);
    });

    testWidgets('LoadingState: skeleton builder instead of the spinner on first load', (tester) async {
      await tester.pumpWidget(app(Scaffold(
        body: LoadingState(loading: true, hasData: false, skeleton: (_) => const SkeletonList(count: 3), child: const Text('Data')),
      )));
      expect(find.byType(SkeletonListTile), findsNWidgets(3));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Data'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('shimmer runs at full motion and is still with reduce motion or battery saver', (tester) async {
      await tester.pumpWidget(app(const Scaffold(body: SkeletonList(count: 3))));
      await tester.pump();
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      await tester.pumpWidget(app(const Scaffold(body: SkeletonList(count: 3)), reduceMotion: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.byType(SkeletonListTile), findsNWidgets(3)); // the shapes are still there

      await tester.pumpWidget(const SizedBox());
      AppMotion.batterySaver.value = true;
      await tester.pumpWidget(app(const Scaffold(body: SkeletonList(count: 3))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('skeleton presets fit a 320 dp window', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final w in <Widget>[
        const SkeletonList(),
        const SkeletonList.cards(),
        const SingleChildScrollView(child: SkeletonProfile()),
        const SingleChildScrollView(child: SkeletonCards(count: 3, stats: true)),
        const SingleChildScrollView(child: SkeletonRows(count: 5, trailing: true)),
      ]) {
        await tester.pumpWidget(app(Scaffold(body: w)));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reduce motion: dialogs and sheets appear without an animation', (tester) async {
      await tester.pumpWidget(app(Scaffold(body: Builder(builder: (ctx) {
        return Column(children: [
          TextButton(onPressed: () => showAppDialog<void>(ctx, builder: (_) => const AlertDialog(title: Text('Dialog'))), child: const Text('open dialog')),
          TextButton(onPressed: () => showAppSheet<void>(ctx, title: 'Sheet', builder: (_) => const Text('sheet body')), child: const Text('open sheet')),
        ]);
      })), reduceMotion: true));
      await tester.tap(find.text('open dialog'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Dialog'), findsOneWidget);
      Navigator.of(tester.element(find.text('Dialog'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('open sheet'));
      await tester.pump();
      await tester.pump();
      expect(find.text('sheet body'), findsOneWidget);
      await tester.pumpAndSettle();
    });
  });

  group('optimistic UI and micro-interactions', () {
    testWidgets('optimistic switch: on at once, back with a toast when saving fails', (tester) async {
      final gate = Completer<Object?>();
      final shown = <bool>[];
      await tester.pumpWidget(app(Scaffold(
        body: Center(child: OptimisticSwitch(value: false, onSave: (_) => gate.future, onChanged: shown.add)),
      )));
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue); // before the server answered
      expect(haptics, contains('HapticFeedbackType.selectionClick'));
      gate.completeError(StateError('offline'));
      await tester.pump();
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(find.textContaining('Could not save'), findsOneWidget);
      expect(shown, [true, false]);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    });

    testWidgets('optimistic switch: stays on when saving works', (tester) async {
      await tester.pumpWidget(app(Scaffold(body: Center(child: OptimisticSwitch(value: false, onSave: (_) async => true)))));
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.textContaining('Could not save'), findsNothing);
    });

    testWidgets('poll vote: the tick moves at once and goes back when the vote is refused', (tester) async {
      const poll = CrewPoll(
        pollId: 'p1',
        question: 'Sunday route?',
        options: [PollOption(id: 'a', text: 'Coast road'), PollOption(id: 'b', text: 'Hill road')],
        closesAt: 4102444800000,
      );
      final gate = Completer<Object?>();
      final votes = <List<String>>[];
      await tester.pumpWidget(app(Scaffold(
        body: SingleChildScrollView(
          child: PollCard(
            poll: poll,
            onVote: (ids) {
              votes.add(ids);
              return gate.future;
            },
          ),
        ),
      )));
      await tester.tap(find.text('Coast road'));
      await tester.pump();
      expect(votes, [
        ['a']
      ]);
      // A second tap while the first vote is in flight is not sent again.
      await tester.tap(find.text('Coast road'));
      await tester.pump();
      expect(votes.length, 1);
      gate.complete(false);
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
    });

    testWidgets('AsyncButton: spinner inside the button, second tap ignored, page not blocked', (tester) async {
      final gate = Completer<void>();
      var runs = 0;
      var other = 0;
      await tester.pumpWidget(app(Scaffold(
        body: Column(children: [
          AsyncButton(
            label: 'Join crew',
            busyLabel: 'Joining',
            onPressed: () {
              runs++;
              return gate.future;
            },
          ),
          TextButton(onPressed: () => other++, child: const Text('Other')),
        ]),
      )));
      await tester.tap(find.text('Join crew'));
      await tester.pump();
      expect(find.text('Joining'), findsOneWidget);
      expect(find.descendant(of: find.byType(AsyncButton), matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      await tester.tap(find.byType(AsyncButton));
      await tester.pump();
      expect(runs, 1);
      await tester.tap(find.text('Other')); // the rest of the page still works
      expect(other, 1);
      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Join crew'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('DsButton: loading shows an inline spinner and ignores taps', (tester) async {
      var taps = 0;
      await tester.pumpWidget(app(Scaffold(body: DsButton(label: 'Save', onPressed: () => taps++, loading: true))));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byType(DsButton));
      expect(taps, 0);
      await tester.pumpWidget(app(Scaffold(body: DsButton(label: 'Save', onPressed: () => taps++))));
      await tester.tap(find.byType(DsButton));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('Pressable: shrinks while pressed, taps once with a light haptic; no scale with reduce motion', (tester) async {
      var taps = 0;
      Widget body({bool reduce = false}) => app(
            Scaffold(body: Center(child: Pressable(onTap: () => taps++, child: const SizedBox(width: 120, height: 56, child: Text('Press'))))),
            reduceMotion: reduce,
          );
      await tester.pumpWidget(body());
      final g = await tester.startGesture(tester.getCenter(find.text('Press')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, lessThan(1));
      await g.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(haptics, contains('HapticFeedbackType.lightImpact'));
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);

      await tester.pumpWidget(body(reduce: true));
      final g2 = await tester.startGesture(tester.getCenter(find.text('Press')));
      await tester.pump();
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
      await g2.up();
      await tester.pumpAndSettle();
      expect(taps, 2);
    });

    testWidgets('AnimatedCount ends on the value; reduce motion shows it at once', (tester) async {
      await tester.pumpWidget(app(const Scaffold(body: AnimatedCount(10))));
      await tester.pumpWidget(app(const Scaffold(body: AnimatedCount(86))));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('86'), findsNothing); // on its way
      await tester.pumpAndSettle();
      expect(find.text('86'), findsOneWidget);
      await tester.pumpWidget(app(const Scaffold(body: AnimatedCount(40, suffix: ' km')), reduceMotion: true));
      await tester.pump();
      expect(find.text('40 km'), findsOneWidget);
    });

    testWidgets('DsSwitchRow gives a selection haptic and still reports the change', (tester) async {
      bool? got;
      await tester.pumpWidget(app(Scaffold(body: DsSwitchRow(label: 'Night voice', value: false, onChanged: (v) => got = v))));
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(got, isTrue);
      expect(haptics, contains('HapticFeedbackType.selectionClick'));
    });

    test('decode size: screen size x pixel ratio, in steps of 32, capped at 3x', () {
      expect(decodeSize(44, 1), 64);
      expect(decodeSize(44, 3), 160);
      expect(decodeSize(44, 4), 160);
      expect(decodeSize(96, 2.75), 288);
      expect(decodeSize(40, 2), decodeSize(44, 2)); // nearly equal sizes share a cache entry
    });

    test('the spring curve starts at 0, ends at 1 and never overshoots', () {
      const c = SpringCurve(SpringSpec.sheet);
      expect(c.transform(0), 0);
      expect(c.transform(1), 1);
      var last = 0.0;
      for (var i = 1; i <= 100; i++) {
        final v = c.transform(i / 100);
        expect(v, inInclusiveRange(0.0, 1.0));
        expect(v, greaterThanOrEqualTo(last - 0.002));
        last = v;
      }
      expect(c.transform(0.5), greaterThan(0.8)); // fast start, soft landing
    });
  });
}
