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

  Future<void> openMore(WidgetTester tester) async {
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('settings_more')), 80, scrollable: list);
    await tester.tap(find.byKey(const ValueKey('settings_more')));
    await tester.pump();
  }

  testWidgets('Settings (Nov 11): no nearby riders switches anywhere; they are in the always-on list', (tester) async {
    final settings = SettingsService();
    await settings.load();
    final (auth, patches) = authWithPatches();
    await host(tester, const SettingsScreen(), settings: settings, auth: auth);
    expect(tester.takeException(), isNull);
    // Main screen: voice alerts, siren alerts, battery saver and data saver (push and leaderboard
    // need their services). Safety switches are gone: they are always on.
    expect(find.byType(Switch), findsNWidgets(4));
    expect(find.text(SafetyTexts.hazardTitle), findsNothing);
    expect(find.text(SafetyTexts.lockTitle), findsNothing);
    expect(find.text(SafetyTexts.crashTitle), findsNothing);
    final list = find.byType(Scrollable).first;

    await tester.scrollUntilVisible(find.byKey(const ValueKey('settings_spoken_alerts')), 80, scrollable: list);
    await tester.tap(find.byKey(const ValueKey('settings_spoken_alerts')));
    await tester.pump();
    expect(settings.voiceWarnings, isFalse);

    await openMore(tester);
    expect(find.text(SafetyTexts.helpTitle), findsNothing);
    expect(find.text(SafetyTexts.askTitle), findsNothing);
    expect(SettingsScreen.alwaysOn.map((e) => e.$2), containsAll([SafetyTexts.helpTitle, SafetyTexts.askTitle]));
    expect(auth.assistHelp, isTrue);
    expect(auth.assistAsk, isTrue);

    // Medical info has no sharing switch anywhere (always shared with responders in an emergency).
    expect(find.text(SafetyTexts.medicalTitle), findsNothing);
    expect(settings.hazardAlerts, isTrue);
    expect(settings.rideOnLockScreen, isTrue);
    expect(patches, isEmpty, reason: 'phone-only settings never call the server');
    expect(tester.takeException(), isNull);
  });

  test('always on: "off" is never sent to the server', () async {
    final (auth, patches) = authWithPatches();
    expect(await auth.updateNetworkPrefs(assistHelp: false, assistAsk: false), isTrue);
    expect(patches, isEmpty);
    expect(auth.assistHelp, isTrue);
    expect(auth.assistAsk, isTrue);
  });

  test('migration: a profile the gateway still has off is written back on once (PATCH /me)', () async {
    SharedPreferences.setMockInitialValues({'coroute_user_id': 'u1'});
    FlutterSecureStorage.setMockInitialValues({'coroute_jwt': 'jwt'});
    final patches = <Map<String, dynamic>>[];
    var server = <String, dynamic>{'userId': 'u1', 'email': 'a@example.com', 'name': 'Asha', 'assistHelp': false, 'assistAsk': true};
    final api = ApiClient(
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/me') && req.method == 'GET') return http.Response(jsonEncode(server), 200);
        if (req.url.path.endsWith('/me') && req.method == 'PATCH') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          patches.add(body);
          server = {...server, ...body};
          return http.Response(jsonEncode(server), 200);
        }
        return http.Response('{}', 200);
      }),
      storage: const FlutterSecureStorage(),
    );
    await api.init();
    final auth = AuthService(api);
    await auth.revalidate();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(patches, [
      {'assistHelp': true, 'assistAsk': true},
    ]);
    expect(auth.serverAssistOn, isTrue);
    // Already on: a later /me sends nothing more.
    await auth.revalidate();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(patches, hasLength(1));
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
    expect(find.byType(Switch), findsNothing, reason: 'always on since Nov 11: an explanation, no switches');
    expect(find.text(NetworkConsentSheet.alwaysOnNote), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(settings.netConsentPrompts, 1);
    expect(patches, isEmpty);

    // Continue: both always-on values and the consent are saved (medical info has no switch).
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
