import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/l10n/l10n.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/ui/ui.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/medical_info.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/account/profile_form.dart';
import 'package:coroute_app/presentation/ride/incident_sheet.dart';
import 'package:coroute_app/presentation/safety/safety_card_sheet.dart';

class _Convoys extends ConvoyService {
  _Convoys(ApiClient api, this.convoy) : super(api, RealtimeService(), TripStorageService(api));
  final ConvoyModel convoy;
  @override
  Map<String, ConvoyModel> get allConvoys => {convoy.groupId: convoy};
  @override
  ConvoyModel? get activeConvoy => convoy;
  @override
  String? get myUserId => 'u_me';
  @override
  bool supports(String feature) => feature == ProtocolFeatures.respond;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() {
    L10n.setLanguage(AppLanguage.system);
    AppTheme.use(AppPalette.dark);
  });

  Future<void> render(WidgetTester tester, Widget child, {List<SingleChildWidget> providers = const [], AppPalette palette = AppPalette.dark}) async {
    AppTheme.use(palette);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = MaterialApp(
      theme: AppTheme.themeFor(palette),
      builder: (context, w) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
        child: w ?? const SizedBox.shrink(),
      ),
      home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(12), child: child)),
    );
    await tester.pumpWidget(providers.isEmpty ? app : MultiProvider(providers: providers, child: app));
    await tester.pump();
  }

  test('contactText', () {
    expect(SafetyCardSheet.contactText('Priya', '+91 91234 56780'), 'Priya, +91 91234 56780');
    expect(SafetyCardSheet.contactText('', '+91 91234 56780'), '+91 91234 56780');
    expect(SafetyCardSheet.contactText('Priya', ''), 'Priya');
    expect(SafetyCardSheet.contactText('', ''), '');
  });

  for (final palette in [AppPalette.light, AppPalette.dark]) {
    testWidgets('card at 320 dp x1.3 (${palette.isLight ? 'light' : 'dark'}): four rows in large text, blanks say Not given, Call only for others', (tester) async {
      await render(
        tester,
        const SafetyCardSheet(
          name: 'Kiran Rao',
          medical: MedicalInfo(bloodGroup: 'O+', allergies: 'penicillin'),
          contactName: 'Priya',
          contactPhone: '+91 91234 56780',
        ),
        palette: palette,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Safety card'), findsOneWidget);
      expect(find.text('Kiran Rao'), findsOneWidget);
      for (final label in ['Blood group', 'Allergies', 'Notes for a doctor', 'Emergency contact']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('O+'), findsOneWidget);
      expect(find.text('penicillin'), findsOneWidget);
      expect(find.text('Not given'), findsOneWidget, reason: 'the notes');
      expect(find.text('Priya, +91 91234 56780'), findsOneWidget);
      // Large text: the blood group uses the metric size, the values the title size.
      expect(tester.widget<Text>(find.text('O+')).style!.fontSize, AppText.metric.fontSize);
      expect(tester.widget<Text>(find.text('penicillin')).style!.fontSize, AppText.title.fontSize);
      expect(find.text('Call Priya'), findsOneWidget);
      expect(find.textContaining('only while your SOS or crash alert is open'), findsOneWidget);
    });
  }

  testWidgets('my own card: no Call button; every blank says Not given', (tester) async {
    await render(tester, const SafetyCardSheet(name: 'Me', mine: true, contactPhone: '+91 91234 56780'));
    expect(find.textContaining('Call'), findsNothing);
    expect(find.text('Not given'), findsNWidgets(3));
    expect(find.text('+91 91234 56780'), findsOneWidget);
  });

  testWidgets('reads in Telugu', (tester) async {
    L10n.setLanguage(AppLanguage.te);
    await render(tester, const SafetyCardSheet(name: 'Kiran', medical: MedicalInfo(bloodGroup: 'B+')));
    expect(tester.takeException(), isNull);
    expect(find.text(L10n.t('card.title', const {}, 'te')), findsOneWidget);
    expect(find.text(L10n.t('card.blood', const {}, 'te')), findsOneWidget);
    expect(find.text(L10n.t('card.none', const {}, 'te')), findsNWidgets(3));
    expect(find.text('B+'), findsOneWidget, reason: 'values are never translated');
    expect(find.text('Safety card'), findsNothing);
  });

  testWidgets('from the profile: "Show my safety card" opens my card with the typed values', (tester) async {
    final api = ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: const FlutterSecureStorage());
    final auth = AuthService(api);
    await render(tester, const SizedBox(height: 600, child: ProfileForm()), providers: [ChangeNotifierProvider<AuthService>.value(value: auth)]);
    final list = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('allergies')), 200, scrollable: list);
    await tester.enterText(find.byKey(const ValueKey('allergies')), 'dust');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('safetyCard')), 200, scrollable: list);
    expect(find.text(ProfileForm.safetyCardLabel), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('safetyCard')));
    await tester.pumpAndSettle();
    expect(find.text('Safety card'), findsOneWidget);
    expect(find.text('dust'), findsOneWidget);
    expect(find.textContaining('Call'), findsNothing, reason: 'my own card');
  });

  testWidgets('from the incident sheet: "Safety card" shows while the alert carries medical info, with Call for the contact', (tester) async {
    const now = 1800000000000;
    final convoy = ConvoyModel.fromJson({
      'groupId': 'G1',
      'name': 'Hill run',
      'joinCode': '123456',
      'createdByUserId': 'u_lead',
      'tripStatus': 'STARTED',
      'riders': {
        'u_me': {'userId': 'u_me', 'name': 'Me', 'lat': 12.9716, 'lng': 77.5946, 'lastSeenEpochMs': now},
        'u_k': {
          'userId': 'u_k',
          'name': 'Kiran',
          'lat': 12.983,
          'lng': 77.606,
          'lastSeenEpochMs': now,
          'emergencyContact': '+91 91234 56780',
          'emergencyContactName': 'Priya',
        },
      },
      'activeAlerts': [
        {
          'alertId': 'A1',
          'userId': 'u_k',
          'userName': 'Kiran',
          'lat': 12.983,
          'lng': 77.606,
          'alertType': 'CRASH',
          'timestamp': now - 60000,
          'auto': true,
          'medical': {'bloodGroup': 'AB-', 'allergies': 'nuts'},
        },
      ],
    });
    final api = ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: const FlutterSecureStorage());
    final c = _Convoys(api, convoy);
    await render(
      tester,
      const IncidentSheetBody(convoyId: 'G1', subjectUserId: 'u_k', alertId: 'A1', nowMs: now),
      providers: [ChangeNotifierProvider<ConvoyService>.value(value: c)],
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Safety card'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Safety card'));
    await tester.pumpAndSettle();
    expect(find.text('AB-'), findsOneWidget);
    expect(find.text('nuts'), findsOneWidget);
    expect(find.text('Priya, +91 91234 56780'), findsOneWidget);
    expect(find.text('Call Priya'), findsOneWidget);
  });
}
