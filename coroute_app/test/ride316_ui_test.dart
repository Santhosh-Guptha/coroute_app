import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/l10n/l10n.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/ui/ui.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/network_models.dart';
import 'package:coroute_app/data/models/outbox_item.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/tile_cache_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/data/services/weather_service.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/presentation/admin/admin_emergencies_panel.dart';
import 'package:coroute_app/presentation/ride/assist_banner.dart';
import 'package:coroute_app/presentation/ride/group_settings_sheet.dart';
import 'package:coroute_app/presentation/ride/incident_sheet.dart';
import 'package:coroute_app/presentation/ride/navigate_to.dart';
import 'package:coroute_app/presentation/ride/ride_sheet.dart';
import 'package:coroute_app/presentation/ride/rider_card_sheet.dart';
import 'package:coroute_app/presentation/ride/riders_ladder.dart';
import 'package:coroute_app/presentation/rider/rider_home_screen.dart';
import 'package:coroute_app/presentation/safety/safety_settings_sheet.dart';
import 'package:coroute_app/presentation/trip_planner/trip_review_sheet.dart';

const int now = 1800000000000;

/// ConvoyService with a fixed convoy and recorded 3.16 calls (no socket).
class _Convoys extends ConvoyService {
  _Convoys(ApiClient api, this.convoy, {this.lead = false, this.ride316 = true, this.me = 'u_me'})
      : super(api, RealtimeService(), TripStorageService(api));

  ConvoyModel convoy;
  final bool lead;
  final bool ride316;
  final String me;
  final List<(String, bool)> sweeperCalls = [];
  final List<int> townLimits = [];
  final List<String> left = [];
  bool leaveFlag = false;
  int clears = 0;
  LiveLink? link;
  int creates = 0, revokes = 0;
  bool createFails = false;

  @override
  Map<String, ConvoyModel> get allConvoys => {convoy.groupId: convoy};
  @override
  ConvoyModel? get activeConvoy => convoy;
  @override
  String? get activeGroupId => convoy.groupId;
  @override
  String? get myUserId => me;
  @override
  bool get canEditRoute => lead;
  @override
  bool get isOnline => true;
  @override
  bool supports(String feature) => feature == ProtocolFeatures.ride316 ? ride316 : feature != ProtocolFeatures.discovery;
  @override
  List<OutboxItem> get outbox => const [];
  @override
  bool setSweeper(String userId, {required bool on}) {
    sweeperCalls.add((userId, on));
    return true;
  }

  @override
  void updateGroupConfig({double? distanceThresholdMeters, int? stopThresholdSeconds, bool? voiceGuidanceEnabled, int? speedLimitKmh, int? townLimitKmh}) {
    if (townLimitKmh != null) townLimits.add(townLimitKmh);
  }

  @override
  bool get leaveRequestedFromNotification => leaveFlag;
  @override
  void clearLeaveRequest() {
    leaveFlag = false;
    clears++;
  }

  @override
  Future<void> leaveActiveConvoy(String userId) async => left.add(userId);

  @override
  LiveLink? liveLinkFor(String alertId) => link;
  @override
  Future<LiveLink?> createLiveLink(String alertId) async {
    creates++;
    if (createFails) return null;
    link = LiveLink(token: 'abcdefghijklmnopqrstuvwxyz012345', url: 'https://coroute.test/e/abcdefghijklmnopqrstuvwxyz012345', expiresAt: now + 1800000);
    notifyListeners();
    return link;
  }

  @override
  Future<bool> revokeLiveLink(String alertId) async {
    revokes++;
    link = null;
    notifyListeners();
    return true;
  }
}

/// A WeatherService whose answer is fixed (no gateway).
class _Weather extends WeatherService {
  _Weather(super.api, super.settings, this.answer);
  final WeatherSummary? answer;
  int checks = 0;
  @override
  Future<WeatherSummary?> check(List<WeatherPoint> pts, {bool force = false}) async {
    checks++;
    return answer;
  }
}

/// A TilePrefetcher with a scripted state (no downloads).
class _Prefetcher extends TilePrefetcher {
  _Prefetcher() : super(null);
  bool isRunning = false;
  int d = 0, t = 0;
  String? err;
  int starts = 0;
  @override
  bool get running => isRunning;
  @override
  int get done => d;
  @override
  int get total => t;
  @override
  String? get error => err;
  @override
  Future<void> start(List<(double, double)> line, {required String label}) async {
    starts++;
  }
}

ApiClient api() => ApiClient(httpClient: MockClient((_) async => http.Response('{}', 200)), storage: const FlutterSecureStorage());

Map<String, dynamic> rider(String id, String name, {String role = 'PACK', int battery = 80, bool charging = false, double lat = 17.40}) => {
      'userId': id,
      'name': name,
      'lat': lat,
      'lng': 78.0,
      'role': role,
      'batteryLevel': battery,
      'isCharging': charging,
      'lastSeenEpochMs': now - 10000,
      'speedKmh': 40,
    };

ConvoyModel convoy({String sweeper = '', List<Map<String, dynamic>> alerts = const [], int townLimit = 0}) => ConvoyModel.fromJson({
      'groupId': 'G1',
      'name': 'Hill run',
      'joinCode': '123456',
      'createdByUserId': 'u_lead',
      'tripStatus': 'STARTED',
      'townLimitKmh': townLimit,
      'riders': {
        'u_me': rider('u_me', 'Me', lat: 17.40),
        'u_lead': rider('u_lead', 'Lead', role: 'LEAD', lat: 17.41),
        'u_k': rider('u_k', 'Kiran', battery: 14, role: sweeper == 'u_k' ? 'SWEEPER' : 'PACK', lat: 17.39),
        'u_a': rider('u_a', 'Arjun', battery: 14, charging: true, lat: 17.38),
      },
      'activeAlerts': alerts,
    });

Map<String, dynamic> sos({Map<String, dynamic>? hospital}) => {
      'alertId': 'A1',
      'userId': 'u_k',
      'userName': 'Kiran',
      'lat': 17.39,
      'lng': 78.0,
      'alertType': 'CRASH',
      'timestamp': now - 60000,
      'auto': true,
      'nearestHospital': ?hospital,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    navigateLauncherOverride = null;
    LiveLinkControls.shareOverride = null;
    adminDialOverride = null;
  });
  tearDown(() {
    L10n.setLanguage(AppLanguage.system);
    AppTheme.use(AppPalette.dark);
    navigateLauncherOverride = null;
    LiveLinkControls.shareOverride = null;
    adminDialOverride = null;
  });

  Future<void> render(WidgetTester tester, Widget child, {List<SingleChildWidget> providers = const [], Size size = const Size(320, 640)}) async {
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
      home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(12), child: child)),
    );
    await tester.pumpWidget(providers.isEmpty ? app : MultiProvider(providers: providers, child: app));
    await tester.pump();
  }

  group('sweeper and battery (items 11, 12)', () {
    testWidgets('the lead sees Make sweeper on a pack rider, Remove sweeper on the sweeper, nothing on the lead', (tester) async {
      final c = _Convoys(api(), convoy(sweeper: 'u_k'), lead: true);
      await render(tester, RiderCard(convoyId: 'G1', userId: 'u_a', onShowOnMap: (_) {}), providers: [ChangeNotifierProvider<ConvoyService>.value(value: c)]);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Make sweeper'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Make sweeper'));
      expect(c.sweeperCalls, [('u_a', true)]);

      await render(tester, RiderCard(convoyId: 'G1', userId: 'u_k', onShowOnMap: (_) {}), providers: [ChangeNotifierProvider<ConvoyService>.value(value: c)]);
      expect(find.text('Sweeper'), findsOneWidget, reason: 'the role marker on the card');
      await tester.scrollUntilVisible(find.text('Remove sweeper'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Remove sweeper'));
      expect(c.sweeperCalls.last, ('u_k', false));

      await render(tester, RiderCard(convoyId: 'G1', userId: 'u_lead', onShowOnMap: (_) {}), providers: [ChangeNotifierProvider<ConvoyService>.value(value: c)]);
      expect(find.text('Make sweeper'), findsNothing, reason: 'never the lead');
    });

    testWidgets('a pack rider never sees the sweeper actions; neither does anyone on an older gateway', (tester) async {
      final pack = _Convoys(api(), convoy(), lead: false);
      await render(tester, RiderCard(convoyId: 'G1', userId: 'u_a', onShowOnMap: (_) {}), providers: [ChangeNotifierProvider<ConvoyService>.value(value: pack)]);
      expect(find.text('Make sweeper'), findsNothing);
      final old = _Convoys(api(), convoy(), lead: true, ride316: false);
      await render(tester, RiderCard(convoyId: 'G1', userId: 'u_a', onShowOnMap: (_) {}), providers: [ChangeNotifierProvider<ConvoyService>.value(value: old)]);
      expect(find.text('Make sweeper'), findsNothing);
    });

    testWidgets('rider card: "14% battery" chip when low and not charging', (tester) async {
      final c = _Convoys(api(), convoy());
      await render(tester, RiderCard(convoyId: 'G1', userId: 'u_k', onShowOnMap: (_) {}), providers: [ChangeNotifierProvider<ConvoyService>.value(value: c)]);
      expect(find.text('14% battery'), findsOneWidget);
      await render(tester, RiderCard(convoyId: 'G1', userId: 'u_a', onShowOnMap: (_) {}), providers: [ChangeNotifierProvider<ConvoyService>.value(value: c)]);
      expect(find.text('14% battery'), findsNothing, reason: 'charging');
    });

    testWidgets('ladder: the sweeper rung has the tail marker, a low rider the battery chip, both in the semantics', (tester) async {
      final c = convoy(sweeper: 'u_k');
      final snap = RideFacts.snapshot(c, 'u_me');
      final statuses = {for (final r in c.riders.values) r.userId: RiderStatus.riding};
      await render(tester, RidersLadder(rungs: snap.ladder, colors: const {}, statuses: statuses, nowMs: now, onTap: (_) {}));
      expect(tester.takeException(), isNull);
      expect(find.byType(SweeperMarker), findsOneWidget);
      expect(find.text('Sweeper'), findsOneWidget);
      expect(find.byType(LowBatteryChip), findsOneWidget, reason: 'Kiran only; Arjun is charging');
      expect(find.text('14% battery'), findsOneWidget);
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp('Kiran.*14% battery.*Sweeper')), findsOneWidget);
      handle.dispose();
    });
  });

  group('group settings (items 11, 13)', () {
    testWidgets('town limit: the lead picks a value, a pack rider only reads it; the sweeper line', (tester) async {
      final lead = _Convoys(api(), convoy(sweeper: 'u_k', townLimit: 40), lead: true);
      await render(tester, const GroupSettingsView(convoyId: 'G1'), providers: [ChangeNotifierProvider<ConvoyService>.value(value: lead)]);
      expect(tester.takeException(), isNull);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text(GroupSettingsView.townLimitTitle), 200, scrollable: list);
      expect(find.text('40 km/h'), findsOneWidget);
      expect(find.text('Sweeper: Kiran'), findsOneWidget);
      await tester.tap(find.text('50'));
      expect(lead.townLimits, [50]);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Off').last);
      expect(lead.townLimits, [50, 0]);

      final pack = _Convoys(api(), convoy(), lead: false);
      await render(tester, const GroupSettingsView(convoyId: 'G1'), providers: [ChangeNotifierProvider<ConvoyService>.value(value: pack)]);
      await tester.scrollUntilVisible(find.text(GroupSettingsView.townLimitTitle), 200, scrollable: list);
      expect(find.text(GroupSettingsView.sweeperLine(pack.convoy)), findsOneWidget);
      expect(find.text("No sweeper yet (set from a rider's card)"), findsOneWidget);
      await tester.tap(find.text('50'));
      expect(pack.townLimits, isEmpty, reason: 'read only for the pack');
    });

    testWidgets('an older gateway shows no town limit', (tester) async {
      final c = _Convoys(api(), convoy(), lead: true, ride316: false);
      await render(tester, const GroupSettingsView(convoyId: 'G1'), providers: [ChangeNotifierProvider<ConvoyService>.value(value: c)]);
      expect(find.text(GroupSettingsView.townLimitTitle), findsNothing);
    });
  });

  group('ride sheet rows (items 2, 7, 8, 16)', () {
    test('save map states', () {
      expect(saveMapStateOf(running: false, done: 0, total: 0), SaveMapState.idle);
      expect(saveMapStateOf(running: true, done: 240, total: 600), SaveMapState.running);
      expect(saveMapStateOf(running: false, done: 600, total: 600), SaveMapState.saved);
      expect(saveMapStateOf(running: false, done: 10, total: 600, error: 'network'), SaveMapState.failed);
      expect(SaveRouteMapRow.progressTitle(240, 600), 'Saving route map: 240 of 600');
    });

    testWidgets('Save route map: button, progress line, saved, failed with retry', (tester) async {
      var saves = 0;
      await render(tester, SaveRouteMapRow(running: false, done: 0, total: 0, onSave: () => saves++));
      expect(find.text(SaveRouteMapRow.idleTitle), findsOneWidget);
      await tester.tap(find.text(SaveRouteMapRow.idleTitle));
      expect(saves, 1);
      await render(tester, SaveRouteMapRow(running: true, done: 240, total: 600, onSave: () => saves++));
      expect(find.text('Saving route map: 240 of 600'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await render(tester, SaveRouteMapRow(running: false, done: 600, total: 600, onSave: () => saves++));
      expect(find.text(SaveRouteMapRow.savedTitle), findsOneWidget);
      await render(tester, SaveRouteMapRow(running: false, done: 5, total: 600, error: 'network', onSave: () => saves++));
      expect(find.text(SaveRouteMapRow.failedTitle), findsOneWidget);
      await tester.tap(find.text(SaveRouteMapRow.failedTitle));
      expect(saves, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('weather and dark lines under the ride sheet title', (tester) async {
      await render(
        tester,
        const Column(children: [
          SheetLine(icon: Icons.umbrella_rounded, text: 'Rain likely after Warangal around 3 PM.'),
          SheetLine(icon: Icons.nights_stay_rounded, text: 'Dark in 40 min'),
        ]),
      );
      expect(find.text('Rain likely after Warangal around 3 PM.'), findsOneWidget);
      expect(find.text('Dark in 40 min'), findsOneWidget);
      expect(find.byIcon(Icons.umbrella_rounded), findsOneWidget);
    });

    testWidgets('fuel row without a tap target still offers Filled up through its trailing button', (tester) async {
      var filled = 0;
      await render(
        tester,
        SheetRow(
          icon: Icons.local_gas_station_rounded,
          title: '162 km since last fill',
          subtitle: 'Tank range 250 km',
          trailing: TextButton(onPressed: () => filled++, child: const Text('Filled up')),
        ),
      );
      expect(find.text('162 km since last fill'), findsOneWidget);
      expect(find.text('Tank range 250 km'), findsOneWidget);
      await tester.tap(find.text('Filled up'));
      expect(filled, 1);
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing, reason: 'not a navigation row');
    });
  });

  group('review sheet (items 7, 8, 16)', () {
    final line = [for (var i = 0; i <= 20; i++) (17.40 + i * 0.01, 78.40 + i * 0.01)];
    RouteModel route({int durationS = 3600}) => RouteModel(distanceM: 30000, durationS: durationS, polyline: GeoMath.encodePolyline(line));

    test('darkLine: null by day, the sunset line when the ETA passes sunset (Hyderabad, early October)', () {
      String fmt(DateTime d) => '${d.hour}:${d.minute.toString().padLeft(2, '0')}';
      // 2026-10-05 10:00 IST (UTC+5:30) = 04:30 UTC.
      final morning = DateTime.utc(2026, 10, 5, 4, 30);
      expect(TripReviewSheet.darkLine(now: morning, route: route(), destinationLat: 17.4, destinationLng: 78.5, fmtTime: fmt), isNull);
      // 17:30 IST with a 2 h ride ends after the ~18:10 sunset.
      final evening = DateTime.utc(2026, 10, 5, 12, 0);
      final dark = TripReviewSheet.darkLine(now: evening, route: route(durationS: 7200), destinationLat: 17.4, destinationLng: 78.5, fmtTime: fmt);
      expect(dark, isNotNull);
      expect(dark, contains('after dark'));
      expect(TripReviewSheet.darkLine(now: evening, route: null, fmtTime: fmt), isNull);
    });

    testWidgets('one weather check when the sheet opens; the line and the attribution show; Save route map row', (tester) async {
      final settings = SettingsService();
      await settings.load();
      final weather = _Weather(
        api(),
        settings,
        const WeatherSummary(line: 'Rain likely after Warangal around 3 PM.', rain: true, firstRainIndex: 2, fetchedAt: now, attribution: 'Weather data by Open-Meteo.com'),
      );
      final pf = _Prefetcher();
      await render(
        tester,
        TripReviewSheet(name: 'Hill run', startName: 'Home', destinationName: 'Fort', route: route(), stops: 1, now: DateTime.utc(2026, 10, 5, 4, 30)),
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<WeatherService>.value(value: weather),
          ChangeNotifierProvider<TilePrefetcher>.value(value: pf),
        ],
        size: const Size(320, 800),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(weather.checks, 1);
      expect(find.text('Rain likely after Warangal around 3 PM.'), findsOneWidget);
      expect(find.text(L10n.t('weather.by')), findsOneWidget);
      expect(find.text(TripReviewSheet.checkingWeather), findsNothing);
      expect(find.text(SaveRouteMapRow.idleTitle), findsOneWidget);
      await tester.tap(find.text(SaveRouteMapRow.idleTitle));
      expect(pf.starts, 1);
    });

    testWidgets('data saver: no request, "Weather check skipped"', (tester) async {
      final settings = SettingsService();
      await settings.load();
      await settings.setLowData(true);
      final weather = _Weather(api(), settings, null);
      await render(
        tester,
        TripReviewSheet(name: 'Hill run', route: route()),
        providers: [ChangeNotifierProvider<SettingsService>.value(value: settings), ChangeNotifierProvider<WeatherService>.value(value: weather)],
        size: const Size(320, 800),
      );
      await tester.pump();
      expect(find.text(L10n.t('weather.off')), findsOneWidget);
      expect(find.text('Rain likely after Warangal around 3 PM.'), findsNothing);
    });
  });

  group('leave from the notification (item 3)', () {
    testWidgets('a confirm first; Cancel keeps the ride, Leave ride leaves; the flag is always cleared', (tester) async {
      final c = _Convoys(api(), convoy());
      c.leaveFlag = true;
      late BuildContext ctx;
      await render(tester, Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      }), providers: [ChangeNotifierProvider<ConvoyService>.value(value: c)]);
      final f1 = leaveFromNotification(ctx, c, 'u_me');
      await tester.pumpAndSettle();
      expect(c.clears, 1);
      expect(c.leaveFlag, isFalse);
      expect(find.text('Leave the ride?'), findsOneWidget);
      expect(find.text('Your group will no longer see your position.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await f1;
      expect(c.left, isEmpty);

      c.leaveFlag = true;
      final f2 = leaveFromNotification(ctx, c, 'u_me');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave ride'));
      await tester.pumpAndSettle();
      await f2;
      expect(c.left, ['u_me']);
      expect(c.clears, 2);
    });
  });

  group('live link and hospital (items 17, 18)', () {
    testWidgets('Share live link creates the link and opens the share sheet; then copy, share again and Stop sharing', (tester) async {
      final shared = <String>[];
      LiveLinkControls.shareOverride = (t) async => shared.add(t);
      final c = _Convoys(api(), convoy(alerts: [sos()]));
      await render(tester, const LiveLinkControls(alertId: 'A1'), providers: [ChangeNotifierProvider<ConvoyService>.value(value: c)]);
      expect(find.text('Share live link'), findsOneWidget);
      await tester.tap(find.text('Share live link'));
      await tester.pumpAndSettle();
      expect(c.creates, 1);
      expect(shared.single, contains('https://coroute.test/e/'));
      expect(shared.single, contains('30 minutes'));
      expect(find.textContaining('Live link active until'), findsOneWidget);
      expect(find.text('Stop sharing'), findsOneWidget);
      expect(find.text('Copy link'), findsOneWidget);
      await tester.tap(find.text('Share live link'));
      await tester.pumpAndSettle();
      expect(shared, hasLength(2));
      await tester.tap(find.text('Stop sharing'));
      await tester.pumpAndSettle();
      expect(c.revokes, 1);
      expect(find.text('Stop sharing'), findsNothing);
      expect(find.text('Share live link'), findsOneWidget);
    });

    testWidgets('when the link cannot be made a short message says so', (tester) async {
      final c = _Convoys(api(), convoy(alerts: [sos()]))..createFails = true;
      await render(tester, const LiveLinkControls(alertId: 'A1'), providers: [ChangeNotifierProvider<ConvoyService>.value(value: c)]);
      await tester.tap(find.text('Share live link'));
      await tester.pumpAndSettle();
      expect(find.text('Could not create the link right now.'), findsOneWidget);
    });

    testWidgets('incident sheet: the lead gets the live link button for another rider\'s SOS, a pack rider does not; the hospital line with Navigate', (tester) async {
      final uris = <Uri>[];
      navigateLauncherOverride = (u) async {
        uris.add(u);
        return true;
      };
      final hospital = {'name': 'Apollo Hospital', 'lat': 17.42, 'lng': 78.45, 'distanceM': 4200};
      final lead = _Convoys(api(), convoy(alerts: [sos(hospital: hospital)]), lead: true, me: 'u_lead');
      await render(
        tester,
        const IncidentSheetBody(convoyId: 'G1', subjectUserId: 'u_k', alertId: 'A1', nowMs: now),
        providers: [ChangeNotifierProvider<ConvoyService>.value(value: lead)],
        size: const Size(320, 900),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Nearest hospital: Apollo Hospital, 4.2 km'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Navigate'));
      await tester.pump();
      expect(uris, isNotEmpty);
      expect(uris.first.toString(), contains('17.42'));
      await tester.scrollUntilVisible(find.text('Share live link'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Share live link'), findsOneWidget);

      final pack = _Convoys(api(), convoy(alerts: [sos(hospital: hospital)]), lead: false, me: 'u_a');
      await render(
        tester,
        const IncidentSheetBody(convoyId: 'G1', subjectUserId: 'u_k', alertId: 'A1', nowMs: now),
        providers: [ChangeNotifierProvider<ConvoyService>.value(value: pack)],
        size: const Size(320, 900),
      );
      expect(find.text('Share live link'), findsNothing);
      expect(find.text('Nearest hospital: Apollo Hospital, 4.2 km'), findsOneWidget);
    });

    testWidgets('the hospital line is not shown when the alert has none', (tester) async {
      final c = _Convoys(api(), convoy(alerts: [sos()]), me: 'u_a');
      await render(
        tester,
        const IncidentSheetBody(convoyId: 'G1', subjectUserId: 'u_k', alertId: 'A1', nowMs: now),
        providers: [ChangeNotifierProvider<ConvoyService>.value(value: c)],
        size: const Size(320, 900),
      );
      expect(find.textContaining('Nearest hospital'), findsNothing);
    });
  });

  group('admin: call the emergency contact (item 20)', () {
    testWidgets('asks first, then dials the number the gateway answers; 404 says there is none', (tester) async {
      final dialled = <Uri>[];
      adminDialOverride = (u) async {
        dialled.add(u);
        return true;
      };
      final posts = <String>[];
      var status = 200;
      final client = ApiClient(
        httpClient: MockClient((req) async {
          posts.add('${req.method} ${req.url.path}');
          if (req.url.path.endsWith('/contact')) {
            return status == 200
                ? http.Response(jsonEncode({'name': 'Priya', 'phone': '+91 91234 56780', 'riderName': 'Kiran'}), 200)
                : http.Response(jsonEncode({'error': 'No contact', 'code': 'NO_CONTACT'}), 404);
          }
          return http.Response('{}', 200);
        }),
        storage: const FlutterSecureStorage(),
      );
      final e = AdminEmergency.fromJson({
        'groupId': 'GRP-1',
        'alertId': 'A1',
        'alertType': 'CRASH',
        'userId': 'u_k',
        'userName': 'Kiran',
        'lat': 16.07,
        'lng': 78.85,
        'startedAt': now - 60000,
      });
      late BuildContext ctx;
      await render(tester, Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      }), providers: [ChangeNotifierProvider<ApiClient>.value(value: client)]);

      final f = callEmergencyContact(ctx, e);
      await tester.pumpAndSettle();
      expect(find.text("Call Kiran's emergency contact?"), findsOneWidget);
      expect(find.text('This call is logged.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await f;
      expect(posts, isEmpty, reason: 'nothing without the confirm');

      final f2 = callEmergencyContact(ctx, e);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Call'));
      await tester.pumpAndSettle();
      await f2;
      expect(posts.single, startsWith('POST '));
      expect(posts.single, endsWith('/admin/emergencies/GRP-1/A1/contact'));
      expect(dialled.single.toString(), 'tel:+919123456780');
      expect(find.textContaining('91234'), findsNothing, reason: 'the number is never shown');

      status = 404;
      final f3 = callEmergencyContact(ctx, e);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Call'));
      await tester.pumpAndSettle();
      await f3;
      expect(find.text('No emergency contact on file.'), findsOneWidget);
      expect(dialled, hasLength(1));
    });
  });

  group('safety settings (items 2, 9, 15, 21, 22, 23)', () {
    Future<SettingsService> settingsFor(WidgetTester tester, {bool rideActive = false, _Convoys? convoys}) async {
      final s = SettingsService();
      await s.load();
      await render(
        tester,
        const SafetySettingsSheet(),
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: s),
          if (convoys != null) ChangeNotifierProvider<ConvoyService>.value(value: convoys),
        ],
        size: const Size(320, 900),
      );
      return s;
    }

    testWidgets('the language picker writes the setting and L10n follows; the sheet rereads itself', (tester) async {
      final s = await settingsFor(tester);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.byKey(const ValueKey('language')), 300, scrollable: list);
      expect(find.text('System language'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('language')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('हिन्दी').last);
      await tester.pumpAndSettle();
      expect(s.language, AppLanguage.hi);
      expect(L10n.current, 'hi');
      expect(find.text(L10n.t('settings.crash', const {}, 'hi')), findsOneWidget);
      expect(find.text('Crash detection'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('language')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();
      expect(L10n.current, 'en');
    });

    testWidgets('new switches: speak more after dark, medical ID on the lock screen, documents reminder, route maps', (tester) async {
      final s = await settingsFor(tester);
      final list = find.byType(Scrollable).first;
      expect(s.speakMoreAfterDark, isTrue);
      expect(s.medicalIdOnLockScreen, isFalse);
      expect(s.documentsReminder, isTrue);
      expect(s.saveRouteMaps, isTrue);
      for (final (title, read) in [
        ('Speak more after dark', () => s.speakMoreAfterDark),
        ('Show my medical ID on the lock screen during an SOS', () => s.medicalIdOnLockScreen),
        ('Helmet and documents reminder', () => s.documentsReminder),
        ('Save route maps on Wi-Fi', () => s.saveRouteMaps),
      ]) {
        await tester.scrollUntilVisible(find.text(title), 200, scrollable: list);
        final before = read();
        await tester.tap(find.text(title));
        await tester.pump();
        expect(read(), !before, reason: title);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('tank range: a chip writes the value, Other takes a typed number, 0 is off', (tester) async {
      final s = await settingsFor(tester);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Tank range (km)'), 200, scrollable: list);
      await tester.tap(find.text('250'));
      await tester.pump();
      expect(s.fuelRangeKm, 250);
      expect(find.text('250 km'), findsOneWidget);
      await tester.tap(find.text('Other'));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('fuelRange')), '320');
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(s.fuelRangeKm, 320);
      await tester.scrollUntilVisible(find.text('Off'), 200, scrollable: list);
      await tester.tap(find.text('Off'));
      await tester.pump();
      expect(s.fuelRangeKm, 0);
    });

    testWidgets('the developer impact row appears after 7 title taps and only during a ride', (tester) async {
      await settingsFor(tester);
      for (var i = 0; i < 7; i++) {
        await tester.tap(find.text('Ride safety'));
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('devImpact')), findsNothing, reason: 'no ride');

      await settingsFor(tester, convoys: _Convoys(api(), convoy()));
      expect(find.byKey(const ValueKey('devImpact')), findsNothing);
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.text('Ride safety'));
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('devImpact')), findsNothing, reason: 'six taps are not enough');
      await tester.tap(find.text('Ride safety'));
      await tester.pump();
      expect(find.byKey(const ValueKey('devImpact')), findsOneWidget);
      expect(find.text('Developer: simulate wearable impact'), findsOneWidget);
    });
  });

  group('far by road (item 5)', () {
    testWidgets('the request banner shows the label and the road distance and ETA', (tester) async {
      final a = AssistRequest.fromJson({
        'incidentId': 'NET-1',
        'lat': 17.4144,
        'lng': 78.0,
        'distanceM': 900,
        'aheadOnRoute': false,
        'routeDistanceM': 9400,
        'etaS': 720,
        'fasterThanGroup': true,
        'severity': 'HIGH',
        'kind': 'ACCIDENT',
        'reportedAt': now - 30000,
        'lastUpdateAt': now - 8000,
        'farByRoad': true,
      }, receivedAt: now)!;
      expect(a.farByRoad, isTrue);
      expect(AssistTexts.farBody(a), 'Far by road: 9.4 km by road, about 12 min. Your group may still be the closest riders.');
      final c = _Convoys(api(), convoy());
      await render(tester, AssistBanner(request: a, myLat: 17.40, myLng: 78.0, nowMs: now, onOpen: () {}), providers: [ChangeNotifierProvider<ConvoyService>.value(value: c)]);
      expect(tester.takeException(), isNull);
      expect(find.byType(FarByRoadChip), findsOneWidget);
      expect(find.text('Far by road'), findsOneWidget);
      expect(find.textContaining('9.4 km by road, about 12 min'), findsOneWidget);
      expect(find.text(AssistTexts.faster), findsNothing, reason: 'the far line replaces the faster line');
      expect(find.text('I Can Help'), findsOneWidget);
      expect(find.text('Navigate'), findsOneWidget);
    });
  });
}
