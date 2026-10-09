import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/medical_info.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/presentation/account/profile_form.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => AppTheme.use(AppPalette.dark));

  group('medical patch (pure)', () {
    test('before the server sent the values only changed fields go out', () {
      final p = ProfileForm.medicalPatch(loaded: false, bloodGroup: 'O+', allergies: '', notes: '', smsOptOut: false);
      expect(p.bloodGroup, 'O+');
      expect(p.allergies, isNull);
      expect(p.medicalNotes, isNull);
      expect(p.smsOptOut, isNull);
    });
    test('once loaded every field goes out (so it can also be cleared)', () {
      final p = ProfileForm.medicalPatch(
        loaded: true,
        bloodGroup: '',
        allergies: ' penicillin ',
        notes: '',
        smsOptOut: true,
        initialBloodGroup: 'A+',
      );
      expect(p.bloodGroup, '');
      expect(p.allergies, 'penicillin');
      expect(p.medicalNotes, '');
      expect(p.smsOptOut, isTrue);
    });
    test('blood group choices: not set plus the eight groups', () {
      expect(ProfileForm.bloodGroupChoices, ['', ...MedicalInfo.bloodGroups]);
      expect(ProfileForm.allergiesMax, 120);
      expect(ProfileForm.medicalNotesMax, 200);
    });
  });

  Future<(AuthService, List<http.Request>)> render(WidgetTester tester, {required AppPalette palette, double scale = 1.3}) async {
    AppTheme.use(palette);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = <http.Request>[];
    final api = ApiClient(
      httpClient: MockClient((req) async {
        calls.add(req);
        if (req.method == 'PATCH' && req.url.path.endsWith('/me')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(jsonEncode({'userId': 'u1', 'email': 'asha@example.com', 'name': 'Asha', ...body}), 200);
        }
        return http.Response('{}', 200);
      }),
      storage: const FlutterSecureStorage(),
    );
    final auth = AuthService(api);
    await tester.pumpWidget(ChangeNotifierProvider<AuthService>.value(
      value: auth,
      child: MaterialApp(
        theme: AppTheme.themeFor(palette),
        builder: (context, w) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: w ?? const SizedBox.shrink(),
        ),
        home: const Scaffold(body: ProfileForm()),
      ),
    ));
    await tester.pump();
    return (auth, calls);
  }

  for (final palette in [AppPalette.light, AppPalette.dark]) {
    final theme = palette.isLight ? 'light' : 'dark';
    testWidgets('profile at 320 dp x1.3 $theme: medical section, limits, receive-texts switch', (tester) async {
      await render(tester, palette: palette);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Medical info (optional)'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Shown to your ride group only while your SOS or crash alert is open.'), findsOneWidget);
      // Limits: the fields stop at 120 and 200 characters.
      await tester.scrollUntilVisible(find.byKey(const ValueKey('allergies')), 200, scrollable: find.byType(Scrollable).first);
      await tester.enterText(find.byKey(const ValueKey('allergies')), 'a' * 150);
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const ValueKey('allergies'))).controller!.text.length, 120);

      await tester.scrollUntilVisible(find.byKey(const ValueKey('medicalNotes')), 200, scrollable: find.byType(Scrollable).first);
      // 3.16: the label reads "Notes for a doctor" and the safety card can be opened from here.
      expect(find.text('Notes for a doctor'), findsOneWidget);
      expect(find.text('Notes for helpers'), findsNothing);
      expect(find.byKey(const ValueKey('safetyCard')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('medicalNotes')), 'b' * 250);
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const ValueKey('medicalNotes'))).controller!.text.length, 200);

      await tester.scrollUntilVisible(find.text('Receive emergency texts from my ride group'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('A rider with no internet can text you where they are. When off, your number is not used for these texts.'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('smsReceive'))).value, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('save sends blood group, allergies and the opt-out to PATCH /me', (tester) async {
    final (auth, calls) = await render(tester, palette: AppPalette.dark, scale: 1.0);
    final list = find.byType(Scrollable).first;
    Future<void> fill(String label, String text) async {
      final f = find.widgetWithText(TextField, label);
      await tester.scrollUntilVisible(f, 100, scrollable: list);
      await tester.enterText(f, text);
    }

    // About you, bike and emergency contact (required).
    await fill('Name', 'Asha');
    await fill('Mobile number', '9876543210');
    await fill('Registration number', 'KA01AB1234');
    await fill('Contact name', 'Ravi');
    await fill('Contact phone', '9123456780');
    await tester.pump();

    await tester.scrollUntilVisible(find.byKey(const ValueKey('bloodGroup')), 200, scrollable: list);
    await tester.tap(find.byKey(const ValueKey('bloodGroup')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('O+').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('allergies')), 'penicillin');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('smsReceive')), 200, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -100));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('smsReceive')));
    await tester.pump();

    await tester.scrollUntilVisible(find.text('Save'), 200, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -100));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final patch = calls.where((r) => r.method == 'PATCH').toList();
    expect(patch, hasLength(1));
    final body = jsonDecode(patch.single.body) as Map<String, dynamic>;
    expect(body['bloodGroup'], 'O+');
    expect(body['allergies'], 'penicillin');
    expect(body['smsOptOut'], isTrue);
    // Not loaded from a 3.14 server and not touched: left out, so it is never cleared by mistake.
    expect(body.containsKey('medicalNotes'), isFalse);
    // The answer carries the fields back: memory only, never in SharedPreferences.
    expect(auth.bloodGroup, 'O+');
    expect(auth.smsOptOut, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().any((k) => prefs.get(k).toString().contains('penicillin')), isFalse);
    await tester.pump(const Duration(seconds: 5)); // snackbar
  });
}
