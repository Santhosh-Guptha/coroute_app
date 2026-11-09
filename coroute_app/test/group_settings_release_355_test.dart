// 3.55 fix: group setting sliders preview while dragging and send once on release
// (docs/SETTINGS_LIVE_AUDIT_v3.55.md, remaining issue 3).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/presentation/ride/group_settings_sheet.dart';

void main() {
  Future<List<double>> pumpSlider(WidgetTester tester, {bool enabled = true}) async {
    final commits = <double>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: ReleaseSlider(
              value: 1000,
              min: 500,
              max: 5000,
              divisions: 9,
              label: (v) => '${v.round()} m',
              onCommit: enabled ? commits.add : null,
              builder: (v, slider) => Column(mainAxisSize: MainAxisSize.min, children: [Text('shown ${v.round()}'), slider]),
            ),
          ),
        ),
      ),
    ));
    return commits;
  }

  testWidgets('a drag previews locally and commits once, on release', (tester) async {
    final commits = await pumpSlider(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.byType(Slider)));
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
    }
    expect(commits, isEmpty, reason: 'nothing is sent while dragging');
    expect(find.text('shown 1000'), findsNothing, reason: 'the row previews the drag value');
    await gesture.up();
    await tester.pump();
    expect(commits, hasLength(1));
    expect(commits.single, isNot(1000));
  });

  testWidgets('disabled for a non-lead: no commit', (tester) async {
    final commits = await pumpSlider(tester, enabled: false);
    await tester.drag(find.byType(Slider), const Offset(100, 0));
    await tester.pump();
    expect(commits, isEmpty);
    expect(find.text('shown 1000'), findsOneWidget);
  });
}
