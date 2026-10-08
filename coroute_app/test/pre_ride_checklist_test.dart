import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/app_constants.dart';
import 'package:coroute_app/data/services/permissions_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/presentation/safety/safety_settings_sheet.dart';
import 'package:coroute_app/presentation/widgets/pre_ride_checklist_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const perms = [
    PermissionItem(key: 'location', title: 'l', reason: '', required: true, granted: true),
    PermissionItem(key: 'locationAlways', title: 'a', reason: '', required: true, granted: false),
    PermissionItem(key: 'microphone', title: 'm', reason: '', required: false, granted: false),
    PermissionItem(key: 'notification', title: 'n', reason: '', required: false, granted: true),
    PermissionItem(key: 'battery', title: 'b', reason: '', required: false, granted: false),
  ];

  test('automatic checks: what needs attention and what is info only', () {
    final checks = PreRideChecklist.checksFrom(permissions: perms, batteryLevel: 22, hasEmergencyContact: false);
    final byKey = {for (final c in checks) c.key: c};
    expect(byKey['locationAlways']!.ok, isFalse);
    expect(byKey['notification']!.ok, isTrue);
    expect(byKey['batteryLevel']!.ok, isFalse, reason: 'below 30 percent');
    expect(byKey['battery']!.ok, isFalse);
    expect(byKey['emergencyContact']!.fix, 'profile');
    expect(byKey['microphone']!.infoOnly, isTrue);
    final charging = PreRideChecklist.checksFrom(permissions: const [], batteryLevel: 10, isCharging: true);
    expect(charging.single.ok, isTrue);
    expect(PreRideChecklist.checksFrom(permissions: const []), isEmpty);
  });

  test('"do not show for 24 hours" expires', () async {
    SharedPreferences.setMockInitialValues({});
    const t0 = 1700000000000;
    expect(await PreRideChecklist.skipActive(nowMs: t0), isFalse);
    await PreRideChecklist.skipFor24Hours(nowMs: t0);
    expect(await PreRideChecklist.skipActive(nowMs: t0 + 3600000), isTrue);
    expect(await PreRideChecklist.skipActive(nowMs: t0 + AppConstants.checklistSkipFor.inMilliseconds + 1), isFalse);
  });

  Future<void> smallPhone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget host(Widget child) => MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.2)),
            child: child,
          ),
        ),
      );

  testWidgets('fits a 320 x 568 screen at text scale 1.2; every item is reachable by scrolling', (tester) async {
    await smallPhone(tester);
    final checks = PreRideChecklist.checksFrom(permissions: perms, batteryLevel: 22, hasEmergencyContact: false);
    await tester.pumpWidget(host(Scaffold(body: PreRideChecklistSheet(checks: checks))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Before you ride'), findsOneWidget);
    expect(find.text('Start the ride'), findsOneWidget, reason: 'the start button is always visible');
    expect(find.text('Fix'), findsWidgets);
    final list = find.byType(Scrollable).first;
    for (final item in [...PreRideChecklist.manualItems, 'Do not show for 24 hours']) {
      await tester.scrollUntilVisible(find.text(item), 60, scrollable: list);
      expect(find.text(item), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('"Start the ride" continues, also with nothing ticked; the skip is saved', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await smallPhone(tester);
    bool? result;
    await tester.pumpWidget(host(Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await PreRideChecklistSheet.show(context),
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Before you ride'), findsOneWidget);
    final list = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(find.text('Do not show for 24 hours'), 60, scrollable: list);
    await tester.drag(list, const Offset(0, -60));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Do not show for 24 hours'));
    await tester.pump();
    await tester.tap(find.text('Start the ride'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(await PreRideChecklist.skipActive(), isTrue);

    // Skipped: the next ride starts at once, without the sheet.
    result = null;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Before you ride'), findsNothing);
    expect(result, isTrue);
  });

  test('safety rows: lock-screen alarm (Android 14) and the brand battery guide until seen', () {
    final withSafety = [
      ...perms,
      const PermissionItem(key: 'sms', title: 's', reason: '', required: false, granted: false),
      const PermissionItem(key: 'fullScreen', title: 'f', reason: '', required: false, granted: false),
    ];
    final checks = PreRideChecklist.checksFrom(permissions: withSafety, manufacturer: 'Xiaomi', oemGuideSeen: false);
    final byKey = {for (final c in checks) c.key: c};
    expect(byKey['fullScreen']!.title, 'Alarm on lock screen');
    expect(byKey['fullScreen']!.fix, 'fullScreen');
    expect(byKey['oemGuide']!.title, 'Battery settings for Xiaomi');
    expect(byKey['oemGuide']!.fix, 'oemGuide');
    expect(byKey.containsKey('sms'), isFalse, reason: 'SMS is a switch with its own explanation, not a check');
    final seen = PreRideChecklist.checksFrom(permissions: withSafety, manufacturer: 'Xiaomi', oemGuideSeen: true);
    expect(seen.any((c) => c.key == 'oemGuide'), isFalse);
    final noBrand = PreRideChecklist.checksFrom(permissions: perms, oemGuideSeen: false);
    expect(noBrand.any((c) => c.key == 'oemGuide' || c.key == 'fullScreen'), isFalse, reason: 'not Android 14, not Android');
  });

  testWidgets('crash detection and "Text the group" switches; switching texts on asks for SMS first', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await smallPhone(tester);
    final settings = SettingsService();
    await settings.load();
    final asked = <String>[];
    var grant = false;
    final checks = PreRideChecklist.checksFrom(permissions: perms, batteryLevel: 80, hasEmergencyContact: true);
    await tester.pumpWidget(ChangeNotifierProvider<SettingsService>.value(
      value: settings,
      child: host(Scaffold(
        body: PreRideChecklistSheet(
          checks: checks,
          requestPermission: (key) async {
            asked.add(key);
            return grant;
          },
        ),
      )),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text(SafetyTexts.crashTitle), 60, scrollable: list);
    expect(find.text('Ride safety'), findsOneWidget);
    expect(find.textContaining('nothing is sent'), findsOneWidget);
    await tester.scrollUntilVisible(find.text(SafetyTexts.smsTitle), 60, scrollable: list);
    expect(find.textContaining('up to 10'), findsOneWidget);
    expect(find.textContaining('only during the ride'), findsOneWidget);

    await tester.tap(find.text(SafetyTexts.smsTitle));
    await tester.pump();
    expect(asked, ['sms']);
    expect(settings.smsFallback, isFalse);
    await tester.scrollUntilVisible(find.text(SafetyTexts.smsDenied), 60, scrollable: list);
    expect(find.text(SafetyTexts.smsDenied), findsOneWidget);

    grant = true;
    await tester.scrollUntilVisible(find.text(SafetyTexts.smsTitle), -60, scrollable: list);
    await tester.tap(find.text(SafetyTexts.smsTitle));
    await tester.pump();
    expect(settings.smsFallback, isTrue);

    // Off again: no permission question.
    await tester.tap(find.text(SafetyTexts.smsTitle));
    await tester.pump();
    expect(settings.smsFallback, isFalse);
    expect(asked, ['sms', 'sms']);

    await tester.scrollUntilVisible(find.text(SafetyTexts.crashTitle), -60, scrollable: list);
    await tester.drag(list, const Offset(0, 150));
    await tester.pump();
    expect(settings.crashDetection, isTrue);
    await tester.tap(find.text(SafetyTexts.crashTitle));
    await tester.pump();
    expect(settings.crashDetection, isFalse);
    expect(tester.takeException(), isNull);
  });
}
