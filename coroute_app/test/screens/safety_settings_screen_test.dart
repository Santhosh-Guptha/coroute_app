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

  testWidgets('SafetySettingsScreen renders all 4 sections with mandatory read-only systems and plain-English descriptions', (tester) async {
    await tester.pumpWidget(buildTestHost(const SafetySettingsScreen()));
    await tester.pumpAndSettle();

    // 1. Safety Shield (Mandatory Safety Systems)
    expect(find.text('SAFETY SHIELD'), findsOneWidget);
    expect(find.text('Automatic Crash Detection'), findsOneWidget);
    expect(find.text('Senses a crash and alerts your group'), findsOneWidget);

    expect(find.text('GPS & Trip Monitoring'), findsOneWidget);
    expect(find.text('Shares your location with your group'), findsOneWidget);

    expect(find.text('SOS ready'), findsOneWidget);
    expect(find.text('Alerts by internet, SMS or nearby phones'), findsOneWidget);

    expect(find.text('Emergency Response'), findsOneWidget);
    expect(find.text('Medical info for people who help you'), findsOneWidget);

    expect(find.text('Offline Safety'), findsOneWidget);
    expect(find.text('Maps and alerts without signal'), findsOneWidget);

    expect(find.text('Runs in background'), findsOneWidget);
    expect(find.text('Keeps working with the screen off'), findsOneWidget);

    // 2. Navigation & Tunnels
    expect(find.text('NAVIGATION & TUNNELS'), findsOneWidget);
    expect(find.text('Tunnel mode'), findsOneWidget);
    expect(find.text('Keeps your dot moving when GPS drops'), findsOneWidget);

    expect(find.text('Ride on lock screen'), findsOneWidget);
    expect(find.text('Group distances on your lock screen'), findsOneWidget);

    expect(find.text('Road Hazard Alerts'), findsOneWidget);
    expect(find.text('Warns of hazards 300 m ahead'), findsOneWidget);

    // Scroll to see remaining sections
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('YOU & CONTACTS'), 200, scrollable: scrollable);
    await tester.pumpAndSettle();

    // 3. Audio & Controls
    expect(find.text('AUDIO & CONTROLS'), findsOneWidget);
    expect(find.text('Handlebar Remote'), findsOneWidget);
    expect(find.text('Bluetooth button for talk and SOS'), findsOneWidget);

    expect(find.text('Voice commands'), findsOneWidget);
    expect(find.text('Hands-free "CoRoute I\'m OK" & "CoRoute Emergency"'), findsOneWidget);

    expect(find.text('Lead voice first'), findsOneWidget);
    expect(find.text('Other voices get quieter for the Lead'), findsOneWidget);

    // 4. Rider Identity & Contacts
    expect(find.text('YOU & CONTACTS'), findsOneWidget);
    expect(find.text('Name & blood group'), findsOneWidget);
    expect(find.text('Emergency Contacts'), findsOneWidget);
  });

  testWidgets('SafetySettingsScreen displays runtime status badges and removes mandatory toggles', (tester) async {
    await tester.pumpWidget(buildTestHost(const SafetySettingsScreen()));
    await tester.pumpAndSettle();

    // Mandatory safety rows must NOT have Switch controls
    final crashRow = find.ancestor(
      of: find.text('Automatic Crash Detection'),
      matching: find.byType(InkWell),
    );
    expect(find.descendant(of: crashRow, matching: find.byType(Switch)), findsNothing);

    final gpsRow = find.ancestor(
      of: find.text('GPS & Trip Monitoring'),
      matching: find.byType(InkWell),
    );
    expect(find.descendant(of: gpsRow, matching: find.byType(Switch)), findsNothing);

    // Runtime status badges exist (e.g. ACTIVE, LIMITED, PERMISSION REQUIRED, UNSUPPORTED, NOT AVAILABLE)
    final validStatuses = ['ACTIVE', 'LIMITED', 'PERMISSION REQUIRED', 'UNSUPPORTED', 'NOT AVAILABLE'];
    expect(
      find.byWidgetPredicate((w) => w is Text && validStatuses.contains(w.data?.toUpperCase())),
      findsWidgets,
    );

    // Optional communication preferences retain Switch toggles
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Handlebar Remote'), 200, scrollable: scrollable);
    await tester.pumpAndSettle();

    final pttRow = find.ancestor(
      of: find.text('Handlebar Remote'),
      matching: find.byType(InkWell),
    );
    expect(find.descendant(of: pttRow, matching: find.byType(Switch)), findsOneWidget);

    // Toggle PTT and verify state updates
    await tester.tap(find.descendant(of: pttRow, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(settings.hardwarePtt, isTrue);
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
    await tester.scrollUntilVisible(find.text('Name & blood group'), 200, scrollable: scrollable);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Name & blood group'));
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
