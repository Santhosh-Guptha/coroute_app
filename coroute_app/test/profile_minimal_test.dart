// Profile tab, minimal (owner direction Nov 11; docs/SETTINGS_MINIMAL_v3.55.md): top box with
// picture, full name and @username plus the Settings gear; My bikes; Emergency contact & Medical ID;
// rider score + Leaderboard; Help with exactly three rows; Account with Sign out and Delete account.
// No plan row, no ride history, no separate report / suggest rows.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/engagement_service.dart';
import 'package:coroute_app/data/services/meta_service.dart';
import 'package:coroute_app/presentation/account/account_screen.dart';
import 'package:coroute_app/presentation/account/privacy_terms_sheet.dart';
import 'package:coroute_app/presentation/engagement/rate_and_feedback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      AppConstants.keyUserId: 'rider_1',
      AppConstants.keyUserRole: AppConstants.riderRole,
      AppConstants.keyUserName: 'Asha Rao',
      AppConstants.keyUserEmail: 'asha@example.com',
    });
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => AppTheme.use(AppPalette.dark));

  Future<(AuthService, MetaService)> services() async {
    const storage = FlutterSecureStorage();
    await storage.write(key: 'coroute_jwt', value: 'rider_jwt');
    final api = ApiClient(
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/me')) {
          return http.Response(
              jsonEncode({'userId': 'rider_1', 'role': AppConstants.riderRole, 'name': 'Asha Rao', 'email': 'asha@example.com', 'username': 'asha_rides'}),
              200);
        }
        return http.Response('{}', 200);
      }),
      storage: storage,
    );
    await api.init();
    final auth = AuthService(api);
    await auth.revalidate();
    return (auth, MetaService(api));
  }

  Future<void> pump(WidgetTester tester, AuthService auth, MetaService meta) async {
    AppTheme.use(AppPalette.light);
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider<MetaService>.value(value: meta),
      ],
      child: MaterialApp(theme: AppTheme.themeFor(AppPalette.light), home: const AccountScreen(embedded: true)),
    ));
    await tester.pump();
  }

  testWidgets('top box: full name, @username and the Settings gear', (tester) async {
    final (auth, meta) = await services();
    await pump(tester, auth, meta);
    expect(tester.takeException(), isNull);
    final box = find.byKey(const Key('profile_top_box'));
    expect(box, findsOneWidget);
    expect(find.descendant(of: box, matching: find.text('Asha Rao')), findsOneWidget);
    expect(find.descendant(of: box, matching: find.text('@asha_rides')), findsOneWidget);
    expect(find.descendant(of: box, matching: find.byKey(const Key('profile_settings'))), findsOneWidget);
  });

  testWidgets('no plan row, no ride history, no separate report / suggest / diagnostics rows', (tester) async {
    final (auth, meta) = await services();
    await pump(tester, auth, meta);
    for (final gone in ['Your plan', 'Ride history', 'Report a problem', 'Suggest a safety feature', 'Diagnostics', 'Change password', 'Your ride analytics']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    expect(find.byIcon(Icons.card_membership_rounded), findsNothing);
    for (final gone in ['profile_suggest_feature', 'profile_ride_analytics', 'profile_public_profile']) {
      expect(find.byKey(Key(gone)), findsNothing, reason: gone);
    }
    expect(find.byKey(const Key('profile_garage')), findsOneWidget);
    expect(find.byKey(const Key('profile_emergency')), findsOneWidget);
    expect(find.text(AccountScreen.emergencyTitle), findsOneWidget);
    expect(find.text(AccountScreen.garageTitle), findsOneWidget);
  });

  testWidgets('Help has exactly three rows; Account has exactly Sign out and Delete account', (tester) async {
    final (auth, meta) = await services();
    await pump(tester, auth, meta);
    expect(AccountScreen.helpRowKeys, hasLength(3));
    for (final k in AccountScreen.helpRowKeys) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    expect(find.text(RateAndFeedback.feedbackTitle), findsOneWidget);
    expect(find.text(RateAndFeedback.rateTitle), findsOneWidget);
    expect(find.text(PrivacyTermsSheet.title), findsOneWidget);
    expect(AccountScreen.accountRowKeys, hasLength(2));
    expect(find.text(AccountScreen.signOutTitle), findsOneWidget);
    expect(find.text(AccountScreen.deleteTitle), findsOneWidget);
  });

  testWidgets('Privacy & terms opens a sheet with privacy, terms and your data', (tester) async {
    final (auth, meta) = await services();
    await pump(tester, auth, meta);
    await tester.tap(find.byKey(const Key('profile_privacy_terms')));
    await tester.pumpAndSettle();
    expect(find.text(PrivacyTermsSheet.privacyLabel), findsOneWidget);
    expect(find.text(PrivacyTermsSheet.termsLabel), findsOneWidget);
    expect(find.text(PrivacyTermsSheet.yourDataLabel), findsOneWidget);
  });

  test('pure helpers: @handle and the three links', () {
    expect(AccountScreen.handleOf(''), '');
    expect(AccountScreen.handleOf('asha'), '@asha');
    expect(AccountScreen.handleOf('@asha'), '@asha');
    final (privacy, terms, data) = PrivacyTermsSheet.urlsFor(null, base: 'https://coroute.devmonks.space/');
    expect(privacy, 'https://coroute.devmonks.space/privacy');
    expect(terms, 'https://coroute.devmonks.space/terms');
    expect(data, 'https://coroute.devmonks.space/privacy-and-security');
  });

  group('Send feedback (one screen)', () {
    test('three categories, each a topic the gateway accepts', () {
      expect(FeedbackCategory.values.map((c) => c.label), ['Report a problem', 'Suggest a safety feature', 'Other']);
      for (final c in FeedbackCategory.values) {
        expect(EngagementService.feedbackTopics, contains(SendFeedbackScreen.topicFor(c)), reason: c.name);
      }
    });

    testWidgets('category picker, optional diagnostics log (off), and the Diagnostics link', (tester) async {
      AppTheme.use(AppPalette.light);
      tester.view.physicalSize = const Size(400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(AppPalette.light),
        home: const SendFeedbackScreen(initial: FeedbackCategory.safetyIdea),
      ));
      for (final c in FeedbackCategory.values) {
        expect(find.byKey(ValueKey('feedback_category:${c.name}')), findsOneWidget);
      }
      final chip = tester.widget<ChoiceChip>(find.byKey(const ValueKey('feedback_category:safetyIdea')));
      expect(chip.selected, isTrue);
      expect(find.text(SendFeedbackScreen.attachTitle), findsOneWidget);
      final attach = tester.widget<Switch>(find.descendant(of: find.byKey(const ValueKey('feedback_attach_log')), matching: find.byType(Switch)));
      expect(attach.value, isFalse, reason: 'the log is sent only when the rider turns this on');
      expect(find.byKey(const ValueKey('feedback_diagnostics')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('feedback_category:problem')));
      await tester.pump();
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('feedback_category:problem'))).selected, isTrue);
    });
  });
}
