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
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/admin/admin_emergencies_panel.dart';

/// Counts alarm starts and stops instead of making a sound.
class FakeAlarm implements AdminAlarm {
  int starts = 0;
  int stops = 0;
  String? lastTitle;

  @override
  Future<void> start({required String title, required String body}) async {
    starts++;
    lastTitle = title;
  }

  @override
  Future<void> stop() async => stops++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AdminEmergenciesPanelState.resetAcknowledged();
  });
  tearDown(() => AppTheme.use(AppPalette.dark));

  final now = DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> crash({String id = 'A1', String name = 'Kiran'}) => {
        'groupId': 'GRP-1',
        'convoyName': 'Sunday ride',
        'alertId': id,
        'alertType': 'CRASH',
        'auto': true,
        'userId': 'u_$id',
        'userName': name,
        'lat': 16.07,
        'lng': 78.85,
        'startedAt': now - 4 * 60000,
        'occurredAt': now - 4 * 60000,
        'presence': 'NO_SIGNAL',
        'lastSeenAt': now - 3 * 60000,
        'riders': 6,
        'lead': {'userId': 'u1', 'name': 'Venkata'},
        'responders': [
          {'userId': 'u2', 'name': 'Arjun', 'kind': 'GOING', 'at': now - 60000},
        ],
        // A gateway must never send this to admins; the panel ignores it even if it did.
        'medical': {'bloodGroup': 'O+', 'allergies': 'penicillin'},
      };

  test('AdminEmergency.fromJson and merge with the fleet', () {
    final e = AdminEmergency.fromJson(crash());
    expect(e.isCrash, isTrue);
    expect(e.title, 'Crash: Kiran');
    expect(e.kindText, 'Automatic crash alert');
    expect(e.presenceText, 'No signal');
    expect(e.leadName, 'Venkata');
    expect(e.responders.single.name, 'Arjun');

    // The fleet knows GRP-1 and the alert is no longer open there: it was resolved.
    final fleet = ConvoyModel.fromJson({'groupId': 'GRP-1', 'name': 'Sunday ride', 'riders': {}, 'activeAlerts': []});
    expect(mergeEmergencies([e], [fleet]), isEmpty);
    // Unknown ride in the fleet: keep the REST entry.
    expect(mergeEmergencies([e], const []), hasLength(1));
    // Only the fleet knows an SOS: it is added.
    final live = ConvoyModel.fromJson({
      'groupId': 'GRP-2',
      'name': 'Coast run',
      'riders': {},
      'activeAlerts': [
        {'alertId': 'B1', 'userId': 'u9', 'userName': 'Asha', 'alertType': 'MECHANICAL', 'timestamp': now},
      ],
    });
    final merged = mergeEmergencies([e], [live]);
    expect(merged.map((x) => x.alertId), ['B1', 'A1'], reason: 'newest first');
    expect(merged.first.title, 'SOS: Asha needs help');
  });

  Future<(FakeAlarm, List<Map<String, dynamic>>)> render(WidgetTester tester, {AppPalette palette = AppPalette.dark, double scale = 1.3}) async {
    AppTheme.use(palette);
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final served = <Map<String, dynamic>>[crash()];
    final api = ApiClient(
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/admin/emergencies')) {
          return http.Response(jsonEncode({'serverTime': now, 'emergencies': served}), 200);
        }
        return http.Response('{}', 200);
      }),
      storage: const FlutterSecureStorage(),
    );
    final convoys = ConvoyService(api, RealtimeService(), TripStorageService(api));
    final alarm = FakeAlarm();
    await tester.pumpWidget(ChangeNotifierProvider<ConvoyService>.value(
      value: convoys,
      child: ChangeNotifierProvider<ApiClient>.value(
        value: api,
        child: MaterialApp(
          theme: AppTheme.themeFor(palette),
          builder: (context, w) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: w ?? const SizedBox.shrink(),
          ),
          home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: AdminEmergenciesPanel(alarm: alarm))),
        ),
      ),
    ));
    await tester.pump(); // post-frame: load starts
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(); // post-frame: alarm sync
    return (alarm, served);
  }

  for (final palette in [AppPalette.light, AppPalette.dark]) {
    final theme = palette.isLight ? 'light' : 'dark';
    testWidgets('list at 320 dp x1.3 $theme: who, kind, ride, presence, responders; no medical', (tester) async {
      await render(tester, palette: palette);
      expect(tester.takeException(), isNull);
      expect(find.text('Emergencies (1)'), findsOneWidget);
      expect(find.text('Crash: Kiran'), findsOneWidget);
      expect(find.textContaining('Automatic crash alert, open 4 min'), findsOneWidget);
      expect(find.textContaining('Sunday ride, lead Venkata, 6 riders'), findsOneWidget);
      expect(find.textContaining('No signal, last seen 3 min ago'), findsOneWidget);
      expect(find.text('Helping: Arjun on the way'), findsOneWidget);
      expect(find.text('Open map'), findsOneWidget);
      expect(find.textContaining('O+'), findsNothing);
      expect(find.textContaining('penicillin'), findsNothing);
    });
  }

  testWidgets('alarm starts once per new emergency, Silence stops it, a later one rings again', (tester) async {
    final (alarm, served) = await render(tester, scale: 1.0);
    expect(alarm.starts, 1);
    expect(alarm.lastTitle, 'Crash: Kiran');

    // The same list again: no second start.
    final state = tester.state<AdminEmergenciesPanelState>(find.byType(AdminEmergenciesPanel));
    await state.reload();
    await tester.pump();
    await tester.pump();
    expect(alarm.starts, 1);

    // A new emergency arrives: one more start.
    served.add(crash(id: 'A2', name: 'Bala'));
    await state.reload();
    await tester.pump();
    await tester.pump();
    expect(alarm.starts, 2);

    await tester.tap(find.text('Silence alarm'));
    await tester.pump();
    expect(alarm.stops, 1);
    expect(find.text('Silence alarm'), findsNothing);
    expect(find.text('Alarm silenced'), findsNWidgets(2));

    served.add(crash(id: 'A3', name: 'Chitra'));
    await state.reload();
    await tester.pump();
    await tester.pump();
    expect(alarm.starts, 3);
  });

  testWidgets('closing the panel stops a ringing alarm; nothing open stops it too', (tester) async {
    final (alarm, served) = await render(tester, scale: 1.0);
    expect(alarm.starts, 1);
    served.clear();
    final state = tester.state<AdminEmergenciesPanelState>(find.byType(AdminEmergenciesPanel));
    await state.reload();
    await tester.pump();
    await tester.pump();
    expect(alarm.stops, 1, reason: 'no open emergency left');
    expect(find.text('No open SOS or crash alerts'), findsOneWidget);

    served.add(crash(id: 'A9'));
    await state.reload();
    await tester.pump();
    await tester.pump();
    expect(alarm.starts, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(alarm.stops, 2, reason: 'disposed while ringing');
  });
}
