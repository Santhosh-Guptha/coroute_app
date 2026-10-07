import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/theme/sun_times.dart';
import 'package:coroute_app/core/theme/theme_controller.dart';
import 'package:coroute_app/core/widgets/cockpit_hud.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/data/services/intercom_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/presentation/account/appearance_sheet.dart';
import 'package:coroute_app/presentation/timeline/member_colors.dart';
import 'package:coroute_app/presentation/timeline/timeline_list.dart';
import 'package:coroute_app/presentation/widgets/connection_banner.dart';
import 'package:coroute_app/presentation/widgets/intercom_dock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => AppTheme.use(AppPalette.dark));

  group('Sunrise and sunset', () {
    test('Hyderabad, 5 Oct 2026: about 06:06 and 18:02 IST', () {
      final s = SunTimes.forDay(DateTime(2026, 10, 5), 17.385, 78.4867)!;
      const ist = Duration(hours: 5, minutes: 30);
      final rise = s.sunrise.add(ist), set = s.sunset.add(ist);
      expect((rise.hour * 60 + rise.minute - (6 * 60 + 6)).abs(), lessThanOrEqualTo(3));
      expect((set.hour * 60 + set.minute - (18 * 60 + 2)).abs(), lessThanOrEqualTo(3));
    });

    test('day at noon, night at midnight, and the next change is ahead', () {
      final noon = DateTime.utc(2026, 10, 5, 6, 30); // 12:00 IST
      final night = DateTime.utc(2026, 10, 4, 18, 30); // 00:00 IST
      final d = SunTimes.state(noon, 17.385, 78.4867);
      final n = SunTimes.state(night, 17.385, 78.4867);
      expect(d.day, isTrue);
      expect(n.day, isFalse);
      expect(d.nextChange.isAfter(noon), isTrue);
      expect(n.nextChange.isAfter(night), isTrue);
    });
  });

  group('Theme switching', () {
    test('colour names follow the active palette', () {
      AppTheme.use(AppPalette.light);
      expect(AppTheme.textPrimary, AppPalette.light.textPrimary);
      expect(AppTheme.isLight, isTrue);
      AppTheme.use(AppPalette.dark);
      expect(AppTheme.obsidianVoid, AppPalette.dark.obsidianVoid);
    });

    test('rider colours keep their slot when the theme changes', () {
      final c = MemberColors.assign(['a', 'b', 'c', 'a', '']);
      expect(c.length, 3);
      expect(c['b'], AppPalette.dark.members[1]);
      AppTheme.use(AppPalette.light);
      expect(c['b'], AppPalette.light.members[1]);
    });

    test('the choice is saved and applied', () async {
      SharedPreferences.setMockInitialValues({'theme.preference': 'light'});
      final t = ThemeController(prefs: await SharedPreferences.getInstance());
      await t.load();
      expect(t.preference, ThemePreference.light);
      expect(AppTheme.isLight, isTrue);
      await t.setPreference(ThemePreference.dark);
      expect(AppTheme.isLight, isFalse);
      expect((await SharedPreferences.getInstance()).getString('theme.preference'), 'dark');
      t.dispose();
    });
  });

  group('Layouts fit every screen', () {
    const sizes = <String, Size>{
      'small phone 320x568': Size(320, 568),
      'phone 360x740': Size(360, 740),
      'large phone 412x915': Size(412, 915),
      'phone landscape 740x360': Size(740, 360),
      'tablet 800x1280': Size(800, 1280),
      'foldable 673x841': Size(673, 841),
    };

    RiderModel rider(String id, String name) => RiderModel(userId: id, name: name, lat: 0, lng: 0, lastSeenEpochMs: 0);
    final convoy = ConvoyModel(
      groupId: 'GRP-TEST',
      name: 'Sunday ride to Srisailam with the whole riding club',
      joinCode: '123456',
      createdByUserId: 'usr_me',
      createdByUserName: 'Me',
      createdAtEpochMs: 0,
      riders: {'usr_me': rider('usr_me', 'Me'), 'usr_other': rider('usr_other', 'Venkata Subramaniam Ramakrishnan')},
    );
    const t0 = 1800000000000;
    final events = [
      TimelineEventModel(eventId: '1', groupId: 'G', userId: 'a', userName: 'Venkata Subramaniam Ramakrishnan', type: 'STOPPED', startedAt: t0, durationMs: 1260000,
          placeName: 'Nagarjuna Sagar - Srisailam Highway, Nalgonda district, Telangana', data: const {'reason': 'MECHANICAL'}),
      TimelineEventModel(eventId: '2', groupId: 'G', userId: 'b', userName: 'Bala', type: 'OVERSPEED', startedAt: t0 + 60000, open: true,
          data: const {'limitKmh': 80, 'maxKmh': 104, 'count': 3}),
      TimelineEventModel(eventId: '3', groupId: 'G', userId: 'c', userName: 'Chitra', type: 'STOP_REACHED', startedAt: t0 + 120000, open: true,
          data: const {'name': 'Hotel Haritha Restaurant and Rest Area, Dornala'}),
    ];

    Future<void> render(WidgetTester tester, Size size, double scale, AppPalette p, Widget child, {List<SingleChildWidget> providers = const []}) async {
      AppTheme.use(p);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = MaterialApp(
        theme: AppTheme.themeFor(p),
        home: MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
          child: Scaffold(body: child),
        ),
      );
      await tester.pumpWidget(providers.isEmpty ? app : MultiProvider(providers: providers, child: app));
      await tester.pump();
    }

    for (final entry in sizes.entries) {
      for (final scale in [1.0, 1.2]) {
        for (final p in [AppPalette.dark, AppPalette.light]) {
          final label = '${entry.key}, text x$scale, ${p.isLight ? 'light' : 'dark'}';

          testWidgets('cockpit speed card: $label', (tester) async {
            await render(tester, entry.value, scale, p,
                const Align(alignment: Alignment.topLeft, child: CockpitHud(speedKmh: 124, heading: 271, batteryLevel: 100, isCharging: true, speedLimitKmh: 80)));
            expect(tester.takeException(), isNull);
            expect(find.text('Over the 80 limit'), findsOneWidget);
          });

          testWidgets('timeline: $label', (tester) async {
            await render(tester, entry.value, scale, p,
                TimelineList(events: events, colors: MemberColors.assign(['a', 'b', 'c']), memberNames: const {'a': 'Venkata Subramaniam Ramakrishnan', 'b': 'Bala', 'c': 'Chitra'}));
            expect(tester.takeException(), isNull);
          });

          testWidgets('radio dock and connection banner: $label', (tester) async {
            final rt = RealtimeService();
            await render(
              tester,
              entry.value,
              scale,
              p,
              Column(children: [const ConnectionBanner(), const Spacer(), IntercomDock(convoy: convoy, me: rider('usr_me', 'Me'))]),
              providers: [
                ChangeNotifierProvider<RealtimeService>.value(value: rt),
                ChangeNotifierProvider(create: (_) => IntercomService(rt)),
              ],
            );
            expect(tester.takeException(), isNull);
          });

          testWidgets('appearance settings: $label', (tester) async {
            SharedPreferences.setMockInitialValues({});
            final t = ThemeController(prefs: await SharedPreferences.getInstance());
            try {
              await t.load();
              AppTheme.use(p);
              await render(tester, entry.value, scale, p, const SingleChildScrollView(child: AppearanceSheet()),
                  providers: [ChangeNotifierProvider<ThemeController>.value(value: t)]);
              expect(tester.takeException(), isNull);
              expect(find.text('Automatic'), findsOneWidget);
            } finally {
              t.dispose();
            }
          });
        }
      }
    }
  });
}
