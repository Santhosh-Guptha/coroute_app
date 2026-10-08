import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/outbox_item.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/ride/incident_banner.dart';
import 'package:coroute_app/presentation/ride/incident_sheet.dart';
import 'package:coroute_app/presentation/ride/incident_view.dart';
import 'package:coroute_app/presentation/ride/navigate_to.dart';

/// ConvoyService with a fixed convoy and recorded safety calls (no socket).
class FakeConvoys extends ConvoyService {
  FakeConvoys(ApiClient api, this.convoy, {this.me = 'u_me', Set<String>? features})
      : features = features ?? {ProtocolFeatures.respond, ProtocolFeatures.checkIn},
        super(api, RealtimeService(), TripStorageService(api));

  ConvoyModel convoy;
  final String me;
  final Set<String> features;
  final List<(String, SosResponseKind)> responses = [];
  final List<CheckInResult> checkIns = [];
  final List<String> resolved = [];
  SosResponseKind? current;

  @override
  Map<String, ConvoyModel> get allConvoys => {convoy.groupId: convoy};
  @override
  ConvoyModel? get activeConvoy => convoy;
  @override
  String? get activeGroupId => convoy.groupId;
  @override
  String? get myUserId => me;
  @override
  bool supports(String feature) => features.contains(feature);
  @override
  bool respondToSos(String alertId, SosResponseKind kind) {
    responses.add((alertId, kind));
    current = kind == SosResponseKind.cancel ? null : kind;
    notifyListeners();
    return true;
  }

  @override
  SosResponseKind? myResponseTo(String alertId) => current;
  @override
  List<OutboxItem> get outbox => const [];
  @override
  bool sendCheckIn(CheckInResult result, {double? awayM}) {
    checkIns.add(result);
    return true;
  }

  @override
  void resolveSosAlert(String alertId) => resolved.add(alertId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    navigateLauncherOverride = null;
  });
  tearDown(() {
    AppTheme.use(AppPalette.dark);
    navigateLauncherOverride = null;
  });

  const now = 1800000000000;
  // Kiran is about 1.8 km north-east of me.
  const myLat = 12.9716, myLng = 77.5946;
  const kLat = 12.983034, kLng = 77.606333;

  Map<String, dynamic> rider(String id, String name, {double lat = myLat, double lng = myLng, String role = 'PACK', String phone = ''}) => {
        'userId': id,
        'name': name,
        'lat': lat,
        'lng': lng,
        'role': role,
        'phone': phone,
        'emergencyContact': id == 'u_k' ? '+91 91234 56780' : '',
        'lastSeenEpochMs': now - 300000,
      };

  ConvoyModel convoy({List<Map<String, dynamic>> alerts = const [], String creator = 'u_lead'}) => ConvoyModel.fromJson({
        'groupId': 'G1',
        'name': 'Hill run',
        'joinCode': '123456',
        'createdByUserId': creator,
        'tripStatus': 'STARTED',
        'riders': {
          'u_me': rider('u_me', 'Me'),
          'u_lead': rider('u_lead', 'Lead', role: 'LEAD'),
          'u_k': rider('u_k', 'Kiran', lat: kLat, lng: kLng, phone: '+91 98765 43210'),
          'u_a': rider('u_a', 'Arjun'),
        },
        'activeAlerts': alerts,
      });

  Map<String, dynamic> crash({bool resolved = false, List<Map<String, dynamic>> responders = const [], Map<String, dynamic>? medical, String user = 'u_k'}) => {
        'alertId': 'A1',
        'userId': user,
        'userName': user == 'u_k' ? 'Kiran' : 'Me',
        'lat': kLat,
        'lng': kLng,
        'alertType': 'CRASH',
        'timestamp': now - 180000,
        'occurredAt': now - 180000,
        'auto': true,
        'speedBeforeKmh': 55.0,
        'resolved': resolved,
        'responders': responders,
        'medical': ?medical,
      };

  group('incidentsFor (pure)', () {
    test('open crash first, key and words; resolved alerts are not incidents', () {
      final c = convoy(alerts: [crash()]);
      final list = incidentsFromEvents(c, const [], 'u_me', now);
      expect(list, hasLength(1));
      final i = list.single;
      expect(i.kind, IncidentKind.crash);
      expect(i.key, 'SOS:A1');
      expect(i.title, 'Crash detected: Kiran');
      expect(i.what, 'Automatic crash alert');
      expect(i.isMe, isFalse);
      expect(incidentsFromEvents(convoy(alerts: [crash(resolved: true)]), const [], 'u_me', now), isEmpty);
    });

    test('possible incident: the riders asked, the lead and the rider; not everyone', () {
      final c = convoy();
      final e = TimelineEventModel(
        eventId: 'e1',
        groupId: 'G1',
        userId: 'u_k',
        userName: 'Kiran',
        type: SafetyEventTypes.possibleIncident,
        startedAt: now - 60000,
        open: true,
        data: const {'fromKmh': 62, 'notify': ['u_a'], 'auto': true},
      );
      expect(incidentsFromEvents(c, [e], 'u_a', now).single.kind, IncidentKind.possibleIncident);
      expect(incidentsFromEvents(c, [e], 'u_lead', now).single.what, contains('62 km/h'));
      expect(incidentsFromEvents(c, [e], 'u_me', now), isEmpty, reason: 'not asked, not the lead');
      final self = incidentsFromEvents(c, [e], 'u_k', now).single;
      expect(self.isMe, isTrue);
      expect(self.title, 'Your group was asked to check on you');
    });

    test('no signal only when escalated, never for a closed app, lead only', () {
      final c = convoy();
      TimelineEventModel off(Map<String, dynamic> data) =>
          TimelineEventModel(eventId: 'o1', groupId: 'G1', userId: 'u_k', userName: 'Kiran', type: 'OFFLINE', startedAt: now - 700000, open: true, data: data);
      expect(incidentsFromEvents(c, [off({'escalated': true, 'cause': 'NO_SIGNAL', 'lastKmh': 62})], 'u_lead', now).single.kind, IncidentKind.noSignal);
      expect(incidentsFromEvents(c, [off({'escalated': true, 'cause': 'NO_SIGNAL'})], 'u_me', now), isEmpty);
      expect(incidentsFromEvents(c, [off({'escalated': true, 'cause': 'APP_CLOSED'})], 'u_lead', now), isEmpty);
      expect(incidentsFromEvents(c, [off({'cause': 'NO_SIGNAL'})], 'u_lead', now), isEmpty);
    });
  });

  Future<FakeConvoys> render(
    WidgetTester tester,
    Widget child, {
    required ConvoyModel c,
    String me = 'u_me',
    Set<String>? features,
    Size size = const Size(320, 640),
    double scale = 1.3,
    AppPalette palette = AppPalette.dark,
  }) async {
    AppTheme.use(palette);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: const FlutterSecureStorage());
    final fake = FakeConvoys(api, c, me: me, features: features);
    await tester.pumpWidget(ChangeNotifierProvider<ConvoyService>.value(
      value: fake,
      child: MaterialApp(
        theme: AppTheme.themeFor(palette),
        builder: (context, w) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: w ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child)),
      ),
    ));
    await tester.pump();
    return fake;
  }

  testWidgets('banner: who, what, "1.8 km north-east of you", time since', (tester) async {
    final i = incidentsFromEvents(convoy(alerts: [crash()]), const [], 'u_me', now).single;
    await render(tester, IncidentBanner(incident: i, myLat: myLat, myLng: myLng, nowMs: now, onOpen: () {}), c: convoy(alerts: [crash()]));
    expect(tester.takeException(), isNull);
    expect(find.text('Crash detected: Kiran'), findsOneWidget);
    expect(find.text('Automatic crash alert, 3 min ago'), findsOneWidget);
    expect(find.text('1.8 km north-east of you'), findsOneWidget);
    expect(find.text('Navigate'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('Navigate tries google.navigation first, then geo:, then the browser', (tester) async {
    final tried = <Uri>[];
    navigateLauncherOverride = (u) async {
      tried.add(u);
      return false;
    };
    final i = incidentsFromEvents(convoy(alerts: [crash()]), const [], 'u_me', now).single;
    var opened = 0;
    await render(tester, IncidentBanner(incident: i, myLat: myLat, myLng: myLng, nowMs: now, onOpen: () => opened++), c: convoy(alerts: [crash()]));
    await tester.tap(find.text('Navigate'));
    await tester.pump();
    expect(tried, hasLength(3));
    expect(tried.first.toString(), 'google.navigation:q=12.983034,77.606333&mode=d');
    expect(tried[1].scheme, 'geo');
    expect(tried[2].host, 'www.google.com');
    expect(opened, 0, reason: 'Navigate does not open the sheet');
    await tester.tap(find.text('Open'));
    expect(opened, 1);
  });

  for (final palette in [AppPalette.light, AppPalette.dark]) {
    final theme = palette.isLight ? 'light' : 'dark';
    testWidgets('sheet at 320 dp x1.3 $theme: I\'m going / I\'m with them call respondToSos, undo cancels', (tester) async {
      final c = convoy(alerts: [crash()]);
      final fake = await render(tester, IncidentSheetBody(convoyId: 'G1', subjectUserId: 'u_k', alertId: 'A1', nowMs: now), c: c, palette: palette);
      expect(tester.takeException(), isNull);
      expect(find.text('Crash detected: Kiran'), findsOneWidget);
      await tester.ensureVisible(find.text("I'm going"));
      await tester.tap(find.text("I'm going"));
      await tester.pump();
      expect(fake.responses.last, ('A1', SosResponseKind.going));
      expect(find.text('You said you are on the way.'), findsOneWidget);
      await tester.ensureVisible(find.text('Undo'));
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(fake.responses.last, ('A1', SosResponseKind.cancel));
      await tester.ensureVisible(find.text("I'm with them"));
      await tester.tap(find.text("I'm with them"));
      await tester.pump();
      expect(fake.responses.last, ('A1', SosResponseKind.withThem));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('answer buttons hidden for my own alert and without the gateway feature', (tester) async {
    await render(tester, const IncidentSheetBody(convoyId: 'G1', subjectUserId: 'u_k', alertId: 'A1', nowMs: now), c: convoy(alerts: [crash()]), features: const {});
    expect(find.text("I'm going"), findsNothing);
    expect(find.text('Navigate'), findsOneWidget);

    await render(tester, const IncidentSheetBody(convoyId: 'G1', subjectUserId: 'u_me', alertId: 'A1', nowMs: now), c: convoy(alerts: [crash(user: 'u_me')]));
    expect(find.text("I'm going"), findsNothing);
    expect(find.text('Your SOS is on'), findsOneWidget);
    expect(find.text('I am safe'), findsOneWidget);
  });

  testWidgets('responders list and medical info while the alert is open; closed alert shows neither', (tester) async {
    final open = crash(
      responders: [
        {'userId': 'u_a', 'name': 'Arjun', 'kind': 'GOING', 'at': now - 120000},
      ],
      medical: {'bloodGroup': 'O+', 'allergies': 'penicillin', 'notes': ''},
    );
    await render(tester, const IncidentSheetBody(convoyId: 'G1', subjectUserId: 'u_k', alertId: 'A1', nowMs: now), c: convoy(alerts: [open]), size: const Size(360, 1400), scale: 1.0);
    expect(find.text('Arjun, on the way, 2 min ago'), findsOneWidget);
    expect(find.text('Who is helping (1)'), findsOneWidget);
    expect(find.text('Blood group O+'), findsOneWidget);
    expect(find.text('Allergies: penicillin'), findsOneWidget);
    expect(find.textContaining('Notes'), findsNothing);

    final closed = Map<String, dynamic>.from(open)..['resolved'] = true;
    await render(tester, const IncidentSheetBody(convoyId: 'G1', subjectUserId: 'u_k', alertId: 'A1', nowMs: now), c: convoy(alerts: [closed]), size: const Size(360, 1400), scale: 1.0);
    expect(find.text('This alert is closed'), findsOneWidget);
    expect(find.text('Blood group O+'), findsNothing);
    expect(find.textContaining('Arjun'), findsNothing);
  });

  testWidgets('the lead sees who is helping before the answer buttons', (tester) async {
    final open = crash(responders: [
      {'userId': 'u_a', 'name': 'Arjun', 'kind': 'WITH_THEM', 'at': now - 60000},
    ]);
    await render(tester, const IncidentSheetBody(convoyId: 'G1', subjectUserId: 'u_k', alertId: 'A1', nowMs: now),
        c: convoy(alerts: [open]), me: 'u_lead', size: const Size(360, 1400), scale: 1.0);
    final helping = tester.getTopLeft(find.text('Who is helping (1)')).dy;
    final buttons = tester.getTopLeft(find.text("I'm going")).dy;
    expect(helping, lessThan(buttons));
    expect(find.text('Arjun, with them, 1 min ago'), findsOneWidget);
  });

  test('a possible incident about me: own key and words; queued words', () {
    final c = convoy();
    final e = TimelineEventModel(
      eventId: 'e1',
      groupId: 'G1',
      userId: 'u_me',
      userName: 'Me',
      type: SafetyEventTypes.possibleIncident,
      startedAt: now - 60000,
      open: true,
      data: const {'fromKmh': 50},
    );
    final self = incidentsFromEvents(c, [e], 'u_me', now).single;
    expect(self.isMe, isTrue);
    expect(self.key, 'INCIDENT:u_me');
    expect(self.title, 'Your group was asked to check on you');
    expect(QueuedLine.textFor(), 'Waiting for signal');
    expect(QueuedLine.textFor(failed: true, what: 'Your stop reason'), 'Your stop reason, not sent');
  });
}
