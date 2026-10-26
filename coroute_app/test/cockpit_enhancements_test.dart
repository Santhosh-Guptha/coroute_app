import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/presentation/ride/group_settings_sheet.dart';
import 'package:coroute_app/presentation/rider/widgets/cockpit_shortcuts_dock.dart';
import 'package:coroute_app/presentation/rider/widgets/coroute_orbit_control.dart';
import 'package:coroute_app/presentation/rider/widgets/glove_quick_settings_modal.dart';
import 'package:coroute_app/presentation/rider/widgets/minimal_cockpit_overlay.dart';


class MockConvoyService extends ChangeNotifier implements ConvoyService {
  @override
  String? activeGroupId = 'GRP-COCKPIT-1';

  @override
  ConvoyModel? activeConvoy;

  @override
  Map<String, ConvoyModel> allConvoys = {};

  @override
  String? myUserId = 'rider_cockpit_me';

  @override
  bool canEditRoute = true;

  @override
  bool isOnline = true;

  @override
  bool isRealGpsActive = true;

  @override
  String? lastError;

  @override
  bool supports(dynamic feature) => true;

  final List<Map<String, dynamic>> configUpdates = [];

  @override
  void updateGroupConfig({
    double? distanceThresholdMeters,
    int? stopThresholdSeconds,
    int? speedLimitKmh,
    int? townLimitKmh,
    bool? voiceGuidanceEnabled,
    Map<String, dynamic>? featurePolicy,
  }) {
    configUpdates.add({
      ...?distanceThresholdMeters != null ? {'distanceThresholdMeters': distanceThresholdMeters} : null,
      ...?stopThresholdSeconds != null ? {'stopThresholdSeconds': stopThresholdSeconds} : null,
      ...?speedLimitKmh != null ? {'speedLimitKmh': speedLimitKmh} : null,
      ...?townLimitKmh != null ? {'townLimitKmh': townLimitKmh} : null,
      ...?voiceGuidanceEnabled != null ? {'voiceGuidanceEnabled': voiceGuidanceEnabled} : null,
      ...?featurePolicy != null ? {'featurePolicy': featurePolicy} : null,
    });
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RiderModel createTestRider(String id, String name) {
  return RiderModel(
    userId: id,
    name: name,
    lat: 17.4330,
    lng: 78.3782,
    speedKmh: 40.0,
    statusReason: '',
    lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
  );
}

ConvoyModel createTestConvoy(RiderModel me) {
  return ConvoyModel(
    groupId: 'GRP-COCKPIT-1',
    name: 'Hyderabad Riders Club',
    joinCode: '456789',
    createdByUserId: me.userId,
    createdByUserName: me.name,
    createdAtEpochMs: 1700000000000,
    riders: {me.userId: me},
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget wrap(Widget child, [ConvoyService? convoyService, SettingsService? settingsService]) {
    final providers = [
      if (convoyService != null) ChangeNotifierProvider<ConvoyService>.value(value: convoyService),
      if (settingsService != null) ChangeNotifierProvider<SettingsService>.value(value: settingsService),
    ];
    final app = MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(body: child),
    );
    return providers.isNotEmpty
        ? MultiProvider(providers: providers, child: app)
        : app;
  }

  testWidgets('CockpitShortcutsDock contains all 7 quick controls including Ride Guardian and Fuel', (tester) async {
    final me = createTestRider('rider_cockpit_me', 'Eagle');
    final convoy = createTestConvoy(me);
    final rt = RealtimeService();
    final intercom = IntercomService(rt);
    final settings = SettingsService();
    await settings.load();

    await tester.pumpWidget(
      wrap(
        CockpitShortcutsDock(
          convoy: convoy,
          me: me,
          intercomService: intercom,
          settingsService: settings,
          keepScreenOn: false,
          autoFollow: true,
          onToggleKeepScreenOn: () {},
          onToggleAutoFollow: () {},
          onEssentialsRadarTap: () {},
        ),
      ),
    );

    // Verify all 7 shortcut keys exist
    expect(find.byKey(const Key('cockpit_dock_voice_toggle')), findsOneWidget);
    expect(find.byKey(const Key('cockpit_dock_guardian')), findsOneWidget);
    expect(find.byKey(const Key('cockpit_dock_fuel')), findsOneWidget);
    expect(find.byKey(const Key('cockpit_dock_stop_reason')), findsOneWidget);
    expect(find.byKey(const Key('cockpit_dock_essentials_radar')), findsOneWidget);
    expect(find.byKey(const Key('cockpit_dock_intercom_toggle')), findsOneWidget);
    expect(find.byKey(const Key('cockpit_dock_quick_settings')), findsOneWidget);
  });

  testWidgets('GloveQuickSettingsModal renders Ride Guardian and Fuel in-flight actions', (tester) async {
    FeatureGates.activeTier = SubscriptionTier.proRider;
    addTearDown(() => FeatureGates.activeTier = SubscriptionTier.community);
    final settings = SettingsService();
    await settings.load();

    bool guardianClicked = false;
    bool fuelClicked = false;

    await tester.pumpWidget(
      wrap(
        Builder(builder: (ctx) {
          return ElevatedButton(
            onPressed: () {
              GloveQuickSettingsModal.show(
                ctx,
                settingsService: settings,
                keepScreenOn: true,
                autoFollow: true,
                onToggleKeepScreenOn: () {},
                onToggleAutoFollow: () {},
                onOpenGuardian: () => guardianClicked = true,
                onOpenFuel: () => fuelClicked = true,
              );
            },
            child: const Text('Show Glove Settings'),
          );
        }),
      ),
    );

    await tester.tap(find.text('Show Glove Settings'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quick_action_guardian_share')), findsOneWidget);
    expect(find.byKey(const Key('quick_action_fuel_sheet')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('quick_action_guardian_share')));
    await tester.tap(find.byKey(const Key('quick_action_guardian_share')));
    await tester.pumpAndSettle();
    expect(guardianClicked, isTrue);

    // Reopen modal to test fuel button
    await tester.tap(find.text('Show Glove Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('quick_action_fuel_sheet')));
    await tester.tap(find.byKey(const Key('quick_action_fuel_sheet')));
    await tester.pumpAndSettle();
    expect(fuelClicked, isTrue);
  });

  testWidgets('GroupSettingsView renders structured cards and Ride Guardian share button', (tester) async {
    final me = createTestRider('rider_cockpit_me', 'Eagle');
    final convoy = createTestConvoy(me);
    final convoyService = MockConvoyService();
    convoyService.activeConvoy = convoy;
    convoyService.allConvoys[convoy.groupId] = convoy;

    await tester.pumpWidget(
      wrap(
        const SingleChildScrollView(child: GroupSettingsView(convoyId: 'GRP-COCKPIT-1')),
        convoyService,
      ),
    );

    // Ride Guardian section & share button
    expect(find.byKey(const Key('group_settings_guardian_share_btn')), findsOneWidget);
    expect(find.text('Share with a Ride Guardian'), findsOneWidget);

    // Section cards
    expect(find.text('Ride feature controls'), findsOneWidget);
    expect(find.text('Convoy safety limits'), findsOneWidget);
    expect(find.text('Audio & guidance alerts'), findsOneWidget);
    expect(find.text('Sharing my location'), findsOneWidget);
  });

  testWidgets('Strict CoRoute standards: ZERO emojis and ASCII hyphens across all modified components', (tester) async {
    final me = createTestRider('rider_cockpit_me', 'Eagle');
    final convoy = createTestConvoy(me);
    final convoyService = MockConvoyService();
    convoyService.activeConvoy = convoy;
    convoyService.allConvoys[convoy.groupId] = convoy;

    await tester.pumpWidget(
      wrap(
        const SingleChildScrollView(child: GroupSettingsView(convoyId: 'GRP-COCKPIT-1')),
        convoyService,
      ),
    );

    for (final element in find.byType(Text).evaluate()) {
      final textWidget = element.widget as Text;
      final text = textWidget.data ?? '';
      expect(text.contains(RegExp(r'[\u{1F300}-\u{1FAFF}]', unicode: true)), isFalse, reason: 'Must not contain emoji: $text');
      expect(text.contains('\u2013'), isFalse, reason: 'Must not contain en-dash: $text');
      expect(text.contains('\u2014'), isFalse, reason: 'Must not contain em-dash: $text');
    }
  });

  testWidgets('CorouteOrbitControl renders draggable FAB and opens 6-tile Quick Access popup', (tester) async {
    bool groupTapped = false;
    bool fuelTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CorouteOrbitControl(
            onIntercomTap: () {},
            onGroupTap: () => groupTapped = true,
            onFuelTap: () => fuelTapped = true,
            onRouteTap: () {},
            onGuardianTap: () {},
            onMoreTap: () {},
          ),
        ),
      ),
    );

    // Initial state: FAB visible, popup closed
    expect(find.byType(CorouteOrbitControl), findsOneWidget);
    expect(find.text('COROUTE ORBIT'), findsNothing);

    // Tap Orbit FAB -> opens popup
    await tester.tap(find.byKey(const Key('coroute_orbit_fab_button')));
    await tester.pumpAndSettle();

    // Verify popup and 6 action tiles
    expect(find.text('COROUTE ORBIT'), findsOneWidget);
    expect(find.text('QUICK ACCESS'), findsOneWidget);
    expect(find.text('Intercom'), findsOneWidget);
    expect(find.text('Group'), findsOneWidget);
    expect(find.text('Fuel'), findsOneWidget);
    expect(find.text('Route'), findsOneWidget);
    expect(find.text('Guardian'), findsOneWidget);
    expect(find.text('More'), findsOneWidget);

    // Tap Group tile -> triggers callback and closes popup
    await tester.tap(find.text('Group'));
    await tester.pumpAndSettle();
    expect(groupTapped, isTrue);
    expect(fuelTapped, isFalse);
    expect(find.text('COROUTE ORBIT'), findsNothing);
  });

  testWidgets('MinimalCockpitTopBar renders destination title, GPS status, and back button', (tester) async {
    bool backPressed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MinimalCockpitTopBar(
            title: 'To Hampi, 142 km',
            connection: null,
            gps: GpsState.accurate,
            onBack: () => backPressed = true,
          ),
        ),
      ),
    );

    expect(find.text('To Hampi, 142 km'), findsOneWidget);
    expect(find.byType(MinimalCockpitTopBar), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    expect(backPressed, isTrue);
  });

  testWidgets('MinimalCockpitTopBar renders navigation tile and handles onNavigationTap', (tester) async {
    bool navPressed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MinimalCockpitTopBar(
            title: 'To Hampi, 142 km',
            connection: null,
            gps: GpsState.accurate,
            onNavigationTap: () => navPressed = true,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('top_bar_navigation_action')), findsOneWidget);
    await tester.tap(find.byKey(const Key('top_bar_navigation_action')));
    expect(navPressed, isTrue);
  });

  testWidgets('MinimalRideStatsBar renders 4 key metrics and handles tap', (tester) async {
    bool tapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MinimalRideStatsBar(
            remainingText: '142 km',
            etaText: '4:35 PM',
            ridingCount: 5,
            totalCount: 8,
            spreadText: '2.1 km',
            onTap: () => tapped = true,
          ),
        ),
      ),
    );

    expect(find.text('142 km'), findsOneWidget);
    expect(find.text('4:35 PM'), findsOneWidget);
    expect(find.text('5/8'), findsOneWidget);
    expect(find.text('2.1 km'), findsOneWidget);

    await tester.tap(find.byType(MinimalRideStatsBar));
    expect(tapped, isTrue);
  });

  testWidgets('MinimalStoppedBar renders duration and triggers onTellWhy', (tester) async {
    bool tellWhyTapped = false;
    bool barTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MinimalStoppedBar(
            stoppedFor: const Duration(minutes: 8),
            nearbyCount: 2,
            onTap: () => barTapped = true,
            onTellWhy: () => tellWhyTapped = true,
          ),
        ),
      ),
    );

    expect(find.text('stopped 8m'), findsOneWidget);
    expect(find.text('2 riders nearby'), findsOneWidget);

    await tester.tap(find.text('Tell why'));
    expect(tellWhyTapped, isTrue);

    await tester.tap(find.text('stopped 8m'));
    expect(barTapped, isTrue);
  });

  testWidgets('MinimalSpeedAlert renders speed and semantics', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MinimalSpeedAlert(
            speedKmh: 94.0,
            limitKmh: 80,
          ),
        ),
      ),
    );

    expect(find.text('94 km/h'), findsOneWidget);
    expect(find.byType(MinimalSpeedAlert), findsOneWidget);
  });

  testWidgets('MapSideControls renders quick controls and responds to taps', (tester) async {
    bool screenOnToggled = false;
    bool centred = false;
    bool sheetOpened = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapSideControls(
            keepScreenOn: false,
            autoFollow: true,
            onToggleKeepScreenOn: () => screenOnToggled = true,
            onCentre: () => centred = true,
            onOpenSheet: () => sheetOpened = true,
            visible: true,
          ),
        ),
      ),
    );

    expect(find.byType(MapSideControls), findsOneWidget);

    await tester.tap(find.byTooltip('Keep screen on'));
    expect(screenOnToggled, isTrue);

    await tester.tap(find.byTooltip('Centre on me'));
    expect(centred, isTrue);

    await tester.tap(find.byTooltip('Open ride sheet'));
    expect(sheetOpened, isTrue);
  });

  testWidgets('CockpitSpeedometer renders big bold tabular figures with glow and speed limit badge', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CockpitSpeedometer(
            speedKmh: 85.0,
            speedLimitKmh: 80,
          ),
        ),
      ),
    );

    expect(find.byType(CockpitSpeedometer), findsOneWidget);
    expect(find.text('85'), findsOneWidget);
    expect(find.text('KM/H'), findsOneWidget);
    expect(find.text('OVER 80'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

    final textWidget = tester.widget<Text>(find.text('85'));
    expect(textWidget.style?.fontFeatures?.contains(const FontFeature.tabularFigures()), isTrue);
    expect(textWidget.style?.shadows, isNotNull);
    expect(textWidget.style?.shadows!.isNotEmpty, isTrue);
  });

  testWidgets('CockpitSosButton enforces glove-friendly minimum 56dp size and hold-to-send confirmation', (tester) async {
    bool triggered = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CockpitSosButton(
              size: 50.0, // smaller size requested, must be clamped to 56dp minimum
              holdDuration: const Duration(milliseconds: 500),
              showLabel: true,
              onTriggered: () => triggered = true,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(CockpitSosButton), findsOneWidget);
    expect(find.text('SOS'), findsOneWidget);
    expect(find.byIcon(Icons.emergency_rounded), findsOneWidget);

    // Verify touch target dimension is at least 56dp
    final containerFinder = find.descendant(
      of: find.byType(CockpitSosButton),
      matching: find.byType(Container),
    );
    final box = tester.renderObject<RenderBox>(containerFinder.first);
    expect(box.size.width, greaterThanOrEqualTo(56.0));
    expect(box.size.height, greaterThanOrEqualTo(56.0));

    // Tap and release immediately does NOT trigger SOS
    await tester.tap(find.byType(CockpitSosButton));
    await tester.pump(const Duration(milliseconds: 100));
    expect(triggered, isFalse);

    // Hold for duration triggers SOS
    final gesture = await tester.startGesture(tester.getCenter(find.byType(CockpitSosButton)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 200));
    expect(triggered, isFalse);

    await tester.pump(const Duration(milliseconds: 400));
    expect(triggered, isTrue);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('CockpitStatusPillsBar renders all 4 HUD status pills cleanly with pure vector icons', (tester) async {
    bool ridersTapped = false;
    bool airbagTapped = false;
    bool remoteTapped = false;
    bool tunnelTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CockpitStatusPillsBar(
            riderCount: 4,
            isAirbagPaired: true,
            isRemotePaired: true,
            isTunnelMode: true,
            onRidersTap: () => ridersTapped = true,
            onAirbagTap: () => airbagTapped = true,
            onRemoteTap: () => remoteTapped = true,
            onTunnelTap: () => tunnelTapped = true,
          ),
        ),
      ),
    );

    // Verify all 4 status pills render
    expect(find.byKey(const Key('cockpit_pill_live_riders')), findsOneWidget);
    expect(find.byKey(const Key('cockpit_pill_airbag')), findsOneWidget);
    expect(find.byKey(const Key('cockpit_pill_remote')), findsOneWidget);
    expect(find.byKey(const Key('cockpit_pill_tunnel_mode')), findsOneWidget);

    expect(find.text('Live · 4 Riders'), findsOneWidget);
    expect(find.text('Airbag'), findsOneWidget);
    expect(find.text('Remote'), findsOneWidget);
    expect(find.text('Tunnel Mode'), findsOneWidget);

    // Verify vector icons
    expect(find.byIcon(Icons.shield_rounded), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);
    expect(find.byIcon(Icons.alt_route_rounded), findsOneWidget);

    // Verify tap handlers
    await tester.tap(find.byKey(const Key('cockpit_pill_live_riders')));
    expect(ridersTapped, isTrue);

    await tester.tap(find.byKey(const Key('cockpit_pill_airbag')));
    expect(airbagTapped, isTrue);

    await tester.tap(find.byKey(const Key('cockpit_pill_remote')));
    expect(remoteTapped, isTrue);

    await tester.tap(find.byKey(const Key('cockpit_pill_tunnel_mode')));
    expect(tunnelTapped, isTrue);
  });
}

