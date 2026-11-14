import 'dart:ui' show SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/presentation/shell/coroute_nav_bar.dart';
import 'package:coroute_app/presentation/shell/quick_actions_sheet.dart';

/// v3.58 shell: Home · Explore · + · Community · Chat, glove-sized, and the quick action sheet.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => AppTheme.use(AppPalette.dark));

  Future<void> pumpBar(WidgetTester tester, {NavSlot? selected, required List<NavSlot> taps, required List<int> plus, AppPalette p = AppPalette.dark, double width = 320, double scale = 1.3, Map<NavSlot, int> badges = const {}}) async {
    AppTheme.use(p);
    final size = Size(width, 640);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(p),
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: CoRouteNavBar(selected: selected, onSelect: taps.add, onPlus: () => plus.add(1), badges: badges, badgeLabels: const {NavSlot.home: 'alerts need attention'}),
        ),
      ),
    ));
    await tester.pump();
  }

  for (final p in [AppPalette.dark, AppPalette.light]) {
    final label = p.isLight ? 'light' : 'dark';
    testWidgets('four destinations and a centre +, no overflow at 320 dp x1.3 ($label)', (tester) async {
      final taps = <NavSlot>[];
      final plus = <int>[];
      await pumpBar(tester, selected: NavSlot.home, taps: taps, plus: plus, p: p);
      expect(tester.takeException(), isNull);
      for (final t in ['Home', 'Explore', 'Community', 'Chat']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.byKey(const Key('nav_plus')), findsOneWidget);
    });
  }

  testWidgets('taps select a destination; + opens the actions; targets are glove-sized', (tester) async {
    final taps = <NavSlot>[];
    final plus = <int>[];
    await pumpBar(tester, selected: NavSlot.home, taps: taps, plus: plus, scale: 1);
    await tester.tap(find.text('Explore'));
    await tester.tap(find.text('Community'));
    await tester.tap(find.text('Chat'));
    await tester.tap(find.byKey(const Key('nav_plus')));
    await tester.pump();
    expect(taps, [NavSlot.explore, NavSlot.community, NavSlot.chat]);
    expect(plus, [1]);
    for (final k in ['nav_home', 'nav_explore', 'nav_community', 'nav_chat']) {
      final s = tester.getSize(find.byKey(Key(k)));
      expect(s.width, greaterThanOrEqualTo(48), reason: k);
      expect(s.height, greaterThanOrEqualTo(48), reason: k);
    }
    expect(tester.getSize(find.byKey(const Key('nav_plus'))).width, greaterThanOrEqualTo(CoRouteNavBar.plusSize));
  });

  testWidgets('a screen outside the bar (Profile, Trips, Alerts) highlights nothing; badges are spoken', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await pumpBar(tester, selected: null, taps: [], plus: [], scale: 1, badges: const {NavSlot.home: 2});
      final sem = tester.getSemantics(find.byKey(const Key('nav_home')));
      expect(sem.label, contains('alerts need attention'));
      expect(find.text('2'), findsOneWidget);
      for (final k in ['nav_home', 'nav_explore', 'nav_community', 'nav_chat']) {
        expect(tester.getSemantics(find.byKey(Key(k))).hasFlag(SemanticsFlag.isSelected), isFalse, reason: k);
      }
    } finally {
      handle.dispose();
    }
  });

  testWidgets('quick actions: Emergency first, then solo, group, join, plan, suggest', (tester) async {
    AppTheme.use(AppPalette.dark);
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: AppTheme.themeFor(AppPalette.dark), home: Scaffold(body: SingleChildScrollView(child: QuickActionsSheet(onExplore: () {})))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final ys = [for (final k in QuickActionsSheet.rowKeys) tester.getTopLeft(find.byKey(Key(k))).dy];
    for (var i = 1; i < ys.length; i++) {
      expect(ys[i], greaterThan(ys[i - 1]), reason: QuickActionsSheet.rowKeys[i]);
    }
    expect(find.text('Emergency'), findsOneWidget);
    expect(find.text('Start solo ride'), findsOneWidget);
    expect(find.text('Join with a code'), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('qa_emergency'))).height, greaterThanOrEqualTo(56));
  });
}
