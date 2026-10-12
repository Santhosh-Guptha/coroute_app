import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/presentation/ride/group_settings_sheet.dart';
import 'package:coroute_app/presentation/rider/widgets/cockpit_shortcuts_dock.dart';
import 'package:coroute_app/presentation/rider/widgets/coroute_orbit_control.dart';
import 'package:coroute_app/presentation/rider/widgets/glove_quick_settings_modal.dart';

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
}
