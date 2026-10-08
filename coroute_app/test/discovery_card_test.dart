import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/network_models.dart';
import 'package:coroute_app/domain/notify/alert_priority.dart';
import 'package:coroute_app/presentation/ride/discovery_card.dart';

void main() {
  tearDown(() => AppTheme.use(AppPalette.dark));

  Encounter encounter({String type = 'SAME_DIRECTION', bool sameRoute = true, int? meetingS}) => Encounter.fromJson({
        'encounterId': 'ENC-0123456789AB',
        'state': 'NEW',
        'type': type,
        'groupName': 'Weekend Riders',
        'riders': 6,
        'distanceM': 4700,
        'meetingS': ?meetingS,
        'sameRoute': sameRoute,
      }, at: 1)!;

  Future<void> render(WidgetTester tester, Widget child, {Size size = const Size(320, 568), AppPalette palette = AppPalette.dark}) async {
    AppTheme.use(palette);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(palette),
      builder: (context, w) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
        child: w ?? const SizedBox.shrink(),
      ),
      home: Scaffold(body: Padding(padding: const EdgeInsets.all(12), child: child)),
    ));
    await tester.pump();
  }

  test('texts: name, rider count, rounded distance, how the groups move; no coordinates', () {
    final e = encounter();
    expect(DiscoveryTexts.title(e), 'Weekend Riders nearby');
    expect(DiscoveryTexts.size(e), '6 riders, about 4.7 km');
    expect(DiscoveryTexts.how(e), 'Travelling on the same route');
    expect(DiscoveryTexts.how(encounter(type: 'OPPOSITE_DIRECTION')), 'Approaching from the opposite direction');
    expect(DiscoveryTexts.how(encounter(type: 'CONVERGING')), 'Joining your route ahead');
    expect(DiscoveryTexts.how(encounter(type: 'CROSSING')), 'Crossing your route ahead');
    expect(DiscoveryTexts.meeting(encounter(meetingS: 180)), 'You may meet in about 3 min');
    expect(DiscoveryTexts.meeting(e), isNull);
    expect(DiscoveryTexts.waved(e), 'Weekend Riders waved');
  });

  for (final palette in [AppPalette.light, AppPalette.dark]) {
    for (final size in [const Size(320, 568), const Size(568, 320)]) {
      testWidgets('card at x1.3 ${palette.isLight ? 'light' : 'dark'} ${size.width.round()}: View, Wave once, Ignore', (tester) async {
        var views = 0, waves = 0, ignores = 0;
        await render(
          tester,
          DiscoveryCard(encounter: encounter(), onView: () => views++, onWave: () => waves++, onIgnore: () => ignores++),
          size: size,
          palette: palette,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Weekend Riders nearby'), findsOneWidget);
        await tester.tap(find.text('View Group'));
        await tester.tap(find.text('Wave'));
        await tester.tap(find.text('Ignore'));
        expect((views, waves, ignores), (1, 1, 1));
      });
    }
  }

  testWidgets('after waving the button says Waved and does nothing', (tester) async {
    var waves = 0;
    await render(tester, DiscoveryCard(encounter: encounter().copyWith(iWaved: true), onView: () {}, onWave: () => waves++, onIgnore: () {}));
    expect(find.text('Wave'), findsNothing);
    await tester.tap(find.text('Waved'));
    expect(waves, 0);
  });

  test('never shown during an emergency, an assistance request or a hazard', () {
    expect(AlertArbiter.socialAllowed(anyEmergency: false, anyAssist: false, anyHazard: false), isTrue);
    expect(AlertArbiter.socialAllowed(anyEmergency: true, anyAssist: false, anyHazard: false), isFalse);
    expect(AlertArbiter.socialAllowed(anyEmergency: false, anyAssist: true, anyHazard: false), isFalse);
    expect(AlertArbiter.socialAllowed(anyEmergency: false, anyAssist: false, anyHazard: true), isFalse);
  });

  testWidgets('View Group sheet: facts only, Wave', (tester) async {
    var waves = 0;
    await render(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showDiscoverySheet(context, encounter(type: 'OPPOSITE_DIRECTION', meetingS: 180), onWave: () => waves++),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Weekend Riders'), findsOneWidget);
    expect(find.text('Approaching from the opposite direction'), findsOneWidget);
    expect(find.text('You may meet in about 3 min'), findsOneWidget);
    await tester.tap(find.text('Wave'));
    await tester.pumpAndSettle();
    expect(waves, 1);
  });
}
