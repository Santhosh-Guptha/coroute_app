// Round 7 (UX / performance): responsive layout tests. No goldens: sizes, positions and "no
// overflow" at 320x568, 360x800, 412x915, 800x1280 and landscape, at text scale 1.0 and 1.3.
// docs/features_355/motion_and_loading.md. Needs the Flutter SDK (`flutter test`).
import 'dart:convert';

import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/ui/ui.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/crews_service.dart';
import 'package:coroute_app/domain/score/rider_score.dart';
import 'package:coroute_app/presentation/score/leaderboard_screen.dart';
import 'package:coroute_app/presentation/social/crew_detail_screen.dart';
import 'package:coroute_app/presentation/social/user_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Map<String, Size> kSizes = {
  'small phone 320x568': Size(320, 568),
  'phone 360x800': Size(360, 800),
  'large phone 412x915': Size(412, 915),
  'tablet 800x1280': Size(800, 1280),
  'landscape phone 915x412': Size(915, 412),
  'landscape small 568x320': Size(568, 320),
};

const String kLong = 'A very long rider or crew name that does not fit on one line of a small phone';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppMotion.batterySaver.value = false;
    SwrCache.shared.clear();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    SwrCache.shared.clear();
    AppTheme.use(AppPalette.dark);
  });

  Future<void> pumpAt(WidgetTester tester, Widget home, Size size, {double scale = 1.0}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(AppPalette.dark),
      scrollBehavior: const AppScrollBehavior(),
      // The same clamp as the app (lib/main.dart): large text is honoured up to 1.3x.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(AdaptiveSpec.clampTextScale(scale))),
        child: child!,
      ),
      home: home,
    ));
    await tester.pump();
  }

  group('adaptive helper', () {
    testWidgets('window class, gutter and panes at each size', (tester) async {
      final expected = <String, (WindowClass, bool, bool)>{
        'small phone 320x568': (WindowClass.compact, false, false),
        'phone 360x800': (WindowClass.normal, false, false),
        'large phone 412x915': (WindowClass.normal, false, false),
        'tablet 800x1280': (WindowClass.large, true, false),
        'landscape phone 915x412': (WindowClass.large, true, true),
        'landscape small 568x320': (WindowClass.normal, false, true),
      };
      for (final e in kSizes.entries) {
        late Adaptive a;
        await pumpAt(tester, Builder(builder: (ctx) {
          a = Adaptive.of(ctx);
          return const SizedBox();
        }), e.value);
        final (cls, two, land) = expected[e.key]!;
        expect(a.windowClass, cls, reason: e.key);
        expect(a.twoPane, two, reason: e.key);
        expect(a.landscape, land, reason: e.key);
        expect(a.gutter, AdaptiveSpec.gutter(e.value.width));
        expect(a.pick(compact: 1, normal: 2, large: 3), cls == WindowClass.compact ? 1 : (cls == WindowClass.normal ? 2 : 3));
        // The page column is never wider than 640 dp and never touches the edges.
        final pad = a.pagePadding();
        expect(e.value.width - pad.horizontal, lessThanOrEqualTo(AdaptiveSpec.maxContentWidth));
        expect(pad.left, greaterThanOrEqualTo(12));
      }
    });

    testWidgets('text scale is capped at 1.3 in Adaptive', (tester) async {
      late Adaptive a;
      await pumpAt(tester, Builder(builder: (ctx) {
        a = Adaptive.of(ctx);
        return const SizedBox();
      }), const Size(360, 800), scale: 2.0);
      expect(a.textScale, closeTo(1.3, 0.001));
      expect(a.bigText, isTrue);
    });

    testWidgets('TwoPane: one pane on phones, list + detail on tablets and in landscape', (tester) async {
      for (final e in kSizes.entries) {
        await pumpAt(tester, const Scaffold(body: TwoPane(list: Text('LIST'), detail: Text('DETAIL'))), e.value);
        final two = AdaptiveSpec.twoPane(e.value.width);
        expect(find.text('LIST'), findsOneWidget, reason: e.key);
        expect(find.text('DETAIL'), two ? findsOneWidget : findsNothing, reason: e.key);
        if (two) {
          final listRight = tester.getTopLeft(find.text('DETAIL')).dx;
          expect(listRight, closeTo(AdaptiveSpec.listPaneWidth(e.value.width) + 1, 0.5), reason: e.key);
        }
        expect(tester.takeException(), isNull, reason: e.key);
      }
    });

    testWidgets('ContentWidth centres and caps the column', (tester) async {
      await pumpAt(tester, const Scaffold(body: ContentWidth(child: SizedBox(key: Key('col'), width: double.infinity, height: 10))), const Size(800, 1280));
      expect(tester.getSize(find.byKey(const Key('col'))).width, 640);
      expect(tester.getTopLeft(find.byKey(const Key('col'))).dx, 80);
      await pumpAt(tester, const Scaffold(body: ContentWidth(child: SizedBox(key: Key('col'), width: double.infinity, height: 10))), const Size(320, 568));
      expect(tester.getSize(find.byKey(const Key('col'))).width, 320);
    });

    testWidgets('tap targets are at least 48 dp', (tester) async {
      await pumpAt(
        tester,
        Scaffold(
          body: Column(children: [
            const MinTapTarget(key: Key('tiny'), child: Icon(Icons.close, size: 16)),
            DsRoundButton(key: const Key('back'), icon: Icons.chevron_left_rounded, label: 'Back', size: 48, onTap: () {}),
            AsyncButton(key: const Key('async'), label: 'Save', onPressed: () async {}),
            DsButton(key: const Key('ds'), label: 'Save', onPressed: () {}),
          ]),
        ),
        const Size(320, 568),
      );
      for (final k in ['tiny', 'back', 'async', 'ds']) {
        final s = tester.getSize(find.byKey(Key(k)));
        expect(s.height, greaterThanOrEqualTo(48), reason: k);
        expect(s.width, greaterThanOrEqualTo(48), reason: k);
      }
    });

    testWidgets('AdaptiveRow moves the trailing part under the text on narrow windows and with big text', (tester) async {
      Widget row() => const Scaffold(body: AdaptiveRow(leading: Icon(Icons.person), body: Text('BODY'), trailing: Text('TRAIL')));
      await pumpAt(tester, row(), const Size(412, 915));
      expect(tester.getTopLeft(find.text('TRAIL')).dy, closeTo(tester.getTopLeft(find.text('BODY')).dy, 6));
      await pumpAt(tester, row(), const Size(320, 568));
      expect(tester.getTopLeft(find.text('TRAIL')).dy, greaterThan(tester.getBottomLeft(find.text('BODY')).dy));
      await pumpAt(tester, row(), const Size(360, 800), scale: 1.3);
      expect(tester.getTopLeft(find.text('TRAIL')).dy, greaterThan(tester.getBottomLeft(find.text('BODY')).dy));
    });

    testWidgets('BottomActionBar: side by side when there is room, stacked on small phones and with big text; inside the safe area', (tester) async {
      Widget bar() => Scaffold(
            body: const SizedBox.expand(),
            bottomNavigationBar: BottomActionBar(children: [
              AsyncButton(key: const Key('a'), label: 'Decline', outlined: true, onPressed: () async {}),
              AsyncButton(key: const Key('b'), label: 'Join the ride', onPressed: () async {}),
            ]),
          );
      await pumpAt(tester, bar(), const Size(412, 915));
      expect(tester.getTopLeft(find.byKey(const Key('a'))).dy, tester.getTopLeft(find.byKey(const Key('b'))).dy);
      await pumpAt(tester, bar(), const Size(320, 568));
      expect(tester.getTopLeft(find.byKey(const Key('b'))).dy, greaterThan(tester.getTopLeft(find.byKey(const Key('a'))).dy));
      await pumpAt(tester, bar(), const Size(412, 915), scale: 1.3);
      expect(tester.getTopLeft(find.byKey(const Key('b'))).dy, greaterThan(tester.getTopLeft(find.byKey(const Key('a'))).dy));
      // One-hand reach: the primary action sits in the bottom third of the screen.
      expect(tester.getCenter(find.byKey(const Key('b'))).dy, greaterThan(915 * 2 / 3));
      expect(tester.takeException(), isNull);
    });
  });

  group('no overflow with long names at text scale 1.0 and 1.3', () {
    Widget gallery() => Scaffold(
          body: SafeArea(
            child: ListView(
              padding: dsScreenPadding,
              children: [
                DsScreenHeader(title: kLong, subtitle: kLong, onBack: () {}, trailing: DsRoundButton(icon: Icons.tune_rounded, label: 'Settings', size: 48, onTap: () {})),
                const SizedBox(height: 12),
                const DsSectionHeader(kLong, trailing: DsChip('Lead')),
                DsCard(onTap: () {}, child: const Text(kLong)),
                DsListRow(icon: Icons.two_wheeler_rounded, label: kLong, value: kLong, onTap: () {}),
                DsSwitchRow(label: kLong, subtitle: kLong, value: true, onChanged: (_) {}),
                DsSegment<int>(values: const [0, 1, 2], selected: 1, label: (_) => 'Convoy riders only', onChanged: (_) {}),
                const SizedBox(height: 12),
                DsButton(label: kLong, icon: Icons.play_arrow_rounded, onPressed: () {}),
                const SizedBox(height: 12),
                DsButton(label: kLong, onPressed: () {}, loading: true),
                const SizedBox(height: 12),
                AsyncButton(label: kLong, icon: Icons.group_add_rounded, onPressed: () async {}),
                const SizedBox(height: 12),
                AdaptiveRow(
                  leading: const UserAvatar(label: kLong, size: 44),
                  body: const Text(kLong, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: AsyncButton(label: 'Add friend', height: 48, onPressed: () async {}),
                ),
                const SizedBox(height: 12),
                const Row(children: [Expanded(child: AnimatedCount(128456, suffix: ' km')), Expanded(child: AnimatedCount(98.5, decimals: 1))]),
                const SizedBox(height: 12),
                const SkeletonProfile(),
                const SkeletonCards(count: 2, stats: true),
                const SkeletonRows(count: 2, trailing: true),
                const ErrorState(title: kLong, message: kLong, onRetry: _noop),
                const TopProgressLine(active: true),
              ],
            ),
          ),
          bottomNavigationBar: BottomActionBar(children: [
            AsyncButton(label: 'Not now, maybe later', outlined: true, onPressed: () async {}),
            AsyncButton(label: 'Join the ride with my crew', onPressed: () async {}),
          ]),
        );

    for (final e in kSizes.entries) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('UI kit + loaders: ${e.key} @ $scale', (tester) async {
          await pumpAt(tester, gallery(), e.value, scale: scale);
          expect(tester.takeException(), isNull);
          // Scroll through everything: rows further down are laid out too.
          for (var i = 0; i < 8; i++) {
            await tester.drag(find.byType(ListView).first, const Offset(0, -500), warnIfMissed: false);
            await tester.pump(const Duration(milliseconds: 50));
            expect(tester.takeException(), isNull, reason: 'after scroll $i');
          }
          await tester.pumpWidget(const SizedBox());
        });
      }
    }

    for (final e in kSizes.entries) {
      testWidgets('poll card: ${e.key} @ 1.3', (tester) async {
        const poll = CrewPoll(
          pollId: 'p1',
          question: 'Which route do we take on Sunday morning if the coast road is still closed after the rain?',
          options: [
            PollOption(id: 'a', text: 'The long coast road through the fishing villages with a breakfast stop', count: 7, percent: 70),
            PollOption(id: 'b', text: 'Hill road', count: 3, percent: 30),
          ],
          totalVoters: 10,
          createdBy: 'a_rider_with_a_long_username',
          closesAt: 4102444800000,
          myVote: ['b'],
        );
        await pumpAt(tester, Scaffold(body: SingleChildScrollView(padding: dsScreenPadding, child: PollCard(poll: poll, onVote: (_) => null, onMore: () {}))), e.value, scale: 1.3);
        expect(tester.takeException(), isNull);
      });
    }

    for (final e in kSizes.entries) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('leaderboard screen (cached rows shown at once): ${e.key} @ $scale', (tester) async {
          SwrCache.shared.put<Leaderboard>(
            'leaderboard',
            Leaderboard(boards: {
              for (final b in LeaderboardBoard.values)
                b: [
                  const LeaderboardRow('a_rider_with_the_longest_username_allowed', 98765, rides: 1234),
                  for (var i = 0; i < 12; i++) LeaderboardRow('rider_$i', 90 - i, rides: 20 + i),
                ],
            }),
          );
          final api = ApiClient(httpClient: MockClient((req) async => http.Response(jsonEncode({'error': 'offline'}), 503)), storage: const FlutterSecureStorage());
          tester.view.physicalSize = e.value;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(ChangeNotifierProvider<ApiClient>.value(
            value: api,
            child: MaterialApp(
              theme: AppTheme.themeFor(AppPalette.dark),
              builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
              home: const LeaderboardScreen(),
            ),
          ));
          // First frame: the cached leaderboard, not a spinner and not a skeleton.
          expect(find.text('a_rider_with_the_longest_username_allowed'), findsOneWidget);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(find.byType(SkeletonListTile), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pump(const Duration(seconds: 1));
          await tester.pump(const Duration(seconds: 15));
          // The refresh failed: the old rows stay.
          expect(find.text('a_rider_with_the_longest_username_allowed'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 15));
        });
      }
    }

    testWidgets('leaderboard screen without a cache: rows-shaped skeleton, then the error state with Try again', (tester) async {
      final api = ApiClient(httpClient: MockClient((req) async => http.Response(jsonEncode({'error': 'offline'}), 503)), storage: const FlutterSecureStorage());
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ChangeNotifierProvider<ApiClient>.value(
        value: api,
        child: MaterialApp(theme: AppTheme.themeFor(AppPalette.dark), home: const LeaderboardScreen()),
      ));
      expect(find.byType(SkeletonListTile), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byType(SkeletonListTile), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 15));
    });
  });
}

void _noop() {}
