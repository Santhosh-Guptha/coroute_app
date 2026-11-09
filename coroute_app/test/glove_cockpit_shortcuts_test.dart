import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/presentation/rider/widgets/cockpit_hud_toast.dart';
import 'package:coroute_app/presentation/rider/widgets/glove_quick_settings_modal.dart';




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







  testWidgets('Glove Quick Settings Grid opens 2x3 grid and toggles in-flight rider settings', (tester) async {
    final settings = SettingsService();
    await settings.load();
    final rt = RealtimeService();
    final intercom = IntercomService(rt);
    intercom.setMicMuted(false);

    bool screenOn = false;
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
                onToggleKeepScreenOn: () => screenOn = !screenOn,
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

    // 3.55: the 3 in-ride quick settings: voice, night map, battery saver (the screen always stays on).
    expect(find.byKey(const Key('quick_setting_voice_alerts')), findsOneWidget);
    expect(find.byKey(const Key('quick_setting_night_map')), findsOneWidget);
    expect(find.byKey(const Key('quick_setting_battery_saver')), findsOneWidget);
    expect(find.byKey(const Key('quick_setting_screen_always_on')), findsNothing);

    // Verify touch target dimensions are glove-friendly (big tiles, >= 96 dp tall)
    final voiceCardSize = tester.getSize(find.byKey(const Key('quick_setting_voice_alerts')));
    expect(voiceCardSize.height, greaterThanOrEqualTo(96.0));
    expect(voiceCardSize.width, greaterThanOrEqualTo(80.0));

    // Toggle Voice Alerts
    await tester.tap(find.byKey(const Key('quick_setting_voice_alerts')));
    await tester.pump();
    expect(toggles['Voice'], isFalse);
    expect(settings.voiceWarnings, isFalse);

    // Toggle Battery saver (the same switch as in Settings)
    await tester.tap(find.byKey(const Key('quick_setting_battery_saver')));
    await tester.pump();
    expect(toggles['Battery saver'], isTrue);
    expect(settings.batterySaver, isTrue);

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



  testWidgets('GloveQuickSettingsModal renders Guardian and Fuel action buttons', (tester) async {
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
                onToggleKeepScreenOn: () {},
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
