// Round 11 ride HUD widget tests (needs the Flutter SDK: flutter test test/hud_ride_sheet_test.dart).
//
// The ride sheet is built the way the cockpit builds it (RideSheet with the HUD header and body,
// the SOS button riding on the sheet's top edge from the same onTopChanged value), so the tests
// check the collapsed, half and full states and that SOS stays on screen and tappable in each.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/ride/ride_stats_accumulator.dart';
import 'package:coroute_app/presentation/ride/ride_sheet.dart';
import 'package:coroute_app/presentation/rider/hud/hud_controls.dart';
import 'package:coroute_app/presentation/rider/hud/hud_logic.dart';
import 'package:coroute_app/presentation/rider/hud/hud_sheet_parts.dart';
import 'package:coroute_app/presentation/rider/hud/hud_speed.dart';
import 'package:coroute_app/presentation/rider/hud/hud_top.dart';
import 'package:coroute_app/presentation/rider/live_cockpit_map_screen.dart' show RideSosButton;

RideStatsAccumulator _stats() {
  final a = RideStatsAccumulator();
  var lat = 12.0;
  a.onFix(ts: 0, lat: lat, lng: 77.0, speedKmh: 50, accuracyM: 5);
  for (var i = 1; i <= 120; i++) {
    lat += (i < 60 ? 50 : 85) / 3.6 / 111194.93;
    a.onFix(ts: i * 1000, lat: lat, lng: 77.0, speedKmh: i < 60 ? 50 : 85, accuracyM: 5, limitKmh: 80);
  }
  return a;
}

Future<(GlobalKey<RideSheetState>, ValueNotifier<double>)> _pump(WidgetTester tester, {bool solo = false, Size size = const Size(412, 915), double textScale = 1.0}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final key = GlobalKey<RideSheetState>();
  final top = ValueNotifier<double>(0);
  final stats = _stats();
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: LayoutBuilder(builder: (context, box) {
          final h = box.maxHeight;
          return Stack(children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xFF23272C))),
            Positioned.fill(
              child: RideSheet(
                key: key,
                maxFraction: 0.68,
                onTopChanged: (v) => top.value = v,
                header: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: RideSheet.hPad),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    HudCollapsedRow(speedKmh: 72, limitKmh: 60, hasFix: true, eta: '9:03 pm', leftValue: '386', leftUnit: 'km', onHoldEnd: () {}),
                    const SizedBox(height: 8),
                    HudGroupPillView(text: solo ? 'Solo ride' : '5 riders · lead 1.2 km ahead', solo: solo),
                  ]),
                ),
                body: [
                  HudArcSpeedometer(key: const Key('hud_arc_speedometer'), speedKmh: 72, limitKmh: 60, peakKmh: stats.peakKmh),
                  HudEtaRow(eta: '9:03 pm', leftValue: '386', leftUnit: 'km', maxKmh: stats.peakKmh),
                  HudRideSoFar(stats: stats),
                  HudSpeedBands(stats: stats, edgesKmh: SpeedBandProfile.motorcycle, currentKmh: 72),
                  HudOverLimit(stats: stats),
                  if (!solo) const HudSectionTitle('Group'),
                  if (!solo) HudRiderRow(name: 'Ravi Kumar', color: Colors.teal, role: 'Lead', distanceText: '1.2 km ahead', battery: 64, onCall: () {}),
                  HudTripChart(trace: stats.speedTrace, stepMs: stats.traceStep, limitKmh: 60),
                ],
              ),
            ),
            ValueListenableBuilder<double>(
              valueListenable: top,
              builder: (_, t, sos) => Positioned(left: 12, bottom: (t + 12).clamp(12.0, h - 82 - 8), child: sos!),
              child: RideSosButton(onTriggered: () {}),
            ),
          ]);
        }),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
  return (key, top);
}

void _expectSosVisible(WidgetTester tester, Size size) {
  final sos = find.byType(RideSosButton);
  expect(sos, findsOneWidget);
  expect(sos.hitTestable(), findsOneWidget, reason: 'SOS must be tappable');
  final r = tester.getRect(sos);
  expect(r.top, greaterThanOrEqualTo(0));
  expect(r.bottom, lessThanOrEqualTo(size.height));
  expect(r.width, greaterThanOrEqualTo(56));
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('collapsed: speed dial, ETA, left, hold-to-end, group pill; SOS visible', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('hud_speed_dial')), findsOneWidget);
    expect(find.text('9:03 pm'), findsWidgets);
    expect(find.byKey(const Key('hud_end_ride')), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('hud_end_ride'))).height, greaterThanOrEqualTo(56));
    expect(find.text('5 riders · lead 1.2 km ahead'), findsOneWidget);
    _expectSosVisible(tester, const Size(412, 915));
  });

  testWidgets('half: arc speedometer and ride so far on screen; SOS visible', (tester) async {
    final (key, _) = await _pump(tester);
    await tester.drag(find.byKey(const Key('hud_speed_dial')), const Offset(0, -260));
    await _settle(tester);
    expect(find.byKey(const Key('hud_arc_speedometer')).hitTestable(), findsOneWidget);
    expect(find.text('Ride so far'), findsOneWidget);
    _expectSosVisible(tester, const Size(412, 915));
    expect(key.currentState, isNotNull);
  });

  testWidgets('full: speed bands, over the limit, group list; SOS visible', (tester) async {
    final (key, _) = await _pump(tester);
    key.currentState!.toggle();
    await _settle(tester);
    await tester.drag(find.byKey(const Key('hud_ride_so_far')), const Offset(0, -500));
    await _settle(tester);
    expect(find.byKey(const Key('hud_speed_bands')), findsOneWidget);
    expect(find.byKey(const Key('hud_over_limit')), findsOneWidget);
    expect(find.text('Distance by speed'), findsOneWidget);
    _expectSosVisible(tester, const Size(412, 915));
  });

  testWidgets('solo: no group list, SOS visible; small phone at 2x text keeps SOS on screen', (tester) async {
    await _pump(tester, solo: true, size: const Size(320, 640), textScale: 2.0);
    expect(find.text('Group'), findsNothing);
    expect(find.text('Solo ride'), findsOneWidget);
    _expectSosVisible(tester, const Size(320, 640));
  });

  testWidgets('speed dial: amber over the limit, red past the +10 % margin (semantics say so)', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: HudSpeedDial(speedKmh: 70, limitKmh: 60)))));
    expect(find.bySemanticsLabel(RegExp('over the limit')), findsOneWidget);
    semantics.dispose();
    expect(HudSpeedRing.level(70, 60), HudSpeedLevel.strong);
  });

  testWidgets('turn card: distance, instruction, then-line; free ride shows the road', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(children: [
          HudTurnCard(model: HudTurnModel.turn(direction: HudTurnDir.left, distanceM: 54, road: 'MG Road', thenLine: 'Then turn right onto Ring Rd', thenDirection: HudTurnDir.right)),
          HudTurnCard(key: Key('free'), model: HudTurnModel.free(title: 'Outer Ring Rd', subtitle: 'No route · riding free')),
        ]),
      ),
    ));
    expect(find.text('50 m'), findsOneWidget);
    expect(find.text('Turn left onto MG Road'), findsOneWidget);
    expect(find.byKey(const Key('hud_turn_then')), findsOneWidget);
    expect(find.text('Outer Ring Rd'), findsOneWidget);
  });

  testWidgets('control column: every button is 56 dp; recenter only when panned', (tester) async {
    Future<void> pump(bool following) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Center(
              child: HudControlColumn(
                headingUp: true,
                onToggleOrientation: () {},
                following: following,
                onRecenter: () {},
                onLayers: () {},
                night: false,
                onToggleNight: () {},
                onFitGroup: () {},
                onZoomIn: () {},
                onZoomOut: () {},
              ),
            ),
          ),
        ));
    await pump(true);
    expect(find.byKey(const Key('hud_recenter')), findsNothing);
    for (final b in tester.widgetList<HudControlButton>(find.byType(HudControlButton))) {
      expect(tester.getSize(find.byWidget(b)).height, greaterThanOrEqualTo(56));
    }
    await pump(false);
    expect(find.byKey(const Key('hud_recenter')), findsOneWidget);
  });
}
