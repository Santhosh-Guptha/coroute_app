import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/ui/ui.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/explore_service.dart';
import 'package:coroute_app/data/services/meta_service.dart';
import 'package:coroute_app/domain/explore/destinations.dart';
import 'package:coroute_app/presentation/account/account_screen.dart';
import 'package:coroute_app/presentation/chat/chat_list_screen.dart';
import 'package:coroute_app/presentation/explore/explore_screen.dart';
import 'package:coroute_app/presentation/home/home_screen.dart';
import 'package:coroute_app/presentation/onboarding/welcome_screen.dart';
import 'package:coroute_app/presentation/social/community_screen.dart';

/// v3.58 screens render with mocked services (no network answers), in both themes, at 320 dp and text x1.3.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    AppTheme.use(AppPalette.dark);
    SwrCache.shared.clear();
  });

  const destinations = [
    Destination(id: 'ds_000000000001', name: 'Nandi Hills', region: 'Karnataka', lat: 13.3702, lng: 77.6835, category: DestinationCategory.breakfast),
    Destination(id: 'ds_000000000002', name: 'Ooty', region: 'Tamil Nadu', lat: 11.4102, lng: 76.695, category: DestinationCategory.weekend, tags: [DestinationCategory.ghats]),
    Destination(id: 'ds_000000000003', name: 'Mysuru Palace', region: 'Karnataka', lat: 12.3052, lng: 76.6552, category: DestinationCategory.night),
  ];

  Future<(ApiClient, AuthService)> services() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final api = ApiClient(httpClient: MockClient((_) async => http.Response('{}', 404)), storage: const FlutterSecureStorage());
    return (api, AuthService(api));
  }

  Future<void> render(WidgetTester tester, Widget child, {AppPalette p = AppPalette.dark, Size size = const Size(320, 640), double scale = 1.3, List<SingleChildWidget> providers = const []}) async {
    AppTheme.use(p);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = MaterialApp(
      theme: AppTheme.themeFor(p),
      home: MediaQuery(data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale), disableAnimations: true), child: child),
    );
    await tester.pumpWidget(providers.isEmpty ? app : MultiProvider(providers: providers, child: app));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  for (final p in [AppPalette.dark, AppPalette.light]) {
    final label = p.isLight ? 'light' : 'dark';

    testWidgets('Home: sections, Emergency visible, safety nudge for a missing contact ($label)', (tester) async {
      final (api, auth) = await services();
      await render(tester, const HomeScreen(), p: p, size: const Size(320, 2200), providers: [
        ChangeNotifierProvider<ApiClient>.value(value: api),
        ChangeNotifierProvider<AuthService>.value(value: auth),
      ]);
      expect(tester.takeException(), isNull);
      for (final k in HomeScreen.sectionKeys) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: k);
      }
      expect(find.byKey(const Key('home_emergency')), findsOneWidget);
      expect(find.text('Emergency'), findsOneWidget);
      expect(find.byKey(const Key('home_avatar')), findsOneWidget);
      expect(find.byKey(const Key('home_alerts')), findsOneWidget);
      // No contact on a fresh account: the first nudge is the emergency contact.
      expect(find.byKey(const Key('home_nudge')), findsOneWidget);
      expect(find.textContaining('emergency contact'), findsWidgets);
      // The Emergency button is near the top (visible without scrolling on a small phone).
      expect(tester.getTopLeft(find.byKey(const Key('home_emergency'))).dy, lessThan(568));
    });

    testWidgets('Explore: cached places, nearest-first hero and list, chip filter ($label)', (tester) async {
      final (api, auth) = await services();
      SwrCache.shared.put<List<Destination>>(ExploreService.cacheKey, destinations);
      await render(tester, const ExploreScreen(), p: p, size: const Size(320, 1600), providers: [
        ChangeNotifierProvider<ApiClient>.value(value: api),
        ChangeNotifierProvider<AuthService>.value(value: auth),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('explore_search')), findsOneWidget);
      expect(find.byKey(const Key('explore_add')), findsOneWidget);
      expect(find.byKey(const Key('explore_hero')), findsOneWidget);
      expect(find.byKey(const Key('chip_ghats')), findsOneWidget, reason: 'a ghat place exists');
      expect(find.byKey(const Key('chip_twisty')), findsNothing, reason: 'no twisty place');
      await tester.ensureVisible(find.byKey(const Key('chip_night')));
      await tester.tap(find.byKey(const Key('chip_night')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Mysuru Palace'), findsOneWidget);
      expect(find.text('Ooty'), findsNothing);
      await tester.enterText(find.byKey(const Key('explore_search')), 'zzz');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Show all'), findsOneWidget);
    });

    testWidgets('Chat: clear empty state when there is no ride chat ($label)', (tester) async {
      final (_, auth) = await services();
      await render(tester, const ChatListScreen(), p: p, providers: [ChangeNotifierProvider<AuthService>.value(value: auth)]);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      expect(find.text(ChatListScreen.emptyTitle), findsOneWidget);
      expect(find.text('Start a ride'), findsOneWidget);
    });

    testWidgets('Welcome: our mark, two-line headline, both buttons, Call 112 ($label)', (tester) async {
      await render(tester, const WelcomeScreen(), p: p, size: const Size(320, 568));
      expect(tester.takeException(), isNull);
      expect(find.text(WelcomeScreen.headline1), findsOneWidget);
      expect(find.text(WelcomeScreen.headline2), findsOneWidget);
      expect(find.byKey(const Key('welcome_get_started')), findsOneWidget);
      expect(find.byKey(const Key('welcome_sign_in')), findsOneWidget);
      expect(find.byKey(const Key('welcome_call_112')), findsOneWidget);
    });

    testWidgets('Profile: cover header, checklist, Settings & info, sign out ($label)', (tester) async {
      final (api, auth) = await services();
      await render(tester, const AccountScreen(embedded: true), p: p, size: const Size(320, 3200), providers: [
        ChangeNotifierProvider<ApiClient>.value(value: api),
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider<MetaService>.value(value: MetaService(api)),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('profile_top_box')), findsOneWidget);
      expect(find.byKey(const Key('profile_settings')), findsOneWidget);
      expect(find.byKey(const Key('profile_checklist')), findsOneWidget);
      expect(find.text(AccountScreen.checklistTitle), findsOneWidget);
      expect(find.byKey(const Key('check_emergency_contact')), findsOneWidget);
      expect(find.text(AccountScreen.settingsInfoTitle), findsOneWidget);
      for (final k in [...AccountScreen.helpRowKeys, ...AccountScreen.accountRowKeys, 'profile_trips', 'profile_account', 'profile_notifications', 'profile_emergency', 'profile_advanced']) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: k);
      }
      expect(find.text('Your plan'), findsNothing, reason: 'no plan information');
    });

    testWidgets('Community: header and crews/clubs rail without the social services ($label)', (tester) async {
      final (api, auth) = await services();
      await render(tester, const CommunityScreen(), p: p, size: const Size(320, 1600), providers: [
        ChangeNotifierProvider<ApiClient>.value(value: api),
        ChangeNotifierProvider<AuthService>.value(value: auth),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.text(CommunityScreen.title), findsOneWidget);
      expect(find.text('Crews and clubs'), findsOneWidget);
      expect(find.text('Join a club'), findsOneWidget);
    });
  }
}
