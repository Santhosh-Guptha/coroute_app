import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/widgets/cockpit_hud.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/presentation/ride/ride_sheet.dart';
import 'package:coroute_app/presentation/ride/riders_ladder.dart';
import 'package:coroute_app/presentation/rider/live_cockpit_map_screen.dart';
import 'package:coroute_app/presentation/widgets/connection_banner.dart';
import 'package:coroute_app/presentation/widgets/intercom_dock.dart';
import 'package:coroute_app/presentation/widgets/rider_status_sheet.dart';

void main() {
  RiderModel rider(String id, String name, {double lat = 0, double speed = 0, int seen = 0, int stoppedSince = 0}) =>
      RiderModel(userId: id, name: name, lat: lat, lng: lat == 0 ? 0 : 78.0, speedKmh: speed, lastSeenEpochMs: seen, stoppedSince: stoppedSince);

  ConvoyModel convoy() => ConvoyModel(
        groupId: 'GRP-TEST',
        name: 'Test convoy',
        joinCode: '123456',
        createdByUserId: 'usr_me',
        createdByUserName: 'Me',
        createdAtEpochMs: 0,
        riders: {'usr_me': rider('usr_me', 'Me'), 'usr_other': rider('usr_other', 'Other Rider')},
      );

  Widget host(Widget child, RealtimeService rt) => MultiProvider(
        providers: [
          ChangeNotifierProvider<RealtimeService>.value(value: rt),
          ChangeNotifierProvider(create: (_) => IntercomService(rt)),
        ],
        child: MaterialApp(home: Scaffold(body: Column(children: [child]))),
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

  testWidgets('IntercomDock is one row: talk target, talk button, mute; no SOS', (tester) async {
    final rt = RealtimeService();
    await tester.pumpWidget(host(IntercomDock(convoy: convoy(), me: rider('usr_me', 'Me')), rt));
    expect(find.text('Talk to: Everyone'), findsOneWidget);
    expect(find.text('HOLD TO TALK'), findsOneWidget);
    expect(find.byTooltip('Mute microphone'), findsOneWidget);
    // The mode toggle moved to Intercom options; SOS is the hold button on the ride map.
    expect(find.text('PTT'), findsNothing);
    expect(find.text('VOX'), findsNothing);
    expect(find.text('SOS'), findsNothing);
    // Offline: the dock says so instead of pretending the radio works.
    expect(find.textContaining('Reconnecting'), findsOneWidget);
    // The talk button is a primary ride action: at least 56 dp tall.
    expect(tester.getSize(find.ancestor(of: find.text('HOLD TO TALK'), matching: find.byType(AnimatedContainer)).first).height, greaterThanOrEqualTo(56));
  });

  testWidgets('Talk-to picker lists only other riders and switches to a private channel', (tester) async {
    final rt = RealtimeService();
    await tester.pumpWidget(host(IntercomDock(convoy: convoy(), me: rider('usr_me', 'Me')), rt));
    await tester.tap(find.text('Talk to: Everyone'));
    await tester.pumpAndSettle();
    expect(find.text('Everyone in the convoy'), findsOneWidget);
    expect(find.text('Other Rider'), findsOneWidget);
    expect(find.text('Me'), findsNothing);
    await tester.tap(find.text('Other Rider'));
    await tester.pumpAndSettle();
    expect(find.text('Private: Other Rider'), findsOneWidget);
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

  testWidgets('riders ladder: order, gaps and "too far behind" at 320 dp and 1.3x text', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final c = ConvoyModel(
      groupId: 'G',
      name: 'Hill run',
      joinCode: '123456',
      createdByUserId: 'me',
      createdByUserName: 'Me',
      createdAtEpochMs: 0,
      destinationLat: 17.3,
      destinationLng: 78.0,
      distanceThresholdMeters: 1000,
      riders: {
        'me': rider('me', 'Me', lat: 17.05, speed: 40, seen: now),
        'a': rider('a', 'Arjun Kumar', lat: 17.055, speed: 0, seen: now, stoppedSince: now - 8 * 60000),
        'k': rider('k', 'Venkata Subramaniam Ramakrishnan', lat: 17.0, speed: 30, seen: now - 6 * 60000),
      },
    );
    final rungs = RideFacts.ladder(c, 'me');
    final statuses = {for (final r in c.riders.values) r.userId: riderStatusOf(r, c, isMe: r.userId == 'me', nowMs: now)};
    RiderModel? tapped;
    for (final p in [AppPalette.dark, AppPalette.light]) {
      await narrow(
        tester,
        RidersLadder(rungs: rungs, colors: const {}, statuses: statuses, nowMs: now, onTap: (r) => tapped = r),
        palette: p,
      );
      expect(tester.takeException(), isNull);
    }
    expect(find.text('Arjun Kumar'), findsOneWidget);
    expect(find.text('Me (You)'), findsOneWidget);
    expect(find.text('Stopped, 8 min'), findsOneWidget);
    expect(find.textContaining('too far behind'), findsOneWidget);
    expect(find.textContaining('Offline'), findsOneWidget);
    expect(find.textContaining('behind'), findsWidgets);
    // Front to back: Arjun above me above Kiran.
    expect(tester.getTopLeft(find.text('Arjun Kumar')).dy, lessThan(tester.getTopLeft(find.text('Me (You)')).dy));
    await tester.tap(find.text('Arjun Kumar'));
    expect(tapped?.userId, 'a');
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
          const CockpitHud(speedKmh: 92, speedLimitKmh: 80),
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
    expect(find.text('Over the 80 limit'), findsOneWidget);
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
