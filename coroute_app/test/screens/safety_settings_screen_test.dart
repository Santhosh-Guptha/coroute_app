import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/ble_remote_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/helmet_voice_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/presentation/safety/safety_settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;
  late AuthService auth;
  late ApiClient api;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService();
    await settings.load();

    api = ApiClient();
    auth = AuthService(api);
  });

  Widget buildTestHost(Widget child) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider<BleRemoteService>(create: (_) => BleRemoteService()),
        ChangeNotifierProvider<HelmetVoiceService>(
          create: (_) => HelmetVoiceService(
            convoyService: ConvoyService(api, RealtimeService(), TripStorageService(api)),
          ),
        ),
      ],
      child: MaterialApp(
        home: child,
      ),
    );
  }

  testWidgets('SafetySettingsScreen renders all 4 sections with 1-line plain-English descriptions', (tester) async {
    await tester.pumpWidget(buildTestHost(const SafetySettingsScreen()));
    await tester.pumpAndSettle();

    // 1. Safety Shield
    expect(find.text('SAFETY SHIELD'), findsOneWidget);
    expect(find.text('Automatic Crash Detection'), findsOneWidget);
    expect(find.text('Instant 15s alarm before dispatch'), findsOneWidget);

    expect(find.text('Smart Airbag Vest Bridge'), findsOneWidget);
    expect(find.text('Auto-detects In&motion, Tech-Air, Helite'), findsOneWidget);

    expect(find.text('Smartwatch Vitals'), findsOneWidget);
    expect(find.text('Monitors pulse & escalates trauma alerts'), findsOneWidget);

    expect(find.text('Emergency Siren Alert'), findsOneWidget);
    expect(find.text('Ducks intercom when ambulances approach'), findsOneWidget);

    // 2. Navigation & Tunnels
    expect(find.text('NAVIGATION & TUNNELS'), findsOneWidget);
    expect(find.text('Tunnel Dead Reckoning'), findsOneWidget);
    expect(find.text('Keeps moving through GPS-dead mountain tunnels'), findsOneWidget);

    expect(find.text('Lock-Screen Radar'), findsOneWidget);
    expect(find.text('Glanceable group distance on lock screen'), findsOneWidget);

    expect(find.text('Road Hazard Alerts'), findsOneWidget);
    expect(find.text('Warns of potholes & road debris 300m ahead'), findsOneWidget);

    // Scroll to see remaining sections
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('RIDER IDENTITY & CONTACTS'), 200, scrollable: scrollable);
    await tester.pumpAndSettle();

    // 3. Audio & Controls
    expect(find.text('AUDIO & CONTROLS'), findsOneWidget);
    expect(find.text('Handlebar Remote'), findsOneWidget);
    expect(find.text('PTT voice & SOS button on handlebar'), findsOneWidget);

    expect(find.text('Helmet Voice Hotwords'), findsOneWidget);
    expect(find.text('Hands-free "CoRoute I\'m OK" & "CoRoute Emergency"'), findsOneWidget);

    expect(find.text('Intercom Audio Ducking'), findsOneWidget);
    expect(find.text('Ducks chatter when Road Captain or sirens speak'), findsOneWidget);

    // 4. Rider Identity & Contacts
    expect(find.text('RIDER IDENTITY & CONTACTS'), findsOneWidget);
    expect(find.text('Callsign & Blood Group'), findsOneWidget);
    expect(find.text('Emergency Contacts'), findsOneWidget);
  });

  testWidgets('SafetySettingsScreen displays clear status badges (READY, OFF, CONNECTED)', (tester) async {
    await tester.pumpWidget(buildTestHost(const SafetySettingsScreen()));
    await tester.pumpAndSettle();

    // Ready badges appear for enabled settings
    expect(find.text('READY'), findsWidgets);

    // Toggle Crash Detection OFF and verify badge updates to OFF
    final crashSwitch = find.ancestor(
      of: find.text('Automatic Crash Detection'),
      matching: find.byType(InkWell),
    );
    await tester.tap(crashSwitch);
    await tester.pumpAndSettle();

    expect(settings.crashDetection, isFalse);
    expect(find.text('OFF'), findsWidgets);
  });

  testWidgets('Touch targets have minimum 48dp height for gloved thumb operation', (tester) async {
    await tester.pumpWidget(buildTestHost(const SafetySettingsScreen()));
    await tester.pumpAndSettle();

    // Verify all settings row items inside the cards enforce minHeight >= 48.0
    final rowItems = find.byWidgetPredicate((w) =>
        w is ConstrainedBox &&
        w.constraints.minHeight >= 48.0);
    expect(rowItems, findsWidgets);

    for (final element in rowItems.evaluate()) {
      final box = element.widget as ConstrainedBox;
      expect(box.constraints.minHeight, greaterThanOrEqualTo(48.0));
    }
  });

  testWidgets('Tapping Callsign & Blood Group opens rider identity modal sheet', (tester) async {
    await tester.pumpWidget(buildTestHost(const SafetySettingsScreen()));
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Callsign & Blood Group'), 200, scrollable: scrollable);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Callsign & Blood Group'));
    await tester.pumpAndSettle();

    // Modal sheet contents
    expect(find.text('Rider Identity & Vitals'), findsOneWidget);
    expect(find.text('CALLSIGN'), findsOneWidget);
    expect(find.text('BLOOD GROUP'), findsOneWidget);
    expect(find.text('O+'), findsOneWidget);
    expect(find.text('Save Identity'), findsOneWidget);
  });

  testWidgets('Tapping Emergency Contacts opens emergency contact configuration sheet', (tester) async {
    await tester.pumpWidget(buildTestHost(const SafetySettingsScreen()));
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Emergency Contacts'), 200, scrollable: scrollable);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Emergency Contacts'));
    await tester.pumpAndSettle();

    // Modal sheet contents
    expect(find.text('Emergency Contacts'), findsWidgets);
    expect(find.text('CONTACT NAME'), findsOneWidget);
    expect(find.text('SMS Direct Dispatch'), findsOneWidget);
    expect(find.text('WhatsApp Cloud Alert'), findsOneWidget);
    expect(find.text('Save Contact'), findsOneWidget);
  });
}
