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
import 'package:coroute_app/data/local/track_queue.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/timeline_service.dart';
import 'package:coroute_app/data/services/track_recorder.dart';
import 'package:coroute_app/data/services/track_uploader.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/admin/admin_emergencies_panel.dart';
import 'package:coroute_app/presentation/admin/admin_user_details_screen.dart';
import 'package:coroute_app/presentation/admin/admin_users_screen.dart';
import 'package:coroute_app/presentation/admin/master_admin_dashboard.dart';

/// No sound in tests (3.14: the Emergencies panel rings for a new SOS).
class _SilentAlarm implements AdminAlarm {
  @override
  Future<void> start({required String title, required String body}) async {}
  @override
  Future<void> stop() async {}
}

/// Admin console (3.13, WP-ADM): the admin home and the users list on a
/// 320 dp phone at 1.3x text in both themes, the wide list + detail layout,
/// and the hold form, all against a fake gateway.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AdminEmergenciesPanelState.resetAcknowledged();
  });
  tearDown(() => AppTheme.use(AppPalette.dark));

  final now = DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> fleetConvoy() => {
        'groupId': 'GRP-1',
        'name': 'Sunday ride to Srisailam with the whole riding club',
        'joinCode': '482913',
        'createdByUserId': 'u1',
        'createdByUserName': 'Venkata Subramaniam Ramakrishnan',
        'destinationName': 'Srisailam Dam viewpoint, Nandyal district',
        'tripStatus': 'STARTED',
        'riders': {
          'u1': {'userId': 'u1', 'name': 'Venkata Subramaniam Ramakrishnan', 'lat': 16.08, 'lng': 78.86, 'speedKmh': 62.0, 'role': 'LEAD', 'lastSeenEpochMs': now},
          'u4': {'userId': 'u4', 'name': 'Asha', 'lat': 16.07, 'lng': 78.85, 'speedKmh': 0.0, 'lastSeenEpochMs': now},
        },
        'activeAlerts': [
          {'alertId': 'a1', 'userId': 'u4', 'userName': 'Asha', 'lat': 16.07, 'lng': 78.85, 'alertType': 'MECHANICAL', 'timestamp': now - 120000},
        ],
      };

  List<Map<String, dynamic>> users() => [
        {'userId': 'u1', 'name': 'Venkata Subramaniam Ramakrishnan', 'email': 'venkata.subramaniam@example.com', 'phone': '9876543210', 'status': 'ACTIVE',
            'isInActiveConvoy': true, 'activeGroup': {'groupId': 'GRP-1', 'name': 'Sunday ride to Srisailam', 'role': 'LEAD'}},
        {'userId': 'u2', 'name': 'Bala', 'email': 'bala@example.com', 'status': 'ON_HOLD', 'statusReason': 'Spam'},
        {'userId': 'u3', 'name': 'Chitra', 'email': 'chitra@example.com', 'status': 'BLOCKED'},
        {'userId': 'u9', 'name': 'Admin', 'email': 'admin@example.com', 'role': 'MASTER_ADMIN', 'status': 'ACTIVE'},
      ];

  /// One account as a row of `GET /api/admin/analytics/riders` (3.54).
  Map<String, dynamic> riderRow(Map<String, dynamic> u) => {
        'userId': u['userId'],
        'name': u['name'],
        'email': u['email'] ?? '',
        'phone': u['phone'] ?? '',
        'role': u['role'] ?? 'RIDER',
        'status': u['status'] ?? 'ACTIVE',
        'tier': 'community',
        'guest': false,
        'trips': 3,
        'km': 120.5,
        'ridingHours': 4.2,
        'sos': 0,
        'lastSeenAt': now - 3600000,
        'createdAt': now - 30 * 86400000,
        'riding': u['isInActiveConvoy'] == true ? {'groupId': 'GRP-1', 'name': 'Sunday ride to Srisailam'} : null,
      };

  /// Fake gateway. Records every request so tests can check the API calls.
  MockClient fakeApi(List<http.Request> calls, {List<Map<String, dynamic>>? accounts}) => MockClient((req) async {
        calls.add(req);
        final p = req.url.path;
        if (p.endsWith('/admin/analytics/riders')) {
          // Filters, search and paging on the "server", like gateway/src/admin_analytics.js.
          final qp = req.url.queryParameters;
          var rows = [for (final u in accounts ?? users()) riderRow(u)];
          final st = qp['status'] ?? '';
          if (st.isNotEmpty) rows = rows.where((r) => r['status'] == st).toList();
          if (qp['riding'] == '1') rows = rows.where((r) => r['riding'] != null).toList();
          final q = (qp['q'] ?? '').toLowerCase();
          if (q.isNotEmpty) rows = rows.where((r) => '${r['name']} ${r['email']} ${r['phone']}'.toLowerCase().contains(q)).toList();
          final cursor = int.tryParse(qp['cursor'] ?? '0') ?? 0;
          final limit = int.tryParse(qp['limit'] ?? '50') ?? 50;
          final page = rows.skip(cursor).take(limit).toList();
          final next = cursor + page.length < rows.length ? cursor + page.length : null;
          return http.Response(jsonEncode({'ok': true, 'riders': page, 'total': rows.length, 'nextCursor': next}), 200);
        }
        if (p.endsWith('/admin/fleet')) return http.Response(jsonEncode({'convoys': [fleetConvoy()]}), 200);
        if (p.endsWith('/admin/users')) return http.Response(jsonEncode({'users': users()}), 200);
        if (p.endsWith('/admin/users/u2/details')) {
          return http.Response(jsonEncode({'user': users()[1], 'activeGroup': null, 'groups': []}), 200);
        }
        if (p.endsWith('/admin/users/u2/status')) {
          return http.Response(jsonEncode({'user': {...users()[1], 'status': 'ON_HOLD'}}), 200);
        }
        return http.Response('{}', 200);
      });

  Future<void> render(WidgetTester tester,
      {required Size size,
      required double scale,
      required AppPalette palette,
      required Widget child,
      required List<http.Request> calls,
      List<Map<String, dynamic>>? accounts}) async {
    AppTheme.use(palette);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final api = ApiClient(httpClient: fakeApi(calls, accounts: accounts), storage: const FlutterSecureStorage());
    final auth = AuthService(api);
    final rt = RealtimeService();
    final trips = TripStorageService(api);
    final timeline = TimelineService(api, rt);
    final queue = MemoryTrackQueue();
    final recorder = TrackRecorder(queue, TrackUploader(api, queue));
    final convoy = ConvoyService(api, rt, trips, recorder: recorder, timeline: timeline);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<ApiClient>.value(value: api),
        ChangeNotifierProvider<RealtimeService>.value(value: rt),
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider<TripStorageService>.value(value: trips),
        ChangeNotifierProvider<TimelineService>.value(value: timeline),
        ChangeNotifierProvider<ConvoyService>.value(value: convoy),
      ],
      child: MaterialApp(
        theme: AppTheme.themeFor(palette),
        builder: (context, w) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: w ?? const SizedBox.shrink(),
        ),
        home: child,
      ),
    ));
    await tester.pump(); // post-frame: fleet watch and first loads start
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  double top(WidgetTester tester, Finder f) => tester.getTopLeft(f.first).dy;

  for (final palette in [AppPalette.light, AppPalette.dark]) {
    final theme = palette.isLight ? 'light' : 'dark';

    testWidgets('admin home at 320 dp, text x1.3, $theme: SOS, live rides, holds, then numbers', (tester) async {
      final calls = <http.Request>[];
      await render(tester, size: const Size(320, 568), scale: 1.3, palette: palette, child: MasterAdminDashboard(alarm: _SilentAlarm()), calls: calls);
      expect(tester.takeException(), isNull);

      // Real numbers come from the API: the fleet and the accounts.
      expect(calls.any((r) => r.url.path.endsWith('/admin/fleet')), isTrue);
      expect(calls.any((r) => r.url.path.endsWith('/admin/users')), isTrue);

      // 3.14: open SOS moved into the Emergencies panel at the top (same title, plus the alarm).
      expect(find.text('Emergencies (1)'), findsOneWidget);
      expect(find.text('SOS: Asha needs help'), findsOneWidget);
      expect(find.text('1 account on hold'), findsOneWidget);
      expect(find.text('Riders online'), findsOneWidget);
      expect(find.text('Open SOS'), findsOneWidget);
      expect(find.text('Accounts'), findsOneWidget);
      expect(find.text('Emergency, 1 SOS'), findsOneWidget); // status in words on the ride row

      // What needs attention comes first.
      final sosY = top(tester, find.text('SOS: Asha needs help'));
      final ridesY = top(tester, find.text('Live rides'));
      final holdY = top(tester, find.text('1 account on hold'));
      final statsY = top(tester, find.text('Overview'));
      expect(sosY < ridesY, isTrue);
      expect(ridesY < holdY, isTrue);
      expect(holdY < statsY, isTrue);

      // No text below 12 sp (before the 1.3x scale).
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        final size = t.style?.fontSize;
        if (size != null) expect(size, greaterThanOrEqualTo(12), reason: '"${t.data}" is ${size}sp');
      }
    });

    testWidgets('users list at 320 dp, text x1.3, $theme: rows, status in words, filter and search', (tester) async {
      final calls = <http.Request>[];
      await render(tester, size: const Size(320, 568), scale: 1.3, palette: palette, child: const AdminUsersScreen(), calls: calls);
      expect(tester.takeException(), isNull);

      expect(find.text('Bala'), findsOneWidget);
      expect(find.text('On hold'), findsOneWidget); // chip on the row
      expect(find.text('Blocked'), findsOneWidget);
      expect(find.text('Riding in Sunday ride to Srisailam'), findsOneWidget);

      // 3.54: the list comes from the server-side rider analytics, with the rider numbers.
      expect(calls.any((r) => r.url.path.endsWith('/admin/analytics/riders')), isTrue);
      expect(find.textContaining('3 trips'), findsWidgets);

      // Filter: one compact button that opens a menu; the status filter runs on the gateway.
      await tester.tap(find.byTooltip('Filter'));
      await tester.pump(); // the route animation starts on this frame
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('On hold').last); // the menu item (the row chip says the same)
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(calls.lastWhere((r) => r.url.path.endsWith('/admin/analytics/riders')).url.queryParameters['status'], 'ON_HOLD');
      expect(find.text('Bala'), findsOneWidget);
      expect(find.text('Chitra'), findsNothing);

      // Search (debounced, sent as q) with no match shows an empty state with a way back.
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(calls.lastWhere((r) => r.url.path.endsWith('/admin/analytics/riders')).url.queryParameters['q'], 'zzz');
      expect(find.text('No matching users'), findsOneWidget);
      expect(find.text('Show all'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('the rider list query: search, status, plan, riding, sort and cursor go to the gateway', () {
    expect(
      AdminUsersScreen.queryFor(q: ' bala ', filter: AdminUserFilter.onHold, tier: 'proRider', sort: AdminRiderSort.km, cursor: 50),
      {'q': 'bala', 'status': 'ON_HOLD', 'tier': 'proRider', 'sort': 'km', 'limit': '50', 'cursor': '50'},
    );
    expect(
      AdminUsersScreen.queryFor(q: '', filter: AdminUserFilter.riding, tier: '', sort: AdminRiderSort.lastSeen),
      {'riding': '1', 'sort': 'lastSeen', 'limit': '50', 'cursor': '0'},
    );
  });

  testWidgets('"Load more" asks for the next page with the cursor', (tester) async {
    final calls = <http.Request>[];
    final many = [
      for (var i = 0; i < 60; i++) {'userId': 'x$i', 'name': 'Rider ${i.toString().padLeft(2, '0')}', 'email': 'r$i@example.com', 'status': 'ACTIVE'},
    ];
    await render(tester, size: const Size(400, 800), scale: 1.0, palette: AppPalette.dark, child: const AdminUsersScreen(), calls: calls, accounts: many);
    final more = find.text('Load more (10 left)');
    await tester.scrollUntilVisible(more, 400, scrollable: find.byType(Scrollable).last);
    await tester.tap(more);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final pages = calls.where((r) => r.url.path.endsWith('/admin/analytics/riders')).toList();
    expect(pages.last.url.queryParameters['cursor'], '50');
    expect(find.textContaining('Load more'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('an older gateway list (no analytics endpoint) still shows who is riding', () {
    final row = AdminUsersScreen.rowFromLegacy({'userId': 'u1', 'isInActiveConvoy': true, 'activeGroup': {'groupId': 'G', 'name': 'Ride'}});
    expect(row['riding'], {'groupId': 'G', 'name': 'Ride'});
    expect(AdminUsersScreen.rowFromLegacy({'userId': 'u2'})['riding'], isNull);
  });

  testWidgets('home "Review" opens the users list filtered to accounts on hold', (tester) async {
    final calls = <http.Request>[];
    await render(tester, size: const Size(360, 740), scale: 1.0, palette: AppPalette.dark, child: MasterAdminDashboard(alarm: _SilentAlarm()), calls: calls);
    await tester.ensureVisible(find.text('Review'));
    await tester.tap(find.text('Review'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AdminUsersScreen), findsOneWidget);
    expect(find.text('Bala'), findsOneWidget);
    expect(find.text('Chitra'), findsNothing);
  });

  testWidgets('users on a tablet: list and details side by side', (tester) async {
    final calls = <http.Request>[];
    await render(tester, size: const Size(1280, 800), scale: 1.0, palette: AppPalette.light, child: const AdminUsersScreen(), calls: calls);
    expect(find.text('Pick a user'), findsOneWidget);
    await tester.tap(find.text('Bala'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byType(AdminUserDetailsScreen), findsOneWidget);
    expect(find.text('Chitra'), findsOneWidget); // the list stays
    expect(calls.any((r) => r.url.path.endsWith('/admin/users/u2/details')), isTrue);
  });

  testWidgets('hold uses a sheet with a reason and sends the same API call', (tester) async {
    final calls = <http.Request>[];
    await render(
      tester,
      size: const Size(320, 640),
      scale: 1.3,
      palette: AppPalette.dark,
      child: AdminUserDetailsScreen(userId: 'u2', initialUser: users()[1]),
      calls: calls,
    );
    // Bala is on hold: releasing needs no form.
    expect(find.text('Release hold'), findsOneWidget);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Release hold'));
    await tester.pump(const Duration(milliseconds: 300));
    final release = calls.where((r) => r.method == 'PATCH').toList();
    expect(release, hasLength(1));
    expect(jsonDecode(release.single.body), {'status': 'ACTIVE', 'reason': ''});
    await tester.pump(const Duration(seconds: 5)); // snackbar times out
    await tester.pump(const Duration(milliseconds: 500));

    // Block opens the form sheet (no AlertDialog) and sends the reason.
    expect(find.text('Block'), findsOneWidget);
    await tester.tap(find.text('Block'));
    await tester.pump(); // the route animation starts on this frame
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Block account?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Fake account');
    await tester.tap(find.text('Block account'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    final block = calls.where((r) => r.method == 'PATCH').toList();
    expect(block, hasLength(2));
    expect(block.last.url.path.endsWith('/admin/users/u2/status'), isTrue);
    expect(jsonDecode(block.last.body), {'status': 'BLOCKED', 'reason': 'Fake account'});
  });
}
