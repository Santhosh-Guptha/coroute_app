import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/ui/ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Records haptics (and answers every platform call) so tests can check them.
  var haptics = <MethodCall>[];
  setUp(() {
    haptics = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add(call);
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    AppTheme.use(AppPalette.dark);
  });

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
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(palette),
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: Scaffold(body: child),
      ),
    ));
    await tester.pump();
  }

  group('Format helpers', () {
    test('distance', () {
      expect(formatDistance(350), '350 m');
      expect(formatDistance(1234), '1.2 km');
      expect(formatDistance(186000), '186 km');
      expect(formatDistance(-350), '350 m');
      expect(formatDistance(double.nan), 'Unknown');
    });

    test('rounded distance and ahead/behind text', () {
      expect(formatDistanceRounded(349), '350 m');
      expect(formatDistanceRounded(1840), '1.8 km');
      expect(describeDistance(800, ahead: true), '800 m ahead');
      expect(describeDistance(349, ahead: false), '350 m behind');
      expect(describeDistance(1840), '1.8 km away');
    });

    test('duration and ago', () {
      expect(formatDuration(const Duration(minutes: 8)), '8 min');
      expect(formatDuration(const Duration(minutes: 72)), '1 h 12 min');
      expect(formatDuration(const Duration(hours: 2)), '2 h');
      expect(formatDuration(const Duration(seconds: -5)), '0 s');
      expect(formatAgo(const Duration(seconds: 5)), 'just now');
      expect(formatAgo(const Duration(seconds: 42)), '40 s ago');
      expect(formatAgo(const Duration(minutes: 6, seconds: 20)), '6 min ago');
    });

    test('initials', () {
      expect(initialsOf('Arjun Kumar'), 'AK');
      expect(initialsOf('kiran'), 'K');
      expect(initialsOf('Venkata Subramaniam Ramakrishnan'), 'VR');
      expect(initialsOf('   '), '?');
    });
  });

  group('RiderStatus.fromSignals', () {
    const now = 10000000;
    final staleMs = RideThresholds.staleAfter.inMilliseconds;
    final offlineMs = RideThresholds.offlineAfter.inMilliseconds;

    RiderStatus at({
      bool sos = false,
      bool online = true,
      int? ageMs = 0,
      double? speed,
      double? accuracy,
      int? stoppedFor,
    }) =>
        RiderStatus.fromSignals(
          sos: sos,
          online: online,
          lastSeenMs: ageMs == null ? null : now - ageMs,
          speedKmh: speed,
          accuracyM: accuracy,
          stoppedForMs: stoppedFor,
          nowMs: now,
        );

    test('SOS wins over everything', () {
      expect(at(sos: true, online: false, ageMs: null), RiderStatus.emergency);
    });

    test('offline: never seen, or seen at least offlineAfter ago', () {
      expect(at(ageMs: null, speed: 40), RiderStatus.offline);
      expect(RiderStatus.fromSignals(lastSeenMs: 0, nowMs: now), RiderStatus.offline);
      expect(at(ageMs: offlineMs, speed: 40), RiderStatus.offline);
      expect(at(ageMs: offlineMs - 1, speed: 40), RiderStatus.disconnected);
    });

    test('disconnected: not online, or no update for staleAfter', () {
      expect(at(online: false, speed: 40), RiderStatus.disconnected);
      expect(at(ageMs: staleMs, speed: 40), RiderStatus.disconnected);
      expect(at(ageMs: staleMs - 1, speed: 40), RiderStatus.riding);
    });

    test('low GPS above the accuracy threshold', () {
      expect(at(speed: 40, accuracy: RideThresholds.lowGpsAccuracyM + 1), RiderStatus.lowGps);
      expect(at(speed: 40, accuracy: RideThresholds.lowGpsAccuracyM), RiderStatus.riding);
    });

    test('riding, stopped and resting', () {
      expect(at(speed: RideThresholds.movingSpeedKmh), RiderStatus.riding);
      expect(at(speed: RideThresholds.movingSpeedKmh - 0.1), RiderStatus.stopped);
      expect(at(speed: null), RiderStatus.stopped);
      final restMs = RideThresholds.restingAfter.inMilliseconds;
      expect(at(speed: 0, stoppedFor: restMs - 1), RiderStatus.stopped);
      expect(at(speed: 0, stoppedFor: restMs), RiderStatus.resting);
    });

    test('labels and priority', () {
      expect(RiderStatus.lowGps.label, 'Low GPS');
      expect(RiderStatus.emergency.priority > RiderStatus.offline.priority, isTrue);
      expect(RiderStatus.offline.priority > RiderStatus.riding.priority, isTrue);
    });
  });

  group('StopKind', () {
    test('maps to and from the stored category codes', () {
      expect(StopKind.fromCategory('FUEL'), StopKind.fuel);
      expect(StopKind.fromCategory('scenic'), StopKind.scenic);
      expect(StopKind.fromCategory('OTHER'), StopKind.custom);
      expect(StopKind.fromCategory(null), StopKind.custom);
      expect(StopKind.meeting.category, 'MEETING');
      expect(StopKind.rest.category, 'REST');
    });
  });

  testWidgets('RiderAvatar shows initials and reads "Name, Status"', (tester) async {
    final handle = tester.ensureSemantics();
    await render(tester, const Center(child: RiderAvatar(name: 'Arjun Kumar', status: RiderStatus.stopped)));
    expect(find.text('AK'), findsOneWidget);
    expect(find.bySemanticsLabel('Arjun Kumar, Stopped'), findsOneWidget);
    handle.dispose();
  });

  group('SOSButton', () {

    testWidgets('a tap does not trigger', (tester) async {
      var count = 0;
      await render(tester, Center(child: SOSButton(onTriggered: () => count++)));
      await tester.tap(find.byType(SOSButton));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 2));
      expect(count, 0);
      expect(haptics, isEmpty);
    });

    testWidgets('a short hold does not trigger, a full hold does (once, with haptic)', (tester) async {
      var count = 0;
      await render(tester, Center(child: SOSButton(onTriggered: () => count++)));

      final early = await tester.startGesture(tester.getCenter(find.byType(SOSButton)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 700));
      await early.up();
      await tester.pump(const Duration(seconds: 2));
      expect(count, 0);

      final hold = await tester.startGesture(tester.getCenter(find.byType(SOSButton)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      expect(count, 0);
      await tester.pump(const Duration(seconds: 2));
      expect(count, 1);
      expect(haptics.map((c) => c.arguments), contains('HapticFeedbackType.heavyImpact'));
      await tester.pump(const Duration(seconds: 2));
      await hold.up();
      await tester.pump();
      expect(count, 1);
    });

    testWidgets('label and screen reader text', (tester) async {
      final handle = tester.ensureSemantics();
      await render(tester, Center(child: SOSButton(onTriggered: () {})));
      expect(find.text('SOS'), findsOneWidget);
      expect(find.bySemanticsLabel('Emergency SOS, press and hold'), findsOneWidget);
      handle.dispose();
    });
  });

  for (final p in [AppPalette.dark, AppPalette.light]) {
    final name = p.isLight ? 'light' : 'dark';

    testWidgets('RideMetric never overflows at 320 dp and text x1.3 ($name)', (tester) async {
      await render(
        tester,
        const Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(child: RideMetric(value: '1234.5', unit: 'km', label: 'Remaining distance', emphasis: true)),
              Expanded(child: RideMetric(value: '10:45 PM', label: 'Arrival time')),
              Expanded(child: RideMetric(value: '12', unit: 'riders', label: 'Group')),
              Expanded(child: RideMetric(value: '18.4', unit: 'km', label: 'Spread')),
            ],
          ),
        ),
        size: const Size(320, 640),
        scale: 1.3,
        palette: p,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Remaining distance'), findsOneWidget);
    });

    testWidgets('kit widgets lay out at 320 dp and text x1.3 ($name)', (tester) async {
      await render(
        tester,
        SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  RiderAvatar(name: 'Venkata Subramaniam Ramakrishnan', status: RiderStatus.emergency, size: 48),
                  SizedBox(width: 8),
                  Flexible(child: RiderStatusChip(status: RiderStatus.disconnected, detail: 'last seen 6 min ago')),
                ],
              ),
              const DistanceIndicator(meters: 3400, ahead: false, warn: true),
              RideAlert(
                tier: AlertTier.critical,
                title: 'SOS: Venkata Subramaniam Ramakrishnan needs help',
                message: 'Nagarjuna Sagar to Srisailam Highway, Nalgonda district',
                actionLabel: 'Show on map',
                onAction: () {},
                onDismiss: () {},
              ),
              const RideAlert(tier: AlertTier.important, title: 'Kiran stopped', message: 'Stopped for 8 min'),
              const RideAlert(tier: AlertTier.normal, title: 'Priya joined'),
              Align(
                alignment: Alignment.centerLeft,
                child: MapControl(icon: Icons.my_location_rounded, tooltip: 'Centre on me', onPressed: () {}, active: true),
              ),
              const StopCard(
                kind: StopKind.fuel,
                name: 'Hotel Haritha Restaurant and Rest Area, Dornala',
                subtitle: '12 km ahead, planned stop for 20 min',
                trailing: Text('12 km'),
              ),
              const TripProgress(stops: [
                TripProgressStop(name: 'Start, Hyderabad', done: true),
                TripProgressStop(name: 'Fuel at Kalwakurthy', kind: StopKind.fuel, done: true),
                TripProgressStop(name: 'Breakfast at Hotel Haritha, Dornala', kind: StopKind.food, kmFromMe: 42.5),
                TripProgressStop(name: 'Srisailam', kind: StopKind.meeting, kmFromMe: 118),
              ]),
              RouteSummary(
                distanceKm: 214.6,
                duration: const Duration(hours: 5, minutes: 40),
                stops: 3,
                riders: 12,
                departure: DateTime(2026, 10, 9, 6, 30),
              ),
              const SizedBox(
                height: 360,
                child: EmptyState(
                  icon: Icons.two_wheeler_rounded,
                  title: 'No active ride',
                  message: 'Start a ride or join your group with a code.',
                  primaryLabel: 'Start Ride',
                  onPrimary: _noop,
                  secondaryLabel: 'Join Ride',
                  onSecondary: _noop,
                ),
              ),
              Align(alignment: Alignment.centerRight, child: SOSButton(onTriggered: () {})),
            ],
          ),
        ),
        size: const Size(320, 1600),
        scale: 1.3,
        palette: p,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('You are here'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(2));
      expect(find.text('Start Ride'), findsOneWidget);
    });
  }

  testWidgets('LoadingState keeps the old content visible while loading', (tester) async {
    await render(tester, const LoadingState(loading: true, child: Text('Old data')));
    expect(find.text('Old data'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await render(tester, const LoadingState(loading: true, hasData: false, child: Text('Old data')));
    expect(find.text('Old data'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await render(tester, const LoadingState(loading: false, child: Text('Old data')));
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('showAppSheet shows the title and the content', (tester) async {
    await render(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showAppSheet<void>(context, title: 'Rider', builder: (_) => const Text('Sheet body')),
          child: const Text('Open'),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Rider'), findsOneWidget);
    expect(find.text('Sheet body'), findsOneWidget);
  });

  group('confirmAction', () {
    Future<bool?> run(WidgetTester tester, Future<void> Function() answer) async {
      bool? result;
      await render(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await confirmAction(
                context,
                title: 'End ride?',
                message: 'Your live location sharing with this group will stop.',
                confirmLabel: 'End Ride',
                destructive: true,
              );
            },
            child: const Text('Open'),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('End ride?'), findsOneWidget);
      await answer();
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('returns true on confirm', (tester) async {
      expect(await run(tester, () => tester.tap(find.text('End Ride'))), isTrue);
    });

    testWidgets('returns false on cancel', (tester) async {
      expect(await run(tester, () => tester.tap(find.text('Cancel'))), isFalse);
    });

    testWidgets('returns false when dismissed outside', (tester) async {
      expect(await run(tester, () => tester.tapAt(const Offset(5, 5))), isFalse);
    });
  });
}

void _noop() {}
