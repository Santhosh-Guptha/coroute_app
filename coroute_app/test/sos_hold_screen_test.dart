import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/l10n/l10n.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/ui/sos_button.dart';
import 'package:coroute_app/presentation/safety/sos_hold_screen.dart';

/// The SOS hold screen (3.16, item 4 and 23): fits 320 dp at text x1.3 in
/// portrait and landscape, light and dark; a tap sends nothing, the hold
/// sends, Cancel closes; Hindi and Telugu texts render and switch live.
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

  tearDown(() {
    L10n.setLanguage(AppLanguage.system);
    AppTheme.use(AppPalette.dark);
  });

  for (final palette in [AppPalette.dark, AppPalette.light]) {
    for (final size in [const Size(320, 568), const Size(568, 320)]) {
      final where = '${palette == AppPalette.dark ? 'dark' : 'light'} ${size.width.round()}x${size.height.round()}';
      testWidgets('hold screen fits at 320 dp, text x1.3 ($where): tap sends nothing, hold sends, Cancel closes', (tester) async {
        await screen(tester, size);
        var sent = 0, cancelled = 0;
        await tester.pumpWidget(host(SosHoldScreen(onSend: () => sent++, onCancel: () => cancelled++), palette));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('Hold to send SOS'), findsOneWidget);
        expect(find.textContaining('Nothing is sent until you hold it'), findsOneWidget);
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
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final lang in [AppLanguage.hi, AppLanguage.te]) {
    for (final size in [const Size(320, 568), const Size(568, 320)]) {
      testWidgets('hold screen in ${lang.code} at ${size.width.round()}x${size.height.round()} x1.3: translated title and Cancel, no overflow', (tester) async {
        L10n.setLanguage(lang);
        await screen(tester, size);
        await tester.pumpWidget(host(SosHoldScreen(onSend: () {}, onCancel: () {}), AppPalette.dark));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text(L10n.t('sos.hold.title', const {}, lang.code)), findsOneWidget);
        expect(find.text(L10n.t('sos.cancel', const {}, lang.code)), findsOneWidget);
        expect(find.text('Hold to send SOS'), findsNothing);
        expect(SosHoldScreen.title, L10n.t('sos.hold.title', const {}, lang.code));
      });
    }
  }

  testWidgets('the title follows a language change while the screen is open', (tester) async {
    await screen(tester, const Size(360, 740));
    await tester.pumpWidget(host(SosHoldScreen(onSend: () {}, onCancel: () {}), AppPalette.dark));
    expect(find.text('Hold to send SOS'), findsOneWidget);
    L10n.setLanguage(AppLanguage.te);
    await tester.pump();
    expect(find.text(L10n.t('sos.hold.title', const {}, 'te')), findsOneWidget);
    expect(find.text('Hold to send SOS'), findsNothing);
    L10n.setLanguage(AppLanguage.en);
    await tester.pump();
    expect(find.text('Hold to send SOS'), findsOneWidget);
  });

  testWidgets('screen reader: the hold button is labelled and its long-press sends', (tester) async {
    final handle = tester.ensureSemantics();
    await screen(tester, const Size(360, 740));
    var sent = 0;
    await tester.pumpWidget(host(SosHoldScreen(onSend: () => sent++, onCancel: () {}), AppPalette.dark));
    expect(find.bySemanticsLabel('Send SOS to your group'), findsOneWidget);
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      tester.getSemantics(find.bySemanticsLabel('Send SOS to your group')).id,
      SemanticsAction.longPress,
    );
    await tester.pump();
    expect(sent, 1);
    handle.dispose();
  });
}
