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
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/presentation/ride/rider_card_sheet.dart';
import 'package:coroute_app/presentation/ride/riders_ladder.dart';

/// A ConvoyService that only serves one convoy (no socket, no GPS).
class _OneConvoy extends ConvoyService {
  _OneConvoy(ApiClient api, this.convoy) : super(api, RealtimeService(), TripStorageService(api));
  final ConvoyModel convoy;

  @override
  Map<String, ConvoyModel> get allConvoys => {convoy.groupId: convoy};
  @override
  ConvoyModel? get activeConvoy => convoy;
  @override
  String? get activeGroupId => convoy.groupId;
  @override
  String? get myUserId => 'me';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => AppTheme.use(AppPalette.dark));

  final at1042 = DateTime(2026, 10, 8, 10, 42).millisecondsSinceEpoch;
  final now = at1042 + 12 * 60000;

  RiderModel rider(String id, String name, {double lat = 17.0, String presence = '', int seen = 0, double speed = 0}) => RiderModel(
        userId: id,
        name: name,
        lat: lat,
        lng: 78.0,
        speedKmh: speed,
        lastSeenEpochMs: seen == 0 ? now : seen,
        presence: presence,
        presenceAt: seen == 0 ? 0 : seen + 90000,
      );

  ConvoyModel convoy() => ConvoyModel(
        groupId: 'G',
        name: 'Hill run',
        joinCode: '123456',
        createdByUserId: 'me',
        createdByUserName: 'Me',
        createdAtEpochMs: 0,
        destinationLat: 17.3,
        destinationLng: 78.0,
        riders: {
          'me': rider('me', 'Me', lat: 17.05, speed: 40),
          'k': rider('k', 'Kiran', lat: 17.02, presence: 'NO_SIGNAL', seen: at1042),
          'c': rider('c', 'Chitra', lat: 17.01, presence: 'APP_CLOSED', seen: now - 3 * 60000),
          'a': rider('a', 'Arjun', lat: 17.04, presence: 'ONLINE'),
        },
      );

  group('presence words (pure)', () {
    String clock(int ms) => '10:42';
    test('no signal: time of the last update and the place', () {
      final c = convoy();
      expect(presenceLine(c.riders['k']!, isMe: false, place: 'Hosur', clock: clock), 'No signal since 10:42 near Hosur');
      expect(presenceLine(c.riders['k']!, isMe: false, clock: clock), 'No signal since 10:42');
    });
    test('app closed, online, unknown and me', () {
      final c = convoy();
      expect(presenceLine(c.riders['c']!, isMe: false, clock: clock), 'App closed on this phone');
      expect(presenceLine(c.riders['a']!, isMe: false, clock: clock), isNull);
      expect(presenceLine(rider('x', 'Old app'), isMe: false, clock: clock), isNull, reason: 'older gateways send no presence');
      expect(presenceLine(c.riders['k']!, isMe: true, clock: clock), isNull);
    });
  });

  Future<void> narrow(WidgetTester tester, Widget child, {required AppPalette palette, ConvoyService? service}) async {
    AppTheme.use(palette);
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = MaterialApp(
      theme: AppTheme.themeFor(palette),
      builder: (context, w) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
        child: w ?? const SizedBox.shrink(),
      ),
      home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child)),
    );
    await tester.pumpWidget(service == null ? app : ChangeNotifierProvider<ConvoyService>.value(value: service, child: app));
    await tester.pump();
  }

  for (final palette in [AppPalette.light, AppPalette.dark]) {
    final theme = palette.isLight ? 'light' : 'dark';

    testWidgets('ladder at 320 dp x1.3 $theme: no signal with time and place, app closed, possible incident chip', (tester) async {
      final c = convoy();
      final statuses = {for (final r in c.riders.values) r.userId: riderStatusOf(r, c, isMe: r.userId == 'me', nowMs: now)};
      await narrow(
        tester,
        RidersLadder(
          rungs: RideFacts.ladder(c, 'me'),
          colors: const {},
          statuses: statuses,
          nowMs: now,
          onTap: (_) {},
          offlinePlaces: const {'k': 'Hosur'},
          possibleIncident: const {'a'},
        ),
        palette: palette,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('No signal since 10:42 AM near Hosur'), findsOneWidget);
      expect(find.text('App closed on this phone'), findsOneWidget);
      expect(find.text('Possible incident'), findsOneWidget);
      // The presence line replaces "last seen" on the chip (no duplicate words).
      expect(find.textContaining('last seen'), findsNothing);
    });

    testWidgets('rider card at 320 dp x1.3 $theme: no signal since, app closed', (tester) async {
      final api = ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: const FlutterSecureStorage());
      final service = _OneConvoy(api, convoy());
      await narrow(tester, RiderCard(convoyId: 'G', userId: 'k', onShowOnMap: (_) {}), palette: palette, service: service);
      expect(tester.takeException(), isNull);
      expect(find.text('No signal since 10:42 AM'), findsOneWidget);

      await narrow(tester, RiderCard(convoyId: 'G', userId: 'c', onShowOnMap: (_) {}), palette: palette, service: service);
      expect(find.text('App closed on this phone'), findsOneWidget);
      expect(find.byType(RiderStatusChip), findsOneWidget);
    });
  }
}
