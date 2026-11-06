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
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/ride/incident_view.dart';
import 'package:coroute_app/presentation/ride/meet_here_sheet.dart';
import 'package:coroute_app/presentation/ride/report_down_sheet.dart';

/// ConvoyService with a fixed convoy that records rider-down reports (no socket).
class _Convoys extends ConvoyService {
  _Convoys(ApiClient api, {this.net = true}) : super(api, RealtimeService(), TripStorageService(api));

  final bool net;
  final List<(double, double, String?)> reports = [];

  @override
  ConvoyModel? get activeConvoy => ConvoyModel.fromJson({
        'groupId': 'G1',
        'name': 'Hill run',
        'joinCode': '123456',
        'createdByUserId': 'u_lead',
        'tripStatus': 'STARTED',
        'riders': {
          'u_me': {'userId': 'u_me', 'name': 'Me', 'lat': 17.40, 'lng': 78.0, 'lastSeenEpochMs': 1},
          'u_k': {'userId': 'u_k', 'name': 'Kiran', 'lat': 17.41, 'lng': 78.0, 'lastSeenEpochMs': 1},
          'u_a': {'userId': 'u_a', 'name': 'Arjun', 'lat': 17.42, 'lng': 78.0, 'lastSeenEpochMs': 1},
        },
      });
  @override
  Map<String, ConvoyModel> get allConvoys => {'G1': activeConvoy!};
  @override
  String? get myUserId => 'u_me';
  @override
  bool supports(String feature) => feature == ProtocolFeatures.safetyNet ? net : true;
  @override
  bool reportRiderDown({required double lat, required double lng, String? subjectUserId}) {
    if (!net) return false;
    reports.add((lat, lng, subjectUserId));
    return true;
  }
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

  _Convoys fake({bool net = true}) =>
      _Convoys(ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: const FlutterSecureStorage()), net: net);

  Future<void> render(WidgetTester tester, Widget child, {required _Convoys convoys, AppPalette palette = AppPalette.dark}) async {
    AppTheme.use(palette);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<ConvoyService>.value(
      value: convoys,
      child: MaterialApp(
        theme: AppTheme.themeFor(palette),
        builder: (context, w) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: w ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(12), child: child)),
      ),
    ));
    await tester.pump();
  }

  group('long-press sheet', () {
    testWidgets('lead keeps Meet here and Add a stop, plus Report a rider down here', (tester) async {
      MeetHereResult? result;
      await render(
        tester,
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async => result = await showMeetHereSheet(context, placeName: () async => 'Shamirpet', distanceFromMeM: 800, lead: true),
            child: const Text('open'),
          ),
        ),
        convoys: fake(),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Meet here'), findsOneWidget);
      expect(find.text('Add a stop here'), findsOneWidget);
      expect(find.text(MeetHereSheet.suggestLabel), findsNothing);
      expect(find.text('Report a rider down here'), findsOneWidget);
      expect(find.text('Shamirpet'), findsOneWidget);
      await tester.ensureVisible(find.text('Report a rider down here'));
      await tester.tap(find.text('Report a rider down here'));
      await tester.pumpAndSettle();
      expect(result?.action, MeetHereAction.reportDown);
      expect(result?.name, 'Shamirpet');
    });

    testWidgets('a pack rider gets Suggest a stop here and the report row; never Meet here', (tester) async {
      MeetHereResult? result;
      await render(
        tester,
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async => result = await showMeetHereSheet(context, placeName: () async => null, lead: false),
            child: const Text('open'),
          ),
        ),
        convoys: fake(),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Meet here'), findsNothing);
      expect(find.text('Add a stop here'), findsNothing);
      expect(find.text(MeetHereSheet.suggestLabel), findsOneWidget);
      expect(find.text('Report a rider down here'), findsOneWidget);
      await tester.tap(find.text(MeetHereSheet.suggestLabel));
      await tester.pumpAndSettle();
      expect(result?.action, MeetHereAction.addStop);
    });

    testWidgets('without the safety network (no net1) the report row is hidden', (tester) async {
      await render(
        tester,
        Builder(
          builder: (context) => FilledButton(
            onPressed: () => showMeetHereSheet(context, placeName: () async => null, lead: false, canReport: false),
            child: const Text('open'),
          ),
        ),
        convoys: fake(net: false),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(MeetHereSheet.suggestLabel), findsOneWidget);
      expect(find.text('Report a rider down here'), findsNothing);
    });
  });

  group('report sheet', () {
    testWidgets('sends the point without a subject by default ("Someone not in my group")', (tester) async {
      final c = fake();
      bool? sent;
      await render(
        tester,
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async => sent = await showReportDownSheet(context, lat: 17.4144, lng: 78.0, placeName: 'Near Shamirpet'),
            child: const Text('open'),
          ),
        ),
        convoys: c,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Report a rider down here'), findsOneWidget);
      expect(find.text('Near Shamirpet'), findsOneWidget);
      expect(find.textContaining('Call 112'), findsOneWidget);
      expect(find.text('Someone not in my group'), findsOneWidget);
      expect(find.text('Kiran'), findsOneWidget);
      expect(find.text('Arjun'), findsOneWidget);
      expect(find.text('Me'), findsNothing, reason: 'never myself');
      await tester.ensureVisible(find.text('Report rider down'));
      await tester.tap(find.text('Report rider down'));
      await tester.pumpAndSettle();
      expect(sent, isTrue);
      expect(c.reports, [(17.4144, 78.0, null)]);
    });

    testWidgets('a chosen rider is sent as the subject; Cancel sends nothing', (tester) async {
      final c = fake();
      bool? sent;
      await render(
        tester,
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async => sent = await showReportDownSheet(context, lat: 17.4144, lng: 78.0),
            child: const Text('open'),
          ),
        ),
        convoys: c,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kiran'));
      await tester.pump();
      await tester.ensureVisible(find.text('Report rider down'));
      await tester.tap(find.text('Report rider down'));
      await tester.pumpAndSettle();
      expect(sent, isTrue);
      expect(c.reports.single.$3, 'u_k');

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sent, isNull);
      expect(c.reports, hasLength(1));
    });

    testWidgets('reads in Hindi when the language is Hindi', (tester) async {
      L10n.setLanguage(AppLanguage.hi);
      await render(tester, const ReportDownSheet(lat: 17.4, lng: 78.0), convoys: fake());
      expect(tester.takeException(), isNull);
      expect(find.text(L10n.t('report.title', const {}, 'hi')), findsOneWidget);
      expect(find.text(L10n.t('report.send', const {}, 'hi')), findsOneWidget);
      expect(find.text('Report a rider down here'), findsNothing);
    });
  });

  group('report wording (item 1)', () {
    const now = 1800000000000;
    ConvoyModel convoy(Map<String, dynamic> alert) => ConvoyModel.fromJson({
          'groupId': 'G1',
          'name': 'Hill run',
          'joinCode': '123456',
          'createdByUserId': 'u_lead',
          'tripStatus': 'STARTED',
          'riders': {
            'u_me': {'userId': 'u_me', 'name': 'Me', 'lat': 17.40, 'lng': 78.0, 'lastSeenEpochMs': now},
            'u_a': {'userId': 'u_a', 'name': 'Arjun Rao', 'lat': 17.41, 'lng': 78.0, 'lastSeenEpochMs': now},
            'u_k': {'userId': 'u_k', 'name': 'Kiran', 'lat': 17.42, 'lng': 78.0, 'lastSeenEpochMs': now},
          },
          'activeAlerts': [alert],
        });

    test('a report about a group member never says "accident": "Arjun reported Kiran down"', () {
      final c = convoy({
        'alertId': 'A1',
        'userId': 'u_k',
        'userName': 'Kiran',
        'lat': 17.42,
        'lng': 78.0,
        'alertType': 'RIDER_DOWN',
        'timestamp': now - 60000,
        'source': 'MEMBER_REPORT',
        'reportedBy': 'u_a',
        'reportedByName': 'Arjun Rao',
      });
      final i = incidentsFromEvents(c, const [], 'u_me', now).single;
      expect(i.isReport, isTrue);
      expect(i.summary, 'Arjun reported Kiran down');
      expect(i.summary.toLowerCase(), isNot(contains('accident')));
      expect(i.title, 'Rider down: Kiran');
      expect(i.what, 'Reported by Arjun');
    });

    test('a report about someone outside the group: "Arjun reported a rider down"', () {
      final c = convoy({
        'alertId': 'A2',
        'userId': 'u_a',
        'userName': 'Arjun Rao',
        'lat': 17.42,
        'lng': 78.0,
        'alertType': 'RIDER_DOWN',
        'timestamp': now - 60000,
        'source': 'NEARBY_REPORT',
        'reportedBy': 'u_a',
        'reportedByName': 'Arjun Rao',
      });
      final i = incidentsFromEvents(c, const [], 'u_me', now).single;
      expect(i.summary, 'Arjun reported a rider down');
      expect(i.summary, isNot(contains('accident')));
      expect(i.title, 'Rider down reported');
    });

    test('a crash still says "may have met with an accident"', () {
      final c = convoy({
        'alertId': 'A3',
        'userId': 'u_k',
        'userName': 'Kiran',
        'lat': 17.42,
        'lng': 78.0,
        'alertType': 'CRASH',
        'timestamp': now - 60000,
        'auto': true,
      });
      expect(incidentsFromEvents(c, const [], 'u_me', now).single.summary, 'Kiran may have met with an accident');
    });
  });
}
