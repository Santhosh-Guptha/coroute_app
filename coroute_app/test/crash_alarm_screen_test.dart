import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/core/l10n/l10n.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/emergency_roster.dart';
import 'package:coroute_app/data/models/pending_sos.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/services/accel_source.dart';
import 'package:coroute_app/data/services/safety_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/sms_sender.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/crash_detector.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';
import 'package:coroute_app/presentation/safety/crash_alarm_host.dart';
import 'package:coroute_app/presentation/safety/crash_alarm_screen.dart';
import 'package:coroute_app/presentation/safety/oem_battery_guide.dart';
import 'package:coroute_app/presentation/safety/safety_settings_sheet.dart';
import 'package:coroute_app/presentation/safety/sos_hold_screen.dart';
import 'package:coroute_app/core/ui/sos_button.dart';

class _Port extends ChangeNotifier implements SafetyPort {
  final StreamController<TrackPoint> fixes = StreamController<TrackPoint>.broadcast();
  final List<String> raised = [];
  @override
  Stream<TrackPoint> get myFixes => fixes.stream;
  @override
  ConvoyModel? get activeConvoy => ConvoyModel(
        groupId: 'G',
        name: 'Ride',
        joinCode: '123456',
        createdByUserId: 'lead',
        createdByUserName: 'Lead',
        createdAtEpochMs: 0,
      );
  @override
  String? get myUserId => 'me';
  @override
  String get myName => 'Kiran';
  @override
  String? get myPhone => null;
  @override
  bool get rideActive => true;
  @override
  bool get hasOpenSos => raised.isNotEmpty;
  @override
  PendingSos? get pendingSos => null;
  @override
  EmergencyRoster? get emergencyRoster => null;
  @override
  RosterContact? get myEmergencyContact => null;
  @override
  SosDelivery raiseSos({
    required String type,
    required double lat,
    required double lng,
    bool auto = false,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAtMs,
  }) {
    raised.add(type);
    return SosDelivery.queued;
  }

  @override
  bool sendCheckIn(CheckInResult result, {double? awayM}) => true;
}

class _NoAccel implements AccelSource {
  @override
  Stream<AccelBucket> buckets({int samplingUs = SafetyConstants.accelSamplingUs, int maxLatencyUs = SafetyConstants.accelMaxLatencyUs}) =>
      const Stream<AccelBucket>.empty();
}

class _NoSms implements SmsSender {
  @override
  Future<SmsCapability> capability() async => SmsCapability.none;
  @override
  Future<SmsStatus> send(String to, String body) async => SmsStatus.failed;
}

void main() {
  Future<void> screen(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget host(Widget child, AppPalette palette) {
    AppTheme.use(palette);
    return MaterialApp(
      theme: AppTheme.themeFor(palette),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child,
        ),
      ),
    );
  }

  for (final palette in [AppPalette.dark, AppPalette.light]) {
    for (final size in [const Size(320, 568), const Size(568, 320)]) {
      final where = '${palette == AppPalette.dark ? 'dark' : 'light'} ${size.width.round()}x${size.height.round()}';
      testWidgets('countdown screen fits at 320 dp, text x1.3 ($where)', (tester) async {
        await screen(tester, size);
        var ok = 0, send = 0;
        await tester.pumpWidget(host(
          CrashAlarmView(secondsLeft: 27, onImOk: () => ok++, onSendNow: () => send++),
          palette,
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text(CrashAlarmView.title), findsOneWidget);
        expect(find.text('Sending SOS to your group in 27 seconds.'), findsOneWidget);
        expect(find.text('Automatic alert'), findsOneWidget);
        final okButton = find.text('I\'m OK');
        final sendButton = find.text('Need Help');
        await tester.ensureVisible(okButton);
        final okBox = find.ancestor(of: okButton, matching: find.byWidgetPredicate((w) => w is FilledButton));
        expect(tester.getSize(okBox).height, greaterThanOrEqualTo(CrashAlarmView.buttonHeight));
        final sendBox = find.ancestor(of: sendButton, matching: find.byWidgetPredicate((w) => w is FilledButton));
        expect(tester.getSize(sendBox).height, greaterThanOrEqualTo(CrashAlarmView.buttonHeight));
        await tester.tap(okButton);
        await tester.ensureVisible(sendButton);
        await tester.pump();
        await tester.tap(sendButton);
        expect(ok, 1);
        expect(send, 1);
        AppTheme.use(AppPalette.dark);
      });
    }
  }

  testWidgets('screen reader: title, countdown and both buttons are announced', (tester) async {
    final handle = tester.ensureSemantics();
    await screen(tester, const Size(360, 740));
    await tester.pumpWidget(host(CrashAlarmView(secondsLeft: 1, onImOk: () {}, onSendNow: () {}), AppPalette.dark));
    expect(find.bySemanticsLabel(CrashAlarmView.title), findsOneWidget);
    expect(find.text('Sending SOS to your group in 1 second.'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('I\'m OK')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('Need Help')), findsWidgets);
    handle.dispose();
  });

  testWidgets('the host pushes the alarm screen when the alarm opens and removes it on I\'m OK', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.load();
    final port = _Port();
    var now = 1700000000000;
    final safety = SafetyService.forTest(port, settings, accel: _NoAccel(), sms: _NoSms(), clock: () => now);
    final nav = GlobalKey<NavigatorState>();
    await screen(tester, const Size(360, 740));
    await tester.pumpWidget(ChangeNotifierProvider<SafetyService>.value(
      value: safety,
      child: MaterialApp(
        navigatorKey: nav,
        builder: (context, child) => CrashAlarmHost(navigatorKey: nav, child: child ?? const SizedBox.shrink()),
        home: const Scaffold(body: Text('Ride screen')),
      ),
    ));
    await tester.pump();
    expect(find.text(CrashAlarmView.title), findsNothing);

    safety.debugRaiseCrash(const CrashEvent(impactAtMs: 1700000000000, impactG: 6, speedBeforeKmh: 50, lat: 12.97, lng: 77.59));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(CrashAlarmView.title), findsOneWidget);

    now += 5000;
    await tester.pump(const Duration(seconds: 1));
    final left = SafetyConstants.crashCountdown.inSeconds - 5;
    expect(find.textContaining('in $left seconds'), findsOneWidget);

    await tester.tap(find.text('I\'m OK'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(CrashAlarmView.title), findsNothing);
    expect(find.text('Ride screen'), findsOneWidget);
    expect(port.raised, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    safety.dispose();
    port.dispose();
  });

  testWidgets('safety settings sheet: ride safety, accident warnings, voice and notification switches; SMS asks for the permission first', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.load();
    await screen(tester, const Size(320, 640));
    final asked = <String>[];
    var grant = false;
    await tester.pumpWidget(ChangeNotifierProvider<SettingsService>.value(
      value: settings,
      child: host(
        Scaffold(
          body: SafetySettingsSheet(requestPermission: (key) async {
            asked.add(key);
            return grant;
          }),
        ),
        AppPalette.dark,
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // 4 ride safety + documents reminder + accident warnings + 3 voice + 3 notification + route maps
    // (the nearby riders switches need AuthService).
    expect(find.byType(Switch), findsNWidgets(13));
    expect(find.text(SafetyTexts.crashTitle), findsOneWidget);
    await tester.tap(find.text(SafetyTexts.smsTitle));
    await tester.pump();
    expect(asked, ['sms']);
    expect(settings.smsFallback, isFalse, reason: 'permission refused');
    expect(find.text(SafetyTexts.smsDenied), findsOneWidget);
    grant = true;
    await tester.tap(find.text(SafetyTexts.smsTitle));
    await tester.pump();
    expect(settings.smsFallback, isTrue);
    await tester.tap(find.text(SafetyTexts.crashTitle));
    await tester.pump();
    expect(settings.crashDetection, isFalse);
    expect(SafetySettingsSheet.summary(settings), 'Texts, break reminder, check-in on');
  });

  for (final lang in [AppLanguage.hi, AppLanguage.te]) {
    for (final size in [const Size(320, 568), const Size(568, 320)]) {
      testWidgets('countdown screen in ${lang.code} at ${size.width.round()}x${size.height.round()} x1.3: translated, no overflow', (tester) async {
        L10n.setLanguage(lang);
        addTearDown(() => L10n.setLanguage(AppLanguage.system));
        await screen(tester, size);
        await tester.pumpWidget(host(CrashAlarmView(secondsLeft: 27, onImOk: () {}, onSendNow: () {}), AppPalette.dark));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text(L10n.t('crash.title', const {}, lang.code)), findsOneWidget);
        expect(find.text(L10n.t('crash.ok', const {}, lang.code)), findsOneWidget);
        expect(find.text(L10n.t('crash.help', const {}, lang.code)), findsOneWidget);
        expect(find.text(L10n.t('crash.countdown', {'n': 27}, lang.code)), findsOneWidget);
        expect(find.text('Possible accident detected. Are you okay?'), findsNothing);
      });
    }
  }

  testWidgets('countdown screen switches language at once when the setting changes', (tester) async {
    L10n.setLanguage(AppLanguage.system);
    addTearDown(() => L10n.setLanguage(AppLanguage.system));
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    await settings.load();
    final port = _Port();
    final safety = SafetyService.forTest(port, settings, accel: _NoAccel(), sms: _NoSms(), clock: () => 1700000000000);
    await screen(tester, const Size(360, 740));
    await tester.pumpWidget(ChangeNotifierProvider<SafetyService>.value(value: safety, child: host(const CrashAlarmScreen(), AppPalette.dark)));
    safety.debugRaiseCrash(const CrashEvent(impactAtMs: 1700000000000, impactG: 6, speedBeforeKmh: 50, lat: 12.97, lng: 77.59));
    await tester.pump();
    expect(find.text('Possible accident detected. Are you okay?'), findsOneWidget);
    L10n.setLanguage(AppLanguage.hi);
    await tester.pump();
    expect(find.text(L10n.t('crash.title', const {}, 'hi')), findsOneWidget);
    L10n.setLanguage(AppLanguage.system);
    await tester.pump();
    await tester.tap(find.text("I'm OK"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(port.raised, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    safety.dispose();
    port.dispose();
  });

  for (final size in [const Size(320, 568), const Size(568, 320)]) {
    testWidgets('SOS hold screen ${size.width.round()}x${size.height.round()} x1.3: a tap sends nothing, the hold sends, Cancel closes', (tester) async {
      await screen(tester, size);
      var sent = 0, cancelled = 0;
      await tester.pumpWidget(host(SosHoldScreen(onSend: () => sent++, onCancel: () => cancelled++), AppPalette.dark));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Hold to send SOS'), findsOneWidget);
      await tester.tap(find.byType(SOSButton));
      await tester.pump(const Duration(seconds: 2));
      expect(sent, 0, reason: 'a tap never sends');
      final hold = await tester.startGesture(tester.getCenter(find.byType(SOSButton)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 2));
      await hold.up();
      await tester.pump();
      expect(sent, 1);
      await tester.ensureVisible(find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      expect(cancelled, 1);
    });
  }

  test('brand guide: brand from the manufacturer, steps for each brand', () {
    expect(OemBatteryGuide.brandFor('Xiaomi'), OemBrand.xiaomi);
    expect(OemBatteryGuide.brandFor('POCO'), OemBrand.xiaomi);
    expect(OemBatteryGuide.brandFor('samsung'), OemBrand.samsung);
    expect(OemBatteryGuide.brandFor('realme'), OemBrand.oppo);
    expect(OemBatteryGuide.brandFor('iQOO'), OemBrand.vivo);
    expect(OemBatteryGuide.brandFor('HONOR'), OemBrand.huawei);
    expect(OemBatteryGuide.brandFor('Google'), OemBrand.generic);
    expect(OemBatteryGuide.rowTitle('samsung'), 'Battery settings for Samsung');
    expect(OemBatteryGuide.rowTitle('Google'), 'Battery settings for your phone');
    for (final b in OemBrand.values) {
      final steps = OemBatteryGuide.stepsFor(b);
      expect(steps, isNotEmpty);
      for (final s in steps) {
        expect(s.contains('\u2014') || s.contains('\u2013'), isFalse);
      }
    }
  });
}
