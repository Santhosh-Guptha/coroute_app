import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/ui/ui.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/services/geo_service.dart';
import 'package:coroute_app/presentation/map_picker/map_picker_screen.dart';
import 'package:coroute_app/presentation/trip_planner/trip_review_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => AppTheme.use(AppPalette.dark));

  Future<void> render(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(400, 800),
    double scale = 1.0,
    AppPalette palette = AppPalette.dark,
  }) async {
    AppTheme.use(palette);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(palette),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: Scaffold(body: child),
        ),
      ),
    ));
    await tester.pump();
  }

  group('Stop types', () {
    test('wire codes: Meeting is MEETING, Custom is OTHER, and they read back', () {
      expect(stopWireCode(StopKind.fuel), 'FUEL');
      expect(stopWireCode(StopKind.food), 'FOOD');
      expect(stopWireCode(StopKind.rest), 'REST');
      expect(stopWireCode(StopKind.meeting), 'MEETING');
      expect(stopWireCode(StopKind.custom), 'OTHER');
      for (final k in StopKind.pickable) {
        expect(StopKind.fromCategory(stopWireCode(k)), k);
      }
      expect(StopKind.pickable.map(stopKindChoiceLabel).toList(), ['Fuel', 'Food', 'Rest', 'Meeting', 'Custom']);
    });

    testWidgets('the five choices wrap at 320 dp and report the tapped type', (tester) async {
      StopKind? picked;
      await render(
        tester,
        StatefulBuilder(
          builder: (context, setState) => StopKindChoices(
            selected: picked,
            onSelected: (k) => setState(() => picked = k),
          ),
        ),
        size: const Size(320, 568),
        scale: 1.3,
      );
      expect(tester.takeException(), isNull);
      for (final l in ['Fuel', 'Food', 'Rest', 'Meeting', 'Custom']) {
        expect(find.text(l), findsOneWidget);
      }
      await tester.tap(find.text('Meeting'));
      await tester.pump();
      expect(picked, StopKind.meeting);
    });
  });

  group('Recent places', () {
    test('newest first, no duplicates, at most five', () async {
      SharedPreferences.setMockInitialValues({});
      for (var i = 0; i < 7; i++) {
        await RecentPlaces.remember(PickedPlace(lat: 17.0 + i, lng: 78.0, name: 'Place $i'));
      }
      await RecentPlaces.remember(const PickedPlace(lat: 20.0, lng: 78.0, name: 'Place 3'));
      final list = await RecentPlaces.load();
      expect(list.length, RecentPlaces.max);
      expect(list.first.name, 'Place 3');
      expect(list.where((p) => p.name == 'Place 3').length, 1);
      expect(list.map((p) => p.name), isNot(contains('Place 0')));
    });

    test('a nameless place is not remembered', () async {
      SharedPreferences.setMockInitialValues({});
      await RecentPlaces.remember(const PickedPlace(lat: 17, lng: 78));
      expect(await RecentPlaces.load(), isEmpty);
    });
  });

  group('Review sheet', () {
    Widget host(void Function(int?) onResult, {RouteModel? route, String? destination = 'Fort'}) => Builder(
          builder: (context) => TextButton(
            onPressed: () async => onResult(await TripReviewSheet.show(
              context,
              name: 'Sunday ride',
              startName: 'Home',
              destinationName: destination,
              route: route,
              stops: 2,
            )),
            child: const Text('open'),
          ),
        );

    testWidgets('shows the route summary and returns the chosen speed limit on Start Ride', (tester) async {
      int? result = -1;
      await render(tester, host((r) => result = r, route: RouteModel(distanceM: 186000, durationS: 5 * 3600 + 40 * 60, polyline: '')));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Sunday ride'), findsOneWidget);
      expect(find.text('From Home to Fort'), findsOneWidget);
      expect(find.text('186 km'), findsOneWidget);
      expect(find.text('5 h 40 min'), findsOneWidget);
      expect(find.text('Departs'), findsOneWidget);
      expect(find.text('Group speed limit'), findsOneWidget);
      await tester.tap(find.text('60'));
      await tester.pump();
      expect(find.text('60 km/h'), findsOneWidget);
      await tester.tap(find.text('Start Ride'));
      await tester.pumpAndSettle();
      expect(result, 60);
    });

    testWidgets('closing the sheet cancels; no route says so in words', (tester) async {
      int? result = -1;
      await render(tester, host((r) => result = r, destination: null));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('No destination yet. You can set it during the ride.'), findsOneWidget);
      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });

    for (final palette in [AppPalette.dark, AppPalette.light]) {
      testWidgets('fits 320 x 568 at text x1.3 (${palette.brightness.name}); Start Ride stays visible', (tester) async {
        await render(
          tester,
          host((_) {}, route: RouteModel(distanceM: 214600, durationS: 20400, polyline: '', approximate: true)),
          size: const Size(320, 568),
          scale: 1.3,
          palette: palette,
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Start Ride'), findsOneWidget);
        final button = find.ancestor(of: find.text('Start Ride'), matching: find.byWidgetPredicate((w) => w is FilledButton));
        expect(tester.getSize(button.first).height, greaterThanOrEqualTo(56));
      });
    }

    test('from/to line', () {
      expect(TripReviewSheet.fromTo('Home', 'Fort'), 'From Home to Fort');
      expect(TripReviewSheet.fromTo('Home', null), 'From Home');
      expect(TripReviewSheet.fromTo(null, 'Fort'), 'To Fort');
      expect(TripReviewSheet.fromTo(' ', ''), '');
    });
  });
}
