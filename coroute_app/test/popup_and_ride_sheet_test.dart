import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/ui/ui.dart';
import 'package:coroute_app/presentation/ride/ride_sheet.dart';
import 'package:coroute_app/presentation/rider/widgets/coroute_orbit_control.dart';
import 'package:coroute_app/presentation/safety/crash_alarm_screen.dart';
import 'package:coroute_app/presentation/widgets/emergency_sos_sheet.dart';
import 'package:coroute_app/presentation/widgets/sheet_coordinator.dart';

/// Pop-ups close on a tap outside (except the protected SOS / crash steps),
/// never pile up, and the ride sheet follows the finger without re-snapping.
void main() {
  final contextKey = GlobalKey();

  Widget app({Widget? body}) {
    AppTheme.use(AppPalette.dark);
    return MaterialApp(
      theme: AppTheme.themeFor(AppPalette.dark),
      home: Scaffold(
        body: Builder(key: contextKey, builder: (_) => body ?? const SizedBox.expand()),
      ),
    );
  }

  BuildContext ctx() => contextKey.currentContext!;
  final coordinator = SheetCoordinator.instance;

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  setUp(coordinator.reset);

  group('a tap outside closes a pop-up', () {
    testWidgets('a standard sheet (showAppSheet)', (tester) async {
      await phone(tester);
      await tester.pumpWidget(app());
      coordinator.present<void>(ctx(), key: 'sheet', open: () => showAppSheet<void>(ctx(), builder: (_) => const Text('SHEET BODY')));
      await tester.pumpAndSettle();
      expect(find.text('SHEET BODY'), findsOneWidget);
      expect(coordinator.isOpen('sheet'), isTrue);

      await tester.tapAt(const Offset(20, 20)); // the scrim above the sheet
      await tester.pumpAndSettle();
      expect(find.text('SHEET BODY'), findsNothing);
      expect(coordinator.hasOpen, isFalse);
    });

    testWidgets('a dialog', (tester) async {
      await phone(tester);
      await tester.pumpWidget(app());
      coordinator.present<void>(
        ctx(),
        key: 'dialog',
        open: () => showDialog<void>(context: ctx(), builder: (_) => const AlertDialog(content: Text('DIALOG BODY'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('DIALOG BODY'), findsOneWidget);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('DIALOG BODY'), findsNothing);
      expect(coordinator.hasOpen, isFalse);
    });

    testWidgets('a custom panel (showPopupPanel), and Back closes it too', (tester) async {
      await phone(tester);
      await tester.pumpWidget(app());
      Future<void> open() => coordinator.present<void>(
            ctx(),
            key: 'panel',
            open: () => showPopupPanel<void>(
              ctx(),
              builder: (_) => const Stack(
                children: [
                  Positioned(left: 100, top: 300, width: 200, height: 120, child: ColoredBox(color: Colors.white, child: Text('PANEL BODY'))),
                ],
              ),
            ),
          );

      open();
      await tester.pumpAndSettle();
      expect(find.text('PANEL BODY'), findsOneWidget);
      await tester.tap(find.text('PANEL BODY')); // inside: stays open
      await tester.pumpAndSettle();
      expect(find.text('PANEL BODY'), findsOneWidget);
      await tester.tapAt(const Offset(20, 700)); // outside: closes
      await tester.pumpAndSettle();
      expect(find.text('PANEL BODY'), findsNothing);

      open();
      await tester.pumpAndSettle();
      expect(find.text('PANEL BODY'), findsOneWidget);
      await tester.binding.handlePopRoute(); // system Back
      await tester.pumpAndSettle();
      expect(find.text('PANEL BODY'), findsNothing);
      expect(coordinator.hasOpen, isFalse);
    });

    testWidgets('the Orbit quick-access panel closes on a tap outside', (tester) async {
      await phone(tester);
      await tester.pumpWidget(app(
        body: CorouteOrbitControl(
          onIntercomTap: () {},
          onGroupTap: () {},
          onFuelTap: () {},
          onRouteTap: () {},
          onGuardianTap: () {},
          onMoreTap: () {},
        ),
      ));
      await tester.tap(find.byKey(const Key('coroute_orbit_fab_button')));
      await tester.pumpAndSettle();
      expect(find.text('COROUTE ORBIT'), findsOneWidget);
      expect(coordinator.isOpen(CorouteOrbitControl.popupKey), isTrue);

      await tester.tapAt(const Offset(390, 790)); // bottom-right corner: scrim
      await tester.pumpAndSettle();
      expect(find.text('COROUTE ORBIT'), findsNothing);
      expect(coordinator.hasOpen, isFalse);
    });

    testWidgets('an in-screen overlay attached to the coordinator is closed by the next pop-up', (tester) async {
      await phone(tester);
      await tester.pumpWidget(app());
      var closed = 0;
      coordinator.attach('overlay', () => closed++);
      coordinator.present<void>(ctx(), key: 'sheet', open: () => showAppSheet<void>(ctx(), builder: (_) => const Text('SHEET BODY')));
      await tester.pumpAndSettle();
      expect(closed, 1);
      expect(coordinator.isOpen('sheet'), isTrue);
    });
  });

  group('protected steps ignore a tap outside', () {
    testWidgets('turning an SOS off: only its buttons decide', (tester) async {
      await phone(tester);
      await tester.pumpWidget(app());
      bool? answer;
      EmergencySosSheet.confirmTurnOff(ctx(), title: 'Cancel SOS?', message: 'Has help reached you?', confirmLabel: 'Confirm Cancel')
          .then((v) => answer = v);
      await tester.pumpAndSettle();
      expect(find.text('Cancel SOS?'), findsOneWidget);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Cancel SOS?'), findsOneWidget, reason: 'an outside tap must not close the SOS step');
      expect(answer, isNull);

      await tester.tap(find.text('Keep SOS Active'));
      await tester.pumpAndSettle();
      expect(find.text('Cancel SOS?'), findsNothing);
      expect(answer, isFalse);
    });

    testWidgets('showProtectedDialog ignores outside taps', (tester) async {
      await phone(tester);
      await tester.pumpWidget(app());
      showProtectedDialog<void>(ctx(), builder: (_) => const AlertDialog(content: Text('PROTECTED')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.tapAt(const Offset(390, 790));
      await tester.pumpAndSettle();
      expect(find.text('PROTECTED'), findsOneWidget);
    });

    testWidgets('the crash countdown fills the screen: no outside to tap', (tester) async {
      await phone(tester);
      await tester.pumpWidget(app());
      var ok = 0, send = 0;
      Navigator.of(ctx()).push(MaterialPageRoute<void>(
        builder: (_) => PopScope(
          canPop: false,
          child: CrashAlarmView(secondsLeft: 27, onImOk: () => ok++, onSendNow: () => send++),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text(CrashAlarmView.title), findsOneWidget);
      await tester.tapAt(const Offset(2, 2));
      await tester.tapAt(const Offset(398, 798));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text(CrashAlarmView.title), findsOneWidget);
      expect(ok + send, 0);
    });

    testWidgets('a protected pop-up is never replaced or toggled closed by the coordinator', (tester) async {
      await phone(tester);
      await tester.pumpWidget(app());
      coordinator.present<void>(ctx(), key: 'sos', protected: true, open: () => showAppSheet<void>(ctx(), builder: (_) => const Text('SOS SHEET')));
      await tester.pumpAndSettle();
      coordinator.present<void>(ctx(), key: 'fuel', open: () => showAppSheet<void>(ctx(), builder: (_) => const Text('FUEL SHEET')));
      coordinator.present<void>(ctx(), key: 'sos', open: () => showAppSheet<void>(ctx(), builder: (_) => const Text('SOS SHEET')));
      await tester.pumpAndSettle();
      expect(find.text('SOS SHEET'), findsOneWidget);
      expect(find.text('FUEL SHEET'), findsNothing);
      expect(coordinator.close(), isFalse);
      expect(coordinator.isOpen('sos'), isTrue);
    });
  });

  group('cockpit pop-ups never pile up', () {
    testWidgets('opening a second pop-up closes the first; the same one again toggles it closed', (tester) async {
      await phone(tester);
      await tester.pumpWidget(app());
      coordinator.present<void>(ctx(), key: 'group', open: () => showAppSheet<void>(ctx(), builder: (_) => const Text('GROUP SHEET')));
      await tester.pumpAndSettle();
      expect(find.text('GROUP SHEET'), findsOneWidget);

      coordinator.present<void>(ctx(), key: 'fuel', open: () => showAppSheet<void>(ctx(), builder: (_) => const Text('FUEL SHEET')));
      await tester.pumpAndSettle();
      expect(find.text('GROUP SHEET'), findsNothing);
      expect(find.text('FUEL SHEET'), findsOneWidget);
      expect(coordinator.currentKey, 'fuel');

      coordinator.present<void>(ctx(), key: 'fuel', open: () => showAppSheet<void>(ctx(), builder: (_) => const Text('FUEL SHEET')));
      await tester.pumpAndSettle();
      expect(find.text('FUEL SHEET'), findsNothing);
      expect(coordinator.hasOpen, isFalse);
    });

    testWidgets('a pop-up opened from the Orbit panel replaces the panel', (tester) async {
      await phone(tester);
      await tester.pumpWidget(app(
        body: Builder(
          builder: (c) => CorouteOrbitControl(
            onIntercomTap: () {},
            onGroupTap: () => coordinator.present<void>(c, key: 'group', open: () => showAppSheet<void>(c, builder: (_) => const Text('GROUP SHEET'))),
            onFuelTap: () {},
            onRouteTap: () {},
            onGuardianTap: () {},
            onMoreTap: () {},
          ),
        ),
      ));
      await tester.tap(find.byKey(const Key('coroute_orbit_fab_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Group'));
      await tester.pumpAndSettle();
      expect(find.text('COROUTE ORBIT'), findsNothing);
      expect(find.text('GROUP SHEET'), findsOneWidget);
      expect(coordinator.currentKey, 'group');
    });
  });

  group('ride sheet drag', () {
    Future<(ValueNotifier<double>, List<double>, List<double>)> pumpSheet(WidgetTester tester) async {
      await phone(tester);
      final headerH = ValueNotifier<double>(120);
      final tops = <double>[];
      final settled = <double>[];
      await tester.pumpWidget(app(
        body: Stack(
          children: [
            Positioned.fill(
              child: RideSheet(
                header: ValueListenableBuilder<double>(
                  valueListenable: headerH,
                  builder: (_, h, _) => SizedBox(height: h, child: const Center(child: Text('HEADER'))),
                ),
                body: [for (var i = 0; i < 30; i++) SizedBox(height: 48, child: Text('Row $i'))],
                onTopChanged: tops.add,
                onTopSettled: settled.add,
              ),
            ),
          ],
        ),
      ));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      return (headerH, tops, settled);
    }

    testWidgets('dragging the header moves the sheet with the finger', (tester) async {
      final (_, tops, settled) = await pumpSheet(tester);
      final collapsed = tops.last;
      expect(settled, isNotEmpty);

      final g = await tester.startGesture(tester.getCenter(find.text('HEADER')));
      await g.moveBy(const Offset(0, -30)); // past the drag slop
      await tester.pump();
      final afterSlop = tops.last;
      await g.moveBy(const Offset(0, -100));
      await tester.pump();
      expect(tops.last - afterSlop, closeTo(100, 2), reason: 'the sheet follows the finger 1:1');
      expect(tops.last, greaterThan(collapsed + 100));

      final settledBefore = settled.length;
      await g.up();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      expect(settled.length, greaterThan(settledBefore), reason: 'told once the sheet is at rest');
      expect(settled.last, greaterThan(collapsed + 50), reason: 'it rests on an open size');
    });

    testWidgets('snap sizes do not change while a finger is on the sheet', (tester) async {
      final (headerH, _, _) = await pumpSheet(tester);
      final state = tester.state<RideSheetState>(find.byType(RideSheet));
      final before = state.debugSizes;

      final g = await tester.startGesture(tester.getCenter(find.text('HEADER')));
      await g.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(state.isTouched, isTrue);

      headerH.value = 200; // the header grows mid-drag (e.g. the stopped details appear)
      await tester.pump();
      await tester.pump();
      expect(state.debugSizes.$1, before.$1);
      expect(state.debugSizes.$2, before.$2);
      expect(identical(state.debugSizes.$3, before.$3), isTrue, reason: 'a new snap list re-snaps the sheet and cancels the drag');

      await g.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(state.debugSizes.$1, before.$1);

      await g.up();
      await tester.pumpAndSettle();
      expect(state.isTouched, isFalse);
      expect(state.debugSizes.$1, greaterThan(before.$1), reason: 'the new collapsed size applies once the finger lifts');
    });
  });
}
