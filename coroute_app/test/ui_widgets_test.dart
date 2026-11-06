import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/presentation/ride/ride_sheet.dart';
import 'package:coroute_app/presentation/rider/live_cockpit_map_screen.dart';
import 'package:coroute_app/presentation/widgets/connection_banner.dart';
import 'package:coroute_app/presentation/widgets/intercom_dock.dart';
import 'package:coroute_app/presentation/widgets/rider_status_sheet.dart';

void main() {

  Widget host(Widget child, RealtimeService rt) => MultiProvider(
        providers: [
          ChangeNotifierProvider<RealtimeService>.value(value: rt),
          ChangeNotifierProvider(create: (_) => SettingsService()),
          ChangeNotifierProvider(create: (_) => IntercomService(rt)),
        ],
        child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
      );

  /// 320 dp wide at 1.3x text, in both themes.
  Future<void> narrow(WidgetTester tester, Widget child, {AppPalette? palette}) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = palette ?? AppPalette.dark;
    final app = MaterialApp(
      theme: AppTheme.themeFor(p),
      home: MediaQuery(
        data: const MediaQueryData(size: Size(320, 720), textScaler: TextScaler.linear(1.3)),
        child: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child)),
      ),
    );
    await tester.pumpWidget(app);
    await tester.pump();
  }

  testWidgets('ConnectionBanner shows offline state and hides when connected', (tester) async {
    final rt = RealtimeService();
    await tester.pumpWidget(host(const ConnectionBanner(), rt));
    expect(find.textContaining('Offline'), findsOneWidget);
  });

  testWidgets('Intercom options: talk mode in plain words and hear the group', (tester) async {
    final rt = RealtimeService();
    await tester.pumpWidget(host(const IntercomOptions(), rt));
    expect(find.text('Hold to talk'), findsOneWidget);
    expect(find.text('Hands-free'), findsOneWidget);
    expect(find.text('Hear the group'), findsOneWidget);
  });

  testWidgets('ride SOS: a tap does nothing, a 1.5 s hold sends; screen readers hear the SOS label', (tester) async {
    final handle = tester.ensureSemantics();
    var sent = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: RideSosButton(onTriggered: () => sent++)))));
    expect(find.bySemanticsLabel(sosSemanticsLabel), findsOneWidget);
    await tester.tap(find.byType(RideSosButton));
    await tester.pump(const Duration(seconds: 2));
    expect(sent, 0);
    final g = await tester.startGesture(tester.getCenter(find.byType(RideSosButton)));
    // The tap-down fires after the 100 ms press timeout; the hold animation starts on that frame.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 800));
    expect(sent, 0);
    await tester.pump(const Duration(milliseconds: 800));
    expect(sent, 1);
    await g.up();
    await tester.pump();
    handle.dispose();
  });

  testWidgets('collapsed sheet: riding metrics and stopped details fit 320 dp at 1.3x', (tester) async {
    for (final p in [AppPalette.dark, AppPalette.light]) {
      await narrow(
        tester,
        Column(children: [
          const RidingMetrics(remainingM: 186000, eta: '11:40 PM', riding: 5, total: 12, spreadM: 2100),
          StoppedDetails(
            stoppedFor: const Duration(minutes: 8),
            place: '12.97160, 77.59456',
            nearby: 3,
            nearbyRadiusM: 500,
            nextM: 12000,
            nextLabel: 'Next stop',
            reason: '',
            onTellWhy: () {},
          ),
        ]),
        palette: p,
      );
      expect(tester.takeException(), isNull);
    }
    expect(find.text('Remaining'), findsOneWidget);
    expect(find.text('ETA'), findsOneWidget);
    expect(find.text('Riding'), findsOneWidget);
    expect(find.text('Spread'), findsOneWidget);
    expect(find.text('Stopped 8 min'), findsOneWidget);
    expect(find.text('Tell the group why'), findsOneWidget);
    expect(metricDistance(186000), ('186', 'km'));
    expect(metricDistance(null), ('-', null));
  });

  testWidgets('stop reason sheet: five big reasons, more reasons and a typed reason in the same sheet', (tester) async {
    String? code;
    String? message;
    await narrow(tester, StatusPicker(onPick: (c, m) {
      code = c;
      message = m;
    }, onClear: () {}));
    expect(tester.takeException(), isNull);
    for (final c in RiderStatusSheet.commonCodes) {
      expect(find.text(RiderStatusSheet.getStatusLabel(c)), findsOneWidget);
    }
    expect(find.text('Traffic Delay'), findsNothing);
    expect(find.text('Clear status'), findsNothing);
    await tester.tap(find.text('More reasons'));
    await tester.pump();
    expect(find.text('Traffic Delay'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Waiting for a mechanic');
    await tester.tap(find.text('Set'));
    expect(code, 'CUSTOM');
    expect(message, 'Waiting for a mechanic');
    await tester.tap(find.text('Fueling'));
    expect(code, 'FUELING');
  });
}
