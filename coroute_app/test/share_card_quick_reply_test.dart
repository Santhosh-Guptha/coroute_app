import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/presentation/report/ride_share_card.dart';
import 'package:coroute_app/presentation/ride/messages_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => AppTheme.use(AppPalette.dark));

  Future<void> render(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(400, 800),
    double scale = 1.0,
    AppPalette palette = AppPalette.dark,
  }) async {
    AppTheme.use(palette);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The text scale is set above the Navigator so sheets get it too.
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(palette),
      builder: (context, c) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: c!,
      ),
      home: Scaffold(body: child),
    ));
    await tester.pump();
  }

  group('Quick replies', () {
    test('one constant list with the quick replies', () {
      expect(quickMessages.map((q) => q.text).toList(),
          ['Fuel stop', 'Wait for me', 'All good', 'Slow down', 'Taking a break', 'Bike problem', 'Road hazard ahead']);
      expect(quickMessages.where((q) => q.isWait).map((q) => q.text), ['Wait for me']);
      for (final q in quickMessages) {
        expect(q.cardType.length, lessThanOrEqualTo(24), reason: 'gateway keeps 24 characters');
        expect(q.text.length, lessThanOrEqualTo(300));
      }
    });

    testWidgets('a double tap sends once, shows "Sent", chips are glove sized (320 dp, x1.3)', (tester) async {
      final sent = <String>[];
      await render(
        tester,
        Padding(
          padding: const EdgeInsets.all(16),
          child: QuickReplyBar(onSend: (q) {
            sent.add(q.text);
            return true;
          }),
        ),
        size: const Size(320, 640),
        scale: 1.3,
      );
      expect(tester.takeException(), isNull);
      for (final q in quickMessages) {
        final chip = find.ancestor(of: find.text(q.text), matching: find.byType(InkWell));
        expect(chip, findsOneWidget);
        expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
      }

      await tester.tap(find.text('Fuel stop'));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.tap(find.text('Fuel stop'));
      await tester.pump(const Duration(milliseconds: 150));
      expect(sent, ['Fuel stop']);
      expect(find.text('Sent: Fuel stop'), findsOneWidget);

      // Another reply is not blocked.
      await tester.tap(find.text('All good'));
      await tester.pump();
      expect(sent, ['Fuel stop', 'All good']);
      expect(find.text('Sent: All good'), findsOneWidget);

      // After the cooldown the same reply can be sent again; the line has cleared.
      await tester.pump(const Duration(seconds: 3));
      expect(find.textContaining('Sent:'), findsNothing);
      await tester.tap(find.text('Fuel stop'));
      await tester.pump();
      expect(sent, ['Fuel stop', 'All good', 'Fuel stop']);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('offline: says not sent and allows a retry', (tester) async {
      var calls = 0;
      await render(tester, QuickReplyBar(onSend: (q) {
        calls++;
        return false;
      }));
      await tester.tap(find.text('Slow down'));
      await tester.pump();
      expect(find.text('Not sent, no connection'), findsOneWidget);
      await tester.tap(find.text('Slow down'));
      await tester.pump();
      expect(calls, 2);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('Share card', () {
    const track = [
      LatLng(17.44, 78.35),
      LatLng(17.30, 78.50),
      LatLng(16.90, 78.70),
      LatLng(16.07, 78.87),
    ];
    RideShareData data({double distanceM = 142000, int? ridingMs = 190 * 60000, List<LatLng>? sketch}) => RideShareData(
          tripName: 'Hyderabad to Srisailam',
          date: DateTime(2026, 10, 4, 6, 30),
          distanceM: distanceM,
          ridingMs: ridingMs,
          riders: 3,
          stops: 2,
          from: 'Gachibowli',
          to: 'Srisailam',
          sketch: sketch ?? track,
        );

    for (final p in [AppPalette.light, AppPalette.dark]) {
      final name = p.isLight ? 'light' : 'dark';
      testWidgets('shows the real numbers at 320 dp and text x1.3 ($name)', (tester) async {
        await render(
          tester,
          SingleChildScrollView(padding: const EdgeInsets.all(16), child: RideShareCard(data: data())),
          size: const Size(320, 900),
          scale: 1.3,
          palette: p,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('CoRoute'), findsOneWidget);
        expect(find.text('Hyderabad to Srisailam'), findsOneWidget);
        expect(find.text('Gachibowli to Srisailam'), findsOneWidget);
        expect(find.text('Sun 4 Oct 2026'), findsOneWidget);
        expect(find.text('142 km'), findsOneWidget);
        expect(find.text('Distance'), findsOneWidget);
        expect(find.text('3 h 10 min'), findsOneWidget);
        expect(find.text('Riding time'), findsOneWidget);
        expect(find.text('3'), findsOneWidget);
        expect(find.text('Riders'), findsOneWidget);
        expect(find.text('2'), findsOneWidget);
        expect(find.text('Stops'), findsOneWidget);
        expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is RouteSketchPainter), findsOneWidget);
      });

      testWidgets('the share sheet lays out at 320 dp and text x1.3 ($name)', (tester) async {
        await render(
          tester,
          Builder(builder: (c) => TextButton(onPressed: () => showRideShareSheet(c, data()), child: const Text('open'))),
          size: const Size(320, 640),
          scale: 1.3,
          palette: p,
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Share ride'), findsOneWidget);
        expect(find.text('Share image'), findsOneWidget);
        expect(find.text('Share as text'), findsOneWidget);
        expect(find.byType(RepaintBoundary), findsWidgets);
      });
    }

    testWidgets('unknown values are left out, never shown as 0', (tester) async {
      await render(tester, SingleChildScrollView(child: RideShareCard(data: data(distanceM: 0, ridingMs: null, sketch: const []))));
      expect(tester.takeException(), isNull);
      expect(find.text('Distance'), findsNothing);
      expect(find.text('Riding time'), findsNothing);
      expect(find.text('Stops'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is RouteSketchPainter), findsNothing);
    });

    test('plain text fallback has the same facts', () {
      final text = data().toText();
      expect(text, contains('CoRoute ride: Hyderabad to Srisailam'));
      expect(text, contains('Distance 142 km, riding 3 h 10 min'));
      expect(text, contains('3 riders, 2 stops'));
      final unknown = data(distanceM: 0, ridingMs: null).toText();
      expect(unknown, isNot(contains('Distance')));
      expect(unknown, isNot(contains('riding')));
      expect(data().fileName, 'Hyderabad_to_Srisailam.png');
    });

    test('cleanPoints drops missing positions', () {
      final pts = RideShareData.cleanPoints([const LatLng(0, 0), const LatLng(17.4, 78.4)]);
      expect(pts, [const LatLng(17.4, 78.4)]);
    });
  });

  group('Route sketch painter', () {
    RouteSketchPainter painter(List<LatLng> pts) => RouteSketchPainter(
          points: pts,
          lineColor: AppPalette.light.neonCyan,
          startColor: AppPalette.light.emeraldSafe,
          endColor: AppPalette.light.textPrimary,
          ringColor: AppPalette.light.slateCard,
        );

    void paintOnce(RouteSketchPainter p, Size size) {
      final recorder = ui.PictureRecorder();
      p.paint(Canvas(recorder), size);
      recorder.endRecording().dispose();
    }

    test('empty track: nothing to draw, no error', () {
      expect(RouteSketchPainter.project(const [], const Size(200, 100)), isEmpty);
      paintOnce(painter(const []), const Size(200, 100));
    });

    test('single point and repeated point: one dot in the middle', () {
      expect(RouteSketchPainter.project(const [LatLng(17.4, 78.4)], const Size(200, 100)), [const Offset(100, 50)]);
      expect(RouteSketchPainter.project(const [LatLng(17.4, 78.4), LatLng(17.4, 78.4)], const Size(200, 100)), [const Offset(100, 50)]);
      paintOnce(painter(const [LatLng(17.4, 78.4)]), const Size(200, 100));
    });

    test('a track fits inside the padded box, straight lines too', () {
      for (final pts in [
        const [LatLng(17.44, 78.35), LatLng(16.07, 78.87), LatLng(16.5, 79.2)],
        const [LatLng(17.0, 78.0), LatLng(17.0, 79.0)], // east to west only
        const [LatLng(16.0, 78.0), LatLng(17.0, 78.0)], // north to south only
      ]) {
        final out = RouteSketchPainter.project(pts, const Size(200, 100));
        expect(out.length, pts.length);
        for (final o in out) {
          expect(o.dx, inInclusiveRange(12 - 1e-6, 188 + 1e-6));
          expect(o.dy, inInclusiveRange(12 - 1e-6, 88 + 1e-6));
        }
        paintOnce(painter(pts), const Size(200, 100));
      }
    });

    test('long tracks are thinned but keep the last point', () {
      final pts = [for (var i = 0; i < 5000; i++) LatLng(17 + i / 10000, 78 + i / 5000)];
      final out = RouteSketchPainter.project(pts, const Size(300, 150));
      expect(out.length, lessThanOrEqualTo(RouteSketchPainter.maxPoints + 1));
      final full = RouteSketchPainter.project([pts.first, pts.last], const Size(300, 150));
      expect((out.last - full.last).distance, lessThan(1e-6));
    });

    test('repaints only when the input changes', () {
      final a = painter(const [LatLng(1, 1)]);
      expect(a.shouldRepaint(a), isFalse);
      expect(painter(const [LatLng(1, 1), LatLng(2, 2)]).shouldRepaint(a), isTrue);
    });
  });
}
