import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/route_essential.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/route_essentials_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/presentation/rider/widgets/cockpit_hud_toast.dart';
import 'package:coroute_app/presentation/rider/widgets/cockpit_shortcuts_dock.dart';
import 'package:coroute_app/presentation/rider/widgets/glove_quick_settings_modal.dart';
import 'package:coroute_app/presentation/rider/widgets/quick_stop_reason_modal.dart';

class FakeConvoyService extends ChangeNotifier implements ConvoyService {
  @override
  String? activeGroupId = 'GRP-TEST-1';

  @override
  ConvoyModel? activeConvoy;

  @override
  String? myUserId = 'rider_me';

  final List<(String userId, String reason, String message)> statusUpdates = [];

  @override
  void updateStatusReason({required String userId, required String reason, String message = ''}) {
    statusUpdates.add((userId, reason, message));
    if (activeConvoy != null && activeConvoy!.riders.containsKey(userId)) {
      final old = activeConvoy!.riders[userId]!;
      final updated = old.copyWith(statusReason: reason, statusMessage: message);
      final map = Map<String, RiderModel>.from(activeConvoy!.riders);
      map[userId] = updated;
      activeConvoy = activeConvoy!.copyWith(riders: map);
      notifyListeners();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeRouteEssentialsService extends ChangeNotifier implements RouteEssentialsService {
  @override
  List<RouteEssential> upcoming = [];

  @override
  double progressM = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RiderModel makeRider(String id, String name, {String reason = ''}) {
  return RiderModel(
    userId: id,
    name: name,
    lat: 12.9716,
    lng: 77.5946,
    speedKmh: 45.0,
    statusReason: reason,
    lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
  );
}

ConvoyModel makeConvoy(RiderModel me) {
  return ConvoyModel(
    groupId: 'GRP-TEST-1',
    name: 'Western Ghats Ride',
    joinCode: '778899',
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

  Widget wrapWithTheme(Widget child) {
    return MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: Center(child: child),
      ),
    );
  }

  testWidgets('CockpitShortcutsDock renders all 5 glove-sized quick action buttons', (tester) async {
    final me = makeRider('rider_me', 'Eagle One');
    final convoy = makeConvoy(me);
    final rt = RealtimeService();
    final intercom = IntercomService(rt);

    await tester.pumpWidget(
      wrapWithTheme(
        CockpitShortcutsDock(
          convoy: convoy,
          me: me,
          intercomService: intercom,
          keepScreenOn: false,
          autoFollow: true,
          onToggleKeepScreenOn: () {},
          onToggleAutoFollow: () {},
          onEssentialsRadarTap: () {},
        ),
      ),
    );

    // Verify all 5 buttons exist
    expect(find.byKey(const Key('cockpit_dock_voice_toggle')), findsOneWidget);
    expect(find.byKey(const Key('cockpit_dock_stop_reason')), findsOneWidget);
    expect(find.byKey(const Key('cockpit_dock_essentials_radar')), findsOneWidget);
    expect(find.byKey(const Key('cockpit_dock_intercom_toggle')), findsOneWidget);
    expect(find.byKey(const Key('cockpit_dock_quick_settings')), findsOneWidget);

    // Verify glove touch target dimensions (>= 48dp)
    final voiceBtnSize = tester.getSize(find.byKey(const Key('cockpit_dock_voice_toggle')));
    expect(voiceBtnSize.width, greaterThanOrEqualTo(48.0));
    expect(voiceBtnSize.height, greaterThanOrEqualTo(48.0));

    final stopBtnSize = tester.getSize(find.byKey(const Key('cockpit_dock_stop_reason')));
    expect(stopBtnSize.width, greaterThanOrEqualTo(48.0));
    expect(stopBtnSize.height, greaterThanOrEqualTo(48.0));

    final radarBtnSize = tester.getSize(find.byKey(const Key('cockpit_dock_essentials_radar')));
    expect(radarBtnSize.width, greaterThanOrEqualTo(48.0));
    expect(radarBtnSize.height, greaterThanOrEqualTo(48.0));

    final intercomBtnSize = tester.getSize(find.byKey(const Key('cockpit_dock_intercom_toggle')));
    expect(intercomBtnSize.width, greaterThanOrEqualTo(48.0));
    expect(intercomBtnSize.height, greaterThanOrEqualTo(48.0));

    final settingsBtnSize = tester.getSize(find.byKey(const Key('cockpit_dock_quick_settings')));
    expect(settingsBtnSize.width, greaterThanOrEqualTo(48.0));
    expect(settingsBtnSize.height, greaterThanOrEqualTo(48.0));
  });

  testWidgets('Voice Mode Quick Toggle cycles (All Alerts <-> Critical SOS <-> Night Extra Loud) and triggers HUD toast', (tester) async {
    final me = makeRider('rider_me', 'Eagle One');
    final convoy = makeConvoy(me);
    final settings = SettingsService();
    await settings.load();

    final toasts = <String>[];

    await tester.pumpWidget(
      wrapWithTheme(
        CockpitShortcutsDock(
          convoy: convoy,
          me: me,
          settingsService: settings,
          keepScreenOn: false,
          autoFollow: true,
          onToggleKeepScreenOn: () {},
          onToggleAutoFollow: () {},
          onEssentialsRadarTap: () {},
          onHudToast: (msg, icon, [color]) => toasts.add(msg),
        ),
      ),
    );

    // Initial mode: All Alerts Spoken
    expect(find.byTooltip('Voice: All Alerts Spoken'), findsOneWidget);

    // Tap 1: Switches to Critical SOS Only
    await tester.tap(find.byKey(const Key('cockpit_dock_voice_toggle')));
    await tester.pump();
    expect(find.byTooltip('Voice: Critical SOS Only'), findsOneWidget);
    expect(toasts.last, 'Voice: Critical SOS Only');
    expect(settings.voiceAnnounceAllAlerts, isFalse);

    // Tap 2: Switches to Night Extra Loud
    await tester.tap(find.byKey(const Key('cockpit_dock_voice_toggle')));
    await tester.pump();
    expect(find.byTooltip('Voice: Night Extra Loud'), findsOneWidget);
    expect(toasts.last, 'Voice: Night Extra Loud');
    expect(settings.voiceAnnounceAllAlerts, isTrue);
    expect(settings.speakMoreAfterDark, isTrue);

    // Tap 3: Cycles back to All Alerts Spoken
    await tester.tap(find.byKey(const Key('cockpit_dock_voice_toggle')));
    await tester.pump();
    expect(find.byTooltip('Voice: All Alerts Spoken'), findsOneWidget);
    expect(toasts.last, 'Voice: All Alerts Spoken');
    expect(settings.speakMoreAfterDark, isFalse);
  });

  testWidgets('Quick Stop Reason Picker opens modal with 4 oversized buttons and broadcasts reason', (tester) async {
    final me = makeRider('rider_me', 'Eagle One');
    final convoyService = FakeConvoyService();
    convoyService.activeConvoy = makeConvoy(me);

    final toasts = <String>[];

    await tester.pumpWidget(
      wrapWithTheme(
        Builder(builder: (ctx) {
          return ElevatedButton(
            onPressed: () {
              QuickStopReasonModal.show(
                ctx,
                convoyService: convoyService,
                userId: me.userId,
                currentReason: me.statusReason,
                onBroadcast: (reason, label) => toasts.add('Broadcast: $label'),
              );
            },
            child: const Text('Open Stop Modal'),
          );
        }),
      ),
    );

    // Open modal
    await tester.tap(find.text('Open Stop Modal'));
    await tester.pumpAndSettle();

    // Verify 4 oversized buttons
    expect(find.byKey(const Key('stop_reason_fueling')), findsOneWidget);
    expect(find.byKey(const Key('stop_reason_rest_break')), findsOneWidget);
    expect(find.byKey(const Key('stop_reason_mechanical_tyre')), findsOneWidget);
    expect(find.byKey(const Key('stop_reason_phone_nav')), findsOneWidget);

    // Verify button touch size is oversized (>= 48dp)
    final fuelingSize = tester.getSize(find.byKey(const Key('stop_reason_fueling')));
    expect(fuelingSize.height, greaterThanOrEqualTo(60.0));

    // Tap 'Fueling'
    await tester.tap(find.byKey(const Key('stop_reason_fueling')));
    await tester.pumpAndSettle();

    // Modal is dismissed automatically
    expect(find.byKey(const Key('stop_reason_fueling')), findsNothing);

    // Verify broadcast occurred in convoyService
    expect(convoyService.statusUpdates.length, 1);
    expect(convoyService.statusUpdates.first.$2, 'FUELING');
    expect(convoyService.statusUpdates.first.$3, 'Fueling');
    expect(toasts.last, 'Broadcast: Fueling');
  });

  testWidgets('Quick Stop Reason Picker allows clearing stop reason when already stopped', (tester) async {
    final me = makeRider('rider_me', 'Eagle One', reason: 'REST_BREAK');
    final convoyService = FakeConvoyService();
    convoyService.activeConvoy = makeConvoy(me);

    final toasts = <String>[];

    await tester.pumpWidget(
      wrapWithTheme(
        Builder(builder: (ctx) {
          return ElevatedButton(
            onPressed: () {
              QuickStopReasonModal.show(
                ctx,
                convoyService: convoyService,
                userId: me.userId,
                currentReason: me.statusReason,
                onBroadcast: (reason, label) => toasts.add('Broadcast: $label'),
              );
            },
            child: const Text('Open Stop Modal'),
          );
        }),
      ),
    );

    await tester.tap(find.text('Open Stop Modal'));
    await tester.pumpAndSettle();

    // Clear stop button must be present when stopped
    expect(find.byKey(const Key('stop_reason_clear')), findsOneWidget);

    // Tap Clear Stop
    await tester.tap(find.byKey(const Key('stop_reason_clear')));
    await tester.pumpAndSettle();

    // Verify cleared in convoyService
    expect(convoyService.statusUpdates.length, 1);
    expect(convoyService.statusUpdates.first.$2, '');
    expect(convoyService.activeConvoy?.riders[me.userId]?.statusReason, '');
    expect(toasts.last, contains('Stop Cleared'));
  });

  testWidgets('Quick Essentials Radar Jump displays nearest essential and triggers jump callback', (tester) async {
    final me = makeRider('rider_me', 'Eagle One');
    final convoy = makeConvoy(me);
    final essentials = FakeRouteEssentialsService();
    essentials.progressM = 1000;
    essentials.upcoming = [
      const RouteEssential(
        placeId: 'hp_petrol_1',
        visitId: 'v1',
        name: 'HP Petrol Pump',
        category: 'FUEL',
        source: 'osm',
        lat: 12.98,
        lng: 77.60,
        routePositionM: 5200,
        entryM: 5100,
        exitM: 5300,
        accessDistanceM: 50,
        detourDistanceM: 100,
        detourDurationS: 60,
      ),
    ];

    bool jumped = false;

    await tester.pumpWidget(
      wrapWithTheme(
        CockpitShortcutsDock(
          convoy: convoy,
          me: me,
          essentialsService: essentials,
          keepScreenOn: false,
          autoFollow: true,
          onToggleKeepScreenOn: () {},
          onToggleAutoFollow: () {},
          onEssentialsRadarTap: () => jumped = true,
        ),
      ),
    );

    // Verify fuel icon is displayed on Radar button
    expect(
      find.descendant(
        of: find.byKey(const Key('cockpit_dock_essentials_radar')),
        matching: find.byIcon(Icons.local_gas_station_rounded),
      ),
      findsOneWidget,
    );

    // Tap Radar Jump button
    await tester.tap(find.byKey(const Key('cockpit_dock_essentials_radar')));
    await tester.pump();

    expect(jumped, isTrue);
  });

  testWidgets('Intercom Mic Mute / VOX Toggle rapidly toggles between Mute and VOX', (tester) async {
    final me = makeRider('rider_me', 'Eagle One');
    final convoy = makeConvoy(me);
    final rt = RealtimeService();
    final intercom = IntercomService(rt);
    intercom.setMode(IntercomMode.vox);

    final toasts = <String>[];

    await tester.pumpWidget(
      wrapWithTheme(
        CockpitShortcutsDock(
          convoy: convoy,
          me: me,
          intercomService: intercom,
          keepScreenOn: false,
          autoFollow: true,
          onToggleKeepScreenOn: () {},
          onToggleAutoFollow: () {},
          onEssentialsRadarTap: () {},
          onHudToast: (msg, icon, [color]) => toasts.add(msg),
        ),
      ),
    );

    // Initially VOX is unmuted
    expect(intercom.isMicMuted, isFalse);
    expect(find.byIcon(Icons.record_voice_over_rounded), findsOneWidget);

    // Tap: Mutes mic
    await tester.tap(find.byKey(const Key('cockpit_dock_intercom_toggle')));
    await tester.pump();
    expect(intercom.isMicMuted, isTrue);
    expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);
    expect(toasts.last, 'Intercom: Mic Muted');

    // Tap again: Unmutes mic and arms VOX
    await tester.tap(find.byKey(const Key('cockpit_dock_intercom_toggle')));
    await tester.pump();
    expect(intercom.isMicMuted, isFalse);
    expect(intercom.mode, IntercomMode.vox);
    expect(find.byIcon(Icons.record_voice_over_rounded), findsOneWidget);
    expect(toasts.last, 'Intercom: VOX Hands-free Active');
  });

  testWidgets('Glove Quick Settings Grid opens 2x3 grid and toggles in-flight rider settings', (tester) async {
    final settings = SettingsService();
    await settings.load();
    final rt = RealtimeService();
    final intercom = IntercomService(rt);

    bool screenOn = false;
    bool autoFollow = true;
    final toggles = <String, bool>{};

    await tester.pumpWidget(
      wrapWithTheme(
        Builder(builder: (ctx) {
          return ElevatedButton(
            onPressed: () {
              GloveQuickSettingsModal.show(
                ctx,
                settingsService: settings,
                intercomService: intercom,
                keepScreenOn: screenOn,
                autoFollow: autoFollow,
                onToggleKeepScreenOn: () => screenOn = !screenOn,
                onToggleAutoFollow: () => autoFollow = !autoFollow,
                onSettingToggled: (name, state) => toggles[name] = state,
              );
            },
            child: const Text('Open Settings Modal'),
          );
        }),
      ),
    );

    await tester.tap(find.text('Open Settings Modal'));
    await tester.pumpAndSettle();

    // Verify the 4 essential in-flight settings exist
    expect(find.byKey(const Key('quick_setting_voice_alerts')), findsOneWidget);
    expect(find.byKey(const Key('quick_setting_sunlight_mode')), findsOneWidget);
    expect(find.byKey(const Key('quick_setting_battery_conserve')), findsOneWidget);
    expect(find.byKey(const Key('quick_setting_screen_always_on')), findsOneWidget);

    // Verify touch target dimensions are glove-friendly (>= 56 dp)
    final voiceCardSize = tester.getSize(find.byKey(const Key('quick_setting_voice_alerts')));
    expect(voiceCardSize.height, greaterThanOrEqualTo(56.0));

    // Toggle Voice Alerts
    await tester.tap(find.byKey(const Key('quick_setting_voice_alerts')));
    await tester.pump();
    expect(toggles['Voice Alerts'], isFalse);

    // Toggle Screen Always On
    await tester.tap(find.byKey(const Key('quick_setting_screen_always_on')));
    await tester.pump();
    expect(screenOn, isTrue);

    // Toggle Battery Conserve
    await tester.tap(find.byKey(const Key('quick_setting_battery_conserve')));
    await tester.pump();
    expect(toggles['Battery Conserve'], isTrue);

    // Close with Done
    await tester.ensureVisible(find.byKey(const Key('quick_settings_done')));
    await tester.tap(find.byKey(const Key('quick_settings_done')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quick_setting_voice_alerts')), findsNothing);
  });

  testWidgets('CockpitHudToast renders high-contrast glowing feedback with ZERO raw emojis and ASCII hyphens', (tester) async {
    const testMsg = 'Voice: Critical SOS Only';

    await tester.pumpWidget(
      wrapWithTheme(
        CockpitHudToast(
          message: testMsg,
          icon: Icons.warning_amber_rounded,
          color: const Color(0xFFFFB300),
        ),
      ),
    );

    expect(find.text(testMsg), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

    // Strict CoRoute Standards: Zero raw emojis, ASCII hyphens only
    final textFinder = find.byType(Text);
    for (final element in textFinder.evaluate()) {
      final widget = element.widget as Text;
      final content = widget.data ?? '';
      // No raw emojis
      expect(content.contains(RegExp(r'[\u{1F300}-\u{1FAFF}]', unicode: true)), isFalse);
      // No en-dash or em-dash
      expect(content.contains('\u2013'), isFalse);
      expect(content.contains('\u2014'), isFalse);
    }
  });

  testWidgets('Strict CoRoute Standards: ZERO raw emojis and ZERO unicode dashes across all shortcut components', (tester) async {
    final me = makeRider('rider_me', 'Eagle One');
    final convoy = makeConvoy(me);
    final convoyService = FakeConvoyService();
    convoyService.activeConvoy = convoy;
    final settings = SettingsService();
    await settings.load();

    await tester.pumpWidget(
      wrapWithTheme(
        CockpitShortcutsDock(
          convoy: convoy,
          me: me,
          settingsService: settings,
          keepScreenOn: false,
          autoFollow: true,
          onToggleKeepScreenOn: () {},
          onToggleAutoFollow: () {},
          onEssentialsRadarTap: () {},
        ),
      ),
    );

    // Inspect all Text widgets in the dock
    for (final element in find.byType(Text).evaluate()) {
      final textWidget = element.widget as Text;
      final text = textWidget.data ?? '';
      expect(text.contains(RegExp(r'[\u{1F300}-\u{1FAFF}]', unicode: true)), isFalse, reason: 'Must not contain emoji: $text');
      expect(text.contains('\u2013'), isFalse, reason: 'Must not contain en-dash: $text');
      expect(text.contains('\u2014'), isFalse, reason: 'Must not contain em-dash: $text');
    }
  });

  testWidgets('CockpitShortcutsDock renders Ride Guardian and Fuel quick shortcuts with glove targets', (tester) async {
    final me = makeRider('rider_me', 'Eagle One');
    final convoy = makeConvoy(me);
    final settings = SettingsService();
    await settings.load();

    await tester.pumpWidget(
      wrapWithTheme(
        CockpitShortcutsDock(
          convoy: convoy,
          me: me,
          settingsService: settings,
          keepScreenOn: false,
          autoFollow: true,
          onToggleKeepScreenOn: () {},
          onToggleAutoFollow: () {},
          onEssentialsRadarTap: () {},
        ),
      ),
    );

    // Verify Guardian and Fuel buttons exist in the dock
    expect(find.byKey(const Key('cockpit_dock_guardian')), findsOneWidget);
    expect(find.byKey(const Key('cockpit_dock_fuel')), findsOneWidget);

    // Verify glove touch targets >= 48dp
    final guardianSize = tester.getSize(find.byKey(const Key('cockpit_dock_guardian')));
    expect(guardianSize.width, greaterThanOrEqualTo(48.0));
    expect(guardianSize.height, greaterThanOrEqualTo(48.0));

    final fuelSize = tester.getSize(find.byKey(const Key('cockpit_dock_fuel')));
    expect(fuelSize.width, greaterThanOrEqualTo(48.0));
    expect(fuelSize.height, greaterThanOrEqualTo(48.0));
  });

  testWidgets('GloveQuickSettingsModal renders Guardian and Fuel action buttons', (tester) async {
    FeatureGates.activeTier = SubscriptionTier.proRider;
    addTearDown(() => FeatureGates.activeTier = SubscriptionTier.community);
    final settings = SettingsService();
    await settings.load();

    bool guardianOpened = false;
    bool fuelOpened = false;

    await tester.pumpWidget(
      wrapWithTheme(
        Builder(builder: (ctx) {
          return ElevatedButton(
            onPressed: () {
              GloveQuickSettingsModal.show(
                ctx,
                settingsService: settings,
                keepScreenOn: false,
                autoFollow: true,
                onToggleKeepScreenOn: () {},
                onToggleAutoFollow: () {},
                onOpenGuardian: () => guardianOpened = true,
                onOpenFuel: () => fuelOpened = true,
              );
            },
            child: const Text('Open Modal'),
          );
        }),
      ),
    );

    await tester.tap(find.text('Open Modal'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quick_action_guardian_share')), findsOneWidget);
    expect(find.byKey(const Key('quick_action_fuel_sheet')), findsOneWidget);

    // Tap Guardian button
    await tester.ensureVisible(find.byKey(const Key('quick_action_guardian_share')));
    await tester.tap(find.byKey(const Key('quick_action_guardian_share')));
    await tester.pumpAndSettle();
    expect(guardianOpened, isTrue);

    // Reopen and tap Fuel button
    await tester.tap(find.text('Open Modal'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('quick_action_fuel_sheet')));
    await tester.tap(find.byKey(const Key('quick_action_fuel_sheet')));
    await tester.pumpAndSettle();
    expect(fuelOpened, isTrue);
  });
}
