// 3.55 owner decision: the missing-rider check card keeps "I'm OK" and "Need help" (asks the group
// to wait) and adds a clearly separate red "Send SOS" button that must be held for 3 s (3.55, was 1.5 s).
// Also the compact chip shown instead of a tap card while moving.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/presentation/ride/group_safety_cards.dart';
import 'package:coroute_app/presentation/ride/moving_card_chip.dart';
import 'package:coroute_app/presentation/safety/hold_sos_pill.dart';

Widget host(Widget child) => MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: child))),
    );

void main() {
  group('MissingRiderCard', () {
    late List<String> calls;
    Widget card({bool withSos = true}) => host(MissingRiderCard(
          title: 'Are you OK? The group is moving on',
          message: "Tap I'm OK, or say why you stopped. Your lead is told if you don't answer.",
          onOk: () => calls.add('ok'),
          onNeedHelp: () => calls.add('needHelp'),
          onWaiting: (r) => calls.add('wait:$r'),
          onSos: withSos ? () => calls.add('sos') : null,
          onDismiss: () => calls.add('dismiss'),
        ));
    setUp(() => calls = []);

    testWidgets("I'm OK, Need help and the waiting reasons work as before", (tester) async {
      await tester.pumpWidget(card());
      expect(find.text("I'm OK"), findsOneWidget);
      expect(find.text('Need help'), findsOneWidget);
      await tester.tap(find.text("I'm OK"));
      await tester.tap(find.text('Need help'));
      await tester.tap(find.text('Photo stop'));
      expect(calls, ['ok', 'needHelp', 'wait:PHOTO_STOP'], reason: 'Need help never raises an SOS');
    });

    testWidgets('Send SOS is separate, says what Need help does, and a tap does nothing', (tester) async {
      await tester.pumpWidget(card());
      expect(find.byKey(const ValueKey('missingRiderSos')), findsOneWidget);
      expect(find.text(MissingRiderCard.needHelpNote), findsOneWidget);
      expect(find.textContaining('Send SOS'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('missingRiderSos')));
      await tester.pump(const Duration(seconds: 2));
      expect(calls, isEmpty, reason: 'a tap or a bump cannot send an SOS');
    });

    testWidgets('holding Send SOS for 3 s raises the SOS; letting go early cancels', (tester) async {
      await tester.pumpWidget(card());
      final at = tester.getCenter(find.byKey(const ValueKey('missingRiderSos')));
      var g = await tester.startGesture(at);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text(HoldSosPill.holdingLabel), findsOneWidget);
      await g.up();
      await tester.pump(const Duration(seconds: 1));
      expect(calls, isEmpty, reason: 'let go after 0.8 s');

      g = await tester.startGesture(at);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 1500));
      expect(calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 1600));
      expect(calls, ['sos']);
      await g.up();
      await tester.pump();
    });

    testWidgets('without an SOS path the red button is not shown', (tester) async {
      await tester.pumpWidget(card(withSos: false));
      expect(find.byType(HoldSosPill), findsNothing);
      expect(find.text("I'm OK"), findsOneWidget);
    });

    testWidgets('screen readers: "Send SOS, press and hold"; their long press sends it', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(card());
      expect(find.bySemanticsLabel('Send SOS, press and hold'), findsOneWidget);
      handle.dispose();
    });
  });

  group('MovingCardChip', () {
    testWidgets('one line, no buttons, nothing to tap', (tester) async {
      await tester.pumpWidget(host(const MovingCardChip(text: "Off the group's route · Stop to choose", important: true)));
      expect(find.text("Off the group's route · Stop to choose"), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(IgnorePointer), findsWidgets);
    });
  });
}
