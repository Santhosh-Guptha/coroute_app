import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/ui/ui.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/explore_service.dart';
import 'package:coroute_app/domain/explore/destinations.dart';
import 'package:coroute_app/domain/explore/explore_config.dart';
import 'package:coroute_app/presentation/explore/explore_screen.dart';
import 'package:coroute_app/presentation/shell/coroute_nav_bar.dart';

/// v3.59 Explore laid out by the admin (sections, order, titles, categories incl. custom, featured) with rider route
/// counts; the new bottom bar. Both themes, 320 dp, text x1.3 and x2, no overflow.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    AppTheme.use(AppPalette.dark);
    SwrCache.shared.clear();
  });

  final places = [
    Destination.fromJson({'id': 'ds_000000000001', 'name': 'Nandi Hills', 'region': 'Karnataka', 'lat': 13.3702, 'lng': 77.6835, 'category': 'breakfast'})!,
    Destination.fromJson({'id': 'ds_000000000002', 'name': 'Ooty, the Queen of Hill Stations in the Nilgiris', 'region': 'Tamil Nadu', 'lat': 11.4102, 'lng': 76.695, 'category': 'weekend', 'tags': ['ghats']})!,
    Destination.fromJson({'id': 'ds_000000000003', 'name': 'Filter Coffee Point', 'region': 'Karnataka', 'lat': 13.1, 'lng': 77.6, 'category': 'coffee'})!,
  ];
  final config = ExploreConfig.fromJson({
    'headline': 'Ride somewhere new this weekend with your crew',
    'subtitle': 'Places riders love.',
    'sections': [
      {'id': 'featured', 'title': 'Owner picks'},
      {'id': 'rider_routes', 'title': 'Ridden by CoRoute riders'},
      {'id': 'near_you', 'title': 'Rides near you'},
      {'id': 'suggest', 'title': 'Know a great ride?'},
    ],
    'categories': [
      {'id': 'coffee', 'label': 'Coffee runs'},
      {'id': 'breakfast', 'label': 'Breakfast rides'},
      {'id': 'ghats', 'label': 'Ghats and hills'},
      {'id': 'night', 'label': 'Night rides'},
    ],
    'featured': ['ds_000000000002'],
    'routes': {'enabled': true},
  });

  Future<ApiClient> api() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    return ApiClient(httpClient: MockClient((_) async => http.Response('{}', 404)), storage: const FlutterSecureStorage());
  }

  Future<void> render(WidgetTester tester, Widget child, ApiClient a, {AppPalette p = AppPalette.dark, double scale = 1.3}) async {
    final oldHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      debugPrint('OVERFLOW WIDGET DETAILS:');
      debugPrint(details.toString());
      oldHandler?.call(details);
    };
    AppTheme.use(p);
    const size = Size(320, 2400);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<ApiClient>.value(
      value: a,
      child: MaterialApp(theme: AppTheme.themeFor(p), home: MediaQuery(data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale), disableAnimations: true), child: child)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    FlutterError.onError = oldHandler;
  }

  for (final p in [AppPalette.light, AppPalette.dark]) {
    for (final scale in [1.3, 2.0]) {
      testWidgets('Explore follows the admin layout, no overflow (${p.isLight ? 'light' : 'dark'}, x$scale)', (tester) async {
        final a = await api();
        SwrCache.shared.put<ExploreData>(ExploreService.dataKey, ExploreData(config, places, const {'ds_000000000001': 3}));
        await render(tester, const ExploreScreen(), a, p: p, scale: scale);
        expect(tester.takeException(), isNull);
        expect(find.text('Ride somewhere new this weekend with your crew'), findsOneWidget);
        expect(find.text('Owner picks'), findsOneWidget);
        expect(find.byKey(const Key('explore_featured')), findsOneWidget);
        expect(find.byKey(const Key('explore_hero')), findsOneWidget);
        expect(find.byKey(const Key('explore_ridden')), findsOneWidget, reason: 'Nandi Hills has 3 rider routes');
        expect(find.text('3 riders shared their routes'), findsOneWidget);
        expect(find.byKey(const Key('explore_list')), findsOneWidget);
        // Chips: admin order, only categories some place uses (no Night rides).
        expect(find.byKey(const Key('chip_coffee')), findsOneWidget);
        expect(find.byKey(const Key('chip_night')), findsNothing);
        await tester.tap(find.byKey(const Key('chip_coffee')));
        await tester.pump(const Duration(milliseconds: 300));
        final err2 = tester.takeException();
        if (err2 is FlutterError) {
          debugPrint('DETAILS: ${err2.diagnostics.map((d) => d.toString()).join("\n")}');
        }
        expect(err2, isNull);
        expect(find.text('Filter Coffee Point'), findsWidgets);
        expect(find.text('Nandi Hills'), findsNothing);
      });
    }
  }

  testWidgets('no rider routes yet: the "be the first" invitation', (tester) async {
    final a = await api();
    SwrCache.shared.put<ExploreData>(ExploreService.dataKey, ExploreData(config, places, const {}));
    await render(tester, const ExploreScreen(), a);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('explore_be_first')), findsOneWidget);
    expect(find.text('Be the first to guide others'), findsOneWidget);
  });

  testWidgets('bottom bar: road-shaped Ride key, labels fit at 320 dp x1.3', (tester) async {
    final taps = <NavSlot>[];
    AppTheme.use(AppPalette.light);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(AppPalette.light),
      home: MediaQuery(
        data: const MediaQueryData(size: Size(320, 640), textScaler: TextScaler.linear(1.3)),
        child: Scaffold(body: const SizedBox.expand(), bottomNavigationBar: CoRouteNavBar(selected: NavSlot.explore, onSelect: taps.add, onPlus: () {})),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(RoadStripe), findsWidgets);
    expect(tester.getSize(find.byKey(const Key('nav_plus'))).width, greaterThanOrEqualTo(CoRouteNavBar.plusSize));
  });
}
