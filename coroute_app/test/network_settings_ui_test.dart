import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/constants/network_constants.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/presentation/ride/group_settings_sheet.dart';
import 'package:coroute_app/presentation/ride/network_consent_sheet.dart';
import 'package:coroute_app/presentation/safety/safety_settings_sheet.dart';
import 'package:coroute_app/presentation/settings/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => AppTheme.use(AppPalette.dark));

  /// AuthService whose PATCH /me echoes the body back (like the gateway's selfUser).
  (AuthService, List<Map<String, dynamic>>) authWithPatches({bool fail = false}) {
    final patches = <Map<String, dynamic>>[];
    final api = ApiClient(
      httpClient: MockClient((req) async {
        if (req.method == 'PATCH' && req.url.path.endsWith('/me')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          patches.add(body);
          if (fail) return http.Response(jsonEncode({'error': 'offline'}), 503);
          final echo = <String, dynamic>{'userId': 'u1', 'email': 'a@example.com', 'name': 'Asha', ...body};
          if (body['netConsent'] == true) echo['netConsentAt'] = 1800000000000;
          echo.remove('netConsent');
          return http.Response(jsonEncode(echo), 200);
        }
        return http.Response('{}', 200);
      }),
      storage: const FlutterSecureStorage(),
    );
    return (AuthService(api), patches);
  }

  Future<void> host(WidgetTester tester, Widget child, {required SettingsService settings, AuthService? auth, Size size = const Size(320, 640)}) async {
    AppTheme.use(AppPalette.dark);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = MaterialApp(
      theme: AppTheme.themeFor(AppPalette.dark),
      builder: (context, w) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
        child: w ?? const SizedBox.shrink(),
      ),
      home: Scaffold(body: child),
    );
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        if (auth != null) ChangeNotifierProvider<AuthService>.value(value: auth),
      ],
      child: app,
    ));
    await tester.pump();
  }

  testWidgets('Settings: nearby riders switches write the profile, the others the phone settings', (tester) async {
    final settings = SettingsService();
    await settings.load();
    final (auth, patches) = authWithPatches();
    await host(tester, const SettingsScreen(), settings: settings, auth: auth);
    expect(tester.takeException(), isNull);
    // 3.55: the list grew (sound rows, some hidden by admin switches) and is built lazily, so only
    // check that the switches render; the rows below are checked one by one.
    expect(find.byType(Switch), findsWidgets);
    final list = find.byType(Scrollable).first;

    await tester.scrollUntilVisible(find.text(SafetyTexts.helpTitle), 80, scrollable: list);
    expect(auth.assistHelp, isTrue, reason: 'default on');
    await tester.tap(find.text(SafetyTexts.helpTitle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(patches.last, {'assistHelp': false});
    expect(auth.assistHelp, isFalse);

    // Medical info has no sharing switch anywhere (always shared with responders in an emergency).
    expect(find.text(SafetyTexts.medicalTitle), findsNothing);

    await tester.scrollUntilVisible(find.text(SafetyTexts.hazardTitle), 80, scrollable: list);
    expect(settings.hazardAlerts, isTrue);
    await tester.tap(find.text(SafetyTexts.hazardTitle));
    await tester.pump();
    expect(settings.hazardAlerts, isFalse);

    await tester.scrollUntilVisible(find.text(SafetyTexts.voiceWarningsTitle), 80, scrollable: list);
    await tester.tap(find.text(SafetyTexts.voiceWarningsTitle));
    await tester.pump();
    expect(settings.voiceWarnings, isFalse);

    await tester.scrollUntilVisible(find.text(SafetyTexts.lockTitle), 80, scrollable: list);
    expect(settings.rideOnLockScreen, isTrue);
    await tester.tap(find.text(SafetyTexts.lockTitle));
    await tester.pump();
    expect(settings.rideOnLockScreen, isFalse);
    expect(patches, hasLength(1), reason: 'phone-only settings never call the server');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a refused save puts the switch back and says so', (tester) async {
    final settings = SettingsService();
    await settings.load();
    final (auth, _) = authWithPatches(fail: true);
    await host(tester, const SettingsScreen(), settings: settings, auth: auth);
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text(SafetyTexts.askTitle), 80, scrollable: list);
    await tester.tap(find.text(SafetyTexts.askTitle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(auth.assistAsk, isTrue);
    expect(find.text(SafetyTexts.saveFailed), findsOneWidget);
  });

  testWidgets('consent: shown before a ride until answered; Later at most 3 times; Continue saves with consent', (tester) async {
    final settings = SettingsService();
    await settings.load();
    final (auth, patches) = authWithPatches();
    expect(NetworkConsentSheet.due(settings, auth), isTrue);
    expect(NetworkConsentSheet.due(null, auth), isFalse);

    await host(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => NetworkConsentSheet.maybeShow(context),
          child: const Text('ride'),
        ),
      ),
      settings: settings,
      auth: auth,
      size: const Size(320, 640),
    );

    // Later: kept on, asked again next time.
    await tester.tap(find.text('ride'));
    await tester.pumpAndSettle();
    expect(find.text('Riders helping riders'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(settings.netConsentPrompts, 1);
    expect(patches, isEmpty);

    // Continue: the assistance switches and the consent are saved (medical info has no switch).
    await tester.tap(find.text('ride'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(patches.single, {'assistHelp': true, 'assistAsk': true, 'netConsent': true});
    expect(settings.netConsentSeen, isTrue);
    expect(auth.netConsentAt, greaterThan(0));
    expect(NetworkConsentSheet.due(settings, auth), isFalse);

    // Answered: never again.
    await tester.tap(find.text('ride'));
    await tester.pumpAndSettle();
    expect(find.text('Riders helping riders'), findsNothing);
  });

  test('consent: no more than the maximum number of prompts', () async {
    final settings = SettingsService();
    await settings.load();
    final (auth, _) = authWithPatches();
    for (var i = 0; i < NetworkConstants.netConsentMaxPrompts; i++) {
      expect(NetworkConsentSheet.due(settings, auth), isTrue);
      await settings.bumpNetConsentPrompts();
    }
    expect(NetworkConsentSheet.due(settings, auth), isFalse);
  });

  testWidgets('group visibility: lead only; discovery only while Public; Private turns discovery off', (tester) async {
    final settings = SettingsService();
    await settings.load();
    final calls = <(GroupVisibility?, bool?, bool?)>[];
    void record({GroupVisibility? visibility, bool? discovery, bool? assistDefault}) => calls.add((visibility, discovery, assistDefault));

    // Not the lead: everything is shown, nothing can change.
    await host(
      tester,
      SingleChildScrollView(
        child: GroupNetworkSettings(visibility: GroupVisibility.private, discovery: false, assistDefault: true, lead: false, onChanged: record),
      ),
      settings: settings,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Private'), findsOneWidget);
    expect(find.text(GroupNetworkSettings.discoveryExplain), findsOneWidget);
    for (final sw in tester.widgetList<SwitchListTile>(find.byType(SwitchListTile))) {
      expect(sw.onChanged, isNull);
    }
    await tester.tap(find.text('Public'));
    await tester.pump();
    expect(calls, isEmpty);

    // The lead, Private: discovery switch disabled, Public can be chosen.
    await host(
      tester,
      SingleChildScrollView(
        child: GroupNetworkSettings(visibility: GroupVisibility.private, discovery: false, assistDefault: true, lead: true, onChanged: record),
      ),
      settings: settings,
    );
    final discovery = tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, GroupNetworkSettings.discoveryTitle));
    expect(discovery.onChanged, isNull);
    expect(discovery.value, isFalse);
    await tester.tap(find.text('Public'));
    await tester.pump();
    expect(calls.last, (GroupVisibility.public, null, null));
    await tester.tap(find.text(GroupNetworkSettings.assistTitle));
    await tester.pump();
    expect(calls.last, (null, null, false));

    // The lead, Public: discovery can be turned on; Private turns it off again.
    await host(
      tester,
      SingleChildScrollView(
        child: GroupNetworkSettings(visibility: GroupVisibility.public, discovery: false, assistDefault: true, lead: true, onChanged: record),
      ),
      settings: settings,
    );
    await tester.tap(find.text(GroupNetworkSettings.discoveryTitle));
    await tester.pump();
    expect(calls.last, (null, true, null));
    await tester.tap(find.text('Private'));
    await tester.pump();
    expect(calls.last, (GroupVisibility.private, false, null));
  });
}
