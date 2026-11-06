import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/presentation/settings/feature_catalog.dart';
import 'package:coroute_app/presentation/settings/features_guide_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpGuide(
    WidgetTester tester, {
    void Function(BuildContext, SettingsTarget)? onOpen,
    double scale = 1.0,
  }) async {
    AppTheme.use(AppPalette.dark);
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(AppPalette.dark),
      home: MediaQuery(
        data: MediaQueryData(size: const Size(420, 2400), textScaler: TextScaler.linear(scale)),
        child: FeaturesGuideScreen(onOpenSettings: onOpen),
      ),
    ));
    await tester.pump();
  }

  group('Feature catalog', () {
    test('every group has entries and ids are unique', () {
      for (final g in FeatureGroup.values) {
        expect(featureCatalog.where((f) => f.group == g), isNotEmpty, reason: g.label);
      }
      final ids = featureCatalog.map((f) => f.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('names are short and texts are one line', () {
      for (final f in featureCatalog) {
        expect(f.name.split(' ').length, lessThanOrEqualTo(4), reason: f.name);
        expect(f.what.length, lessThanOrEqualTo(90), reason: f.id);
        expect(f.when.length, lessThanOrEqualTo(70), reason: f.id);
        expect(f.privacy.length, lessThanOrEqualTo(80), reason: f.id);
      }
    });

    test('search matches every word, any case', () {
      final garage = featureCatalog.firstWhere((f) => f.id == 'garage');
      expect(garage.matches(''), isTrue);
      expect(garage.matches('garage'), isTrue);
      expect(garage.matches('service dates'), isTrue);
      expect(garage.matches('hotspot'), isFalse);
    });
  });

  group('Features guide screen', () {
    testWidgets('shows the title, search and the first groups', (tester) async {
      await pumpGuide(tester);
      expect(find.text('Features guide'), findsOneWidget);
      expect(find.byKey(FeaturesGuideScreen.searchKey), findsOneWidget);
      expect(find.text('Riding'), findsOneWidget);
      expect(find.text('Live ride map'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Safety'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('Safety'), findsOneWidget);
    });

    testWidgets('search filters the list', (tester) async {
      await pumpGuide(tester);
      await tester.enterText(find.byKey(FeaturesGuideScreen.searchKey), 'garage');
      await tester.pump();
      expect(find.text('Garage'), findsOneWidget);
      expect(find.text('Live ride map'), findsNothing);
      expect(find.text('Safety'), findsNothing);

      await tester.enterText(find.byKey(FeaturesGuideScreen.searchKey), 'hands-free');
      await tester.pump();
      expect(find.text('Talk'), findsOneWidget);
      expect(find.text('Hands-free talk'), findsOneWidget);
      expect(find.text('Garage'), findsNothing);

      await tester.enterText(find.byKey(FeaturesGuideScreen.searchKey), 'zzzz');
      await tester.pump();
      expect(find.textContaining('No features match'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      expect(find.text('Live ride map'), findsOneWidget);
    });

    testWidgets('a tile expands to details and opens its settings', (tester) async {
      SettingsTarget? opened;
      await pumpGuide(tester, onOpen: (_, t) => opened = t);
      await tester.enterText(find.byKey(FeaturesGuideScreen.searchKey), 'garage');
      await tester.pump();
      await tester.tap(find.text('Garage'));
      await tester.pumpAndSettle();
      expect(find.text('Battery: None'), findsOneWidget);
      expect(find.text('Data: None'), findsOneWidget);
      expect(find.text('Change in settings'), findsOneWidget);
      await tester.tap(find.text('Change in settings'));
      await tester.pump();
      expect(opened, SettingsTarget.garage);
    });

    testWidgets('large text does not overflow', (tester) async {
      await pumpGuide(tester, scale: 1.6);
      await tester.tap(find.text('Live ride map'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
