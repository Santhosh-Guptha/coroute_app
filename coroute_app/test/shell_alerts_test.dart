import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/ui/ui.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/domain/notify/alert_policy.dart';
import 'package:coroute_app/presentation/account/profile_form.dart';
import 'package:coroute_app/presentation/alerts/alert_tiers.dart';
import 'package:coroute_app/presentation/home/ride_start_view.dart';
import 'package:coroute_app/presentation/onboarding/onboarding_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => AppTheme.use(AppPalette.dark));

  group('Alert tiers (same rules as the notifications)', () {
    test('keys and channels map to the brief tiers', () {
      AlertSpec spec(String key, AlertChannel ch) => AlertSpec(key, ch, 't', 'b');
      expect(tierFor(spec('SOS:a1', AlertChannel.sos)), AlertTier.critical);
      expect(tierFor(spec('OFFLINE:u1', AlertChannel.alerts)), AlertTier.critical);
      expect(tierFor(spec('SEPARATED:u1', AlertChannel.alerts)), AlertTier.critical);
      expect(tierFor(spec('STOPPED:u1', AlertChannel.alerts)), AlertTier.important);
      expect(tierFor(spec('OFF_ROUTE:u1', AlertChannel.updates)), AlertTier.important);
      expect(tierFor(spec('EV:overspeed', AlertChannel.alerts)), AlertTier.important);
      expect(tierFor(spec('EV:stop', AlertChannel.updates)), AlertTier.normal);
      expect(tierFor(spec('EV:joined', AlertChannel.activity)), AlertTier.normal);
    });

    test('each situation appears once, critical first, my own SOS left out', () {
      const now = 1800000000000;
      final events = [
        TimelineEventModel(eventId: 'e1', groupId: 'G', userId: 'u_b', userName: 'Bala', type: 'SOS', startedAt: now - 60000, open: true, data: const {'alertId': 'A1'}),
        // The same SOS seen twice (echo): still one alert.
        TimelineEventModel(eventId: 'e2', groupId: 'G', userId: 'u_b', userName: 'Bala', type: 'SOS', startedAt: now - 50000, open: true, data: const {'alertId': 'A1'}),
        TimelineEventModel(eventId: 'e3', groupId: 'G', userId: 'u_me', userName: 'Me', type: 'SOS', startedAt: now - 40000, open: true, data: const {'alertId': 'A2'}),
        TimelineEventModel(eventId: 'e4', groupId: 'G', userId: 'u_c', userName: 'Chitra', type: 'STOPPED', startedAt: now - 25 * 60000, open: true),
        TimelineEventModel(eventId: 'e5', groupId: 'G', userId: 'u_d', userName: 'Dev', type: 'JOINED', startedAt: now - 120000),
        // Too old for the recent list.
        TimelineEventModel(eventId: 'e6', groupId: 'G', userId: 'u_e', userName: 'Esha', type: 'JOINED', startedAt: now - 3 * 3600000),
      ];
      final alerts = inAppAlerts(events, const AlertViewer(userId: 'u_me', isLead: true), nowMs: now);
      expect(alerts.map((a) => a.key).toList(), ['SOS:A1', 'STOPPED:u_c', 'EV:e5']);
      expect(alerts.map((a) => a.tier).toList(), [AlertTier.critical, AlertTier.important, AlertTier.normal]);
      expect(alerts.first.userId, 'u_b');
      expect(alerts.first.standing, isTrue);
      expect(alerts.last.standing, isFalse);
      expect(alertBadgeCount(alerts), 2);
      expect(alertBadgeCount(alerts, local: 1), 3);
    });

    test('a pack rider is not told about long stops (lead and sweeper only)', () {
      const now = 1800000000000;
      final events = [
        TimelineEventModel(eventId: 'e4', groupId: 'G', userId: 'u_c', userName: 'Chitra', type: 'STOPPED', startedAt: now - 25 * 60000, open: true),
      ];
      expect(inAppAlerts(events, const AlertViewer(userId: 'u_me'), nowMs: now), isEmpty);
    });
  });

  group('Profile form rules', () {
    test('every safety detail is checked, pillion needs no plate', () {
      String? v({String name = 'Asha', String phone = '9876543210', bool pillion = false, String plate = 'KA01', String cn = 'Ravi', String cp = '9123456780'}) =>
          ProfileForm.validate(name: name, phone: phone, pillion: pillion, vehicleNo: plate, contactName: cn, contactPhone: cp);
      expect(v(), isNull);
      expect(v(name: 'A'), isNotNull);
      expect(v(phone: '123'), isNotNull);
      expect(v(plate: ''), isNotNull);
      expect(v(plate: '', pillion: true), isNull);
      expect(v(cn: ''), isNotNull);
      expect(v(cp: '12'), isNotNull);
      expect(ProfileForm.vehicleTypes.contains(ProfileForm.pillionType), isFalse, reason: 'pillion is a switch, not a vehicle');
    });
  });

  group('Shell screens fit 320 dp at text x1.3', () {
    Future<void> render(WidgetTester tester, Widget child, AppPalette p, {List<SingleChildWidget> providers = const []}) async {
      AppTheme.use(p);
      const size = Size(320, 568);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = MaterialApp(
        theme: AppTheme.themeFor(p),
        home: MediaQuery(data: MediaQueryData(size: size, textScaler: TextScaler.linear(1.3)), child: child),
      );
      await tester.pumpWidget(providers.isEmpty ? app : MultiProvider(providers: providers, child: app));
      await tester.pump();
    }

    for (final p in [AppPalette.dark, AppPalette.light]) {
      final label = p.isLight ? 'light' : 'dark';

      testWidgets('onboarding: $label', (tester) async {
        await render(tester, const OnboardingScreen(), p);
        expect(tester.takeException(), isNull);
        expect(find.text('Ride Together'), findsOneWidget);
        expect(find.text('Skip'), findsOneWidget);
        expect(find.text('Next'), findsOneWidget);
      });

      testWidgets('no active ride, profile incomplete: $label', (tester) async {
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({});
        final api = ApiClient(httpClient: MockClient((_) async => http.Response('{}', 404)), storage: const FlutterSecureStorage());
        final auth = AuthService(api);
        await render(tester, const RideStartView(), p, providers: [ChangeNotifierProvider<AuthService>.value(value: auth)]);
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        expect(find.text('No active ride'), findsOneWidget);
        expect(find.text('Start Ride'), findsOneWidget);
        expect(find.text('Join Ride'), findsOneWidget);
        // At most one alert: the safety details.
        expect(find.byType(RideAlert), findsOneWidget);
        expect(find.text('Add your safety details'), findsOneWidget);
      });
    }
  });
}
