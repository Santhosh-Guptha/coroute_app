import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/presentation/admin/charts/charts.dart';

/// The admin chart widgets (CustomPainter, no chart package): empty and loading
/// states, the screen reader summary, tap / hover without errors, the trend tile.
void main() {
  tearDown(() => AppTheme.use(AppPalette.dark));

  Future<void> pump(WidgetTester tester, Widget child, {double width = 360, AppPalette palette = AppPalette.light}) async {
    AppTheme.use(palette);
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(palette),
      home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: SingleChildScrollView(child: child))),
    ));
    await tester.pump(const Duration(milliseconds: 350)); // the 300 ms load-in
  }

  final labels = [for (var d = 1; d <= 7; d++) '2026-11-0$d'];

  testWidgets('bar chart: summary names the peak; tap and hover show a tooltip without errors', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, AdminBarChart(values: const [1, 3, 0, 42, 5, 2, 7], labels: labels, title: 'Rides per day', period: 'last 7 days', unit: 'rides'));
    expect(find.bySemanticsLabel('Rides per day, last 7 days, peak 42 rides on 4 Nov'), findsOneWidget);
    final box = tester.getRect(find.descendant(of: find.byType(AdminBarChart), matching: find.byType(CustomPaint)));
    await tester.tapAt(Offset(box.right - 10, box.center.dy));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: box.center);
    await mouse.moveTo(Offset(box.left + box.width * 0.6, box.center.dy));
    await tester.pump();
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('bar chart: empty state and loading skeleton', (tester) async {
    await pump(tester, AdminBarChart(values: const [0, 0, 0], labels: labels.sublist(0, 3), title: 'Rides per day', period: 'last 7 days', emptyText: 'No rides yet'));
    expect(find.text('No rides yet'), findsOneWidget);
    await pump(tester, AdminBarChart(values: const [], labels: const [], title: 'Rides per day', period: 'last 7 days', loading: true));
    expect(find.byType(ChartSkeleton), findsOneWidget);
  });

  testWidgets('line chart with the previous period, at phone and desktop widths, both themes', (tester) async {
    for (final (width, palette) in [(360.0, AppPalette.light), (1000.0, AppPalette.dark)]) {
      final semantics = tester.ensureSemantics();
      await pump(
        tester,
        AdminLineChart(values: const [2, 4, 3, 6, 5, 8, 7], previous: const [1, 2, 2, 3, 3, 4, 4], labels: labels, title: 'Active riders', period: 'last 7 days', unit: 'riders'),
        width: width,
        palette: palette,
      );
      expect(find.bySemanticsLabel(RegExp(r'^Active riders, last 7 days, peak 8 riders on 6 Nov, previous period 19 in total against 35')), findsOneWidget);
      await tester.tapAt(tester.getCenter(find.descendant(of: find.byType(AdminLineChart), matching: find.byType(CustomPaint))));
      await tester.pump();
      expect(tester.takeException(), isNull);
      semantics.dispose();
    }
  });

  testWidgets('horizontal bars: labels, values and shares; empty state', (tester) async {
    await pump(tester, const AdminHorizontalBars(title: 'Riders per plan', items: [HBarItem('Community', 30, highlight: false), HBarItem('Small group', 10)]));
    expect(find.text('Community'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    await pump(tester, const AdminHorizontalBars(title: 'Riders per plan', items: [], emptyText: 'No riders yet'));
    expect(find.text('No riders yet'), findsOneWidget);
  });

  testWidgets('trend tile: arrow chip against the previous period, red when more is worse', (tester) async {
    await pump(
      tester,
      const Column(children: [
        AdminTrendTile(label: 'Rides', value: '12', current: 12, previous: 10, spark: [1, 2, 3]),
        AdminTrendTile(label: 'SOS', value: '4', current: 4, previous: 2, upIsGood: false),
        AdminTrendTile(label: 'Open SOS', value: '0', current: 0, note: 'All clear'),
      ]),
    );
    expect(find.text('▲ 20%'), findsOneWidget);
    expect(find.text('▲ 100%'), findsOneWidget);
    expect(find.text('All clear'), findsOneWidget);
    final up = tester.widget<Text>(find.text('▲ 100%'));
    expect(up.style?.color, AppPalette.light.danger);
    final good = tester.widget<Text>(find.text('▲ 20%'));
    expect(good.style?.color, AppPalette.light.success);
  });
}
