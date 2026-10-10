import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore_for_file: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/emergency_roster.dart';
import 'package:coroute_app/data/models/pending_sos.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/realtime_service.dart';
import 'package:coroute_app/data/services/trip_storage_service.dart';
import 'package:coroute_app/domain/safety/sms_plan.dart';
import 'package:coroute_app/presentation/widgets/emergency_sos_sheet.dart';

class _MockUrlLauncher extends UrlLauncherPlatform with MockPlatformInterfaceMixin {
  final List<String> launched = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

class _OfflineConvoyService extends ConvoyService {
  _OfflineConvoyService(ApiClient api, ConvoyModel convoy)
      : super(api, RealtimeService(), TripStorageService(api)) {
    _activeConvoy = convoy;
  }

  ConvoyModel? _activeConvoy;

  @override
  ConvoyModel? get activeConvoy => _activeConvoy;
  @override
  bool get isOnline => false; // Total cellular / data network outage
  @override
  String? get myOpenSosAlertId => null;
  @override
  PendingSos? get pendingSos => const PendingSos(
        clientId: 'u_me-1000',
        groupId: 'GRP-OUTAGE',
        lat: 12.971598,
        lng: 77.594562,
        type: 'EMERGENCY',
        createdAt: 1000,
      );
}

class _MockAuthService extends AuthService {
  _MockAuthService(super.api, {this.contact = '+91 98765 43210'});
  final String contact;

  @override
  String? get emergencyContact => contact;
  @override
  String? get emergencyContactName => 'Brother';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockUrlLauncher mockLauncher;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    mockLauncher = _MockUrlLauncher();
    UrlLauncherPlatform.instance = mockLauncher;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/charging'),
      (call) async => null,
    );
  });

  group('Scenario F: Indian Emergency Fallback', () {
    const latBangalore = 12.971598;
    const lngBangalore = 77.594562;

    testWidgets('Offline dialing of 108 (Ambulance), 100 (Police), 112 (National Emergency), and SMS', (tester) async {
      tester.view.physicalSize = const Size(400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final api = ApiClient(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        storage: const FlutterSecureStorage(),
      );
      final auth = _MockAuthService(api, contact: '+91 98765 43210');

      final convoy = ConvoyModel(
        groupId: 'GRP-OUTAGE',
        name: 'Nilgiris Ride',
        joinCode: '654321',
        createdByUserId: 'u_lead',
        createdByUserName: 'Lead Rider',
        createdAtEpochMs: 1000,
        riders: {
          'u_me': RiderModel(userId: 'u_me', name: 'Me', lat: latBangalore, lng: lngBangalore, lastSeenEpochMs: 1000),
        },
      );

      final convoys = _OfflineConvoyService(api, convoy);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthService>.value(value: auth),
            ChangeNotifierProvider<ConvoyService>.value(value: convoys),
          ],
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: const Scaffold(
              body: SingleChildScrollView(
                child: EmergencySosSheet(
                  lat: latBangalore,
                  lng: lngBangalore,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify offline state banner & guidance are visible
      expect(find.text('No signal. SOS not sent yet'), findsOneWidget);
      expect(find.textContaining('Call or text your emergency contact below'), findsOneWidget);

      // 1. Dial 108 (Ambulance in India)
      final dial108Btn = find.text('Dial 108 (Ambulance)');
      expect(dial108Btn, findsOneWidget);
      await tester.tap(dial108Btn);
      await tester.pumpAndSettle();
      expect(mockLauncher.launched, contains('tel:108'));

      // 2. Dial 100 (Police in India)
      final dial100Btn = find.text('Dial 100 (Police)');
      expect(dial100Btn, findsOneWidget);
      await tester.tap(dial100Btn);
      await tester.pumpAndSettle();
      expect(mockLauncher.launched, contains('tel:100'));

      // 3. Dial 112 (National Emergency Helpline)
      final dial112Btn = find.text('Dial 112 (emergency services)');
      expect(dial112Btn, findsOneWidget);
      await tester.tap(dial112Btn);
      await tester.pumpAndSettle();
      expect(mockLauncher.launched, contains('tel:112'));

      // 4. Call personal emergency contact directly
      final callContactBtn = find.textContaining('Call Brother');
      expect(callContactBtn, findsOneWidget);
      await tester.tap(callContactBtn);
      await tester.pumpAndSettle();
      expect(mockLauncher.launched, contains('tel:+919876543210'));

      // 5. Pre-composed SMS with 6-decimal sub-meter GPS coordinates
      final sendSmsBtn = find.textContaining('Text my location');
      expect(sendSmsBtn, findsOneWidget);
      await tester.tap(sendSmsBtn);
      await tester.pumpAndSettle();

      final smsUris = mockLauncher.launched.where((u) => u.startsWith('sms:')).toList();
      expect(smsUris, isNotEmpty);
      final smsUri = smsUris.last;
      expect(smsUri, contains('+919876543210'));
      final decodedSms = Uri.decodeComponent(smsUri);
      expect(decodedSms, contains('https://maps.google.com/?q=12.971598,77.594562'));
      expect(decodedSms, contains('Emergency'));
    });

    test('Autonomous offline SMS fallback planner: recipient hierarchy, dedupe, and single-part fit', () {
      const myPos = (12.9716, 77.5946);
      (double, double) posKm(double northKm) => (myPos.$1 + northKm * 0.009, myPos.$2);

      final members = [
        const RosterMember(userId: 'u_pack1', role: 'PACK', phone: '+91 90000 00001'),
        const RosterMember(userId: 'u_sweeper', role: 'SWEEPER', phone: '+91 90000 00002'),
        const RosterMember(userId: 'u_lead', role: 'LEAD', phone: '+91 90000 00003'),
        const RosterMember(userId: 'u_pack2', role: 'PACK', phone: '090000-00001'), // duplicate phone written with 0 prefix & dashes
        const RosterMember(userId: 'u_self', role: 'PACK', phone: '+91 90000 99999'), // myself
      ];

      final roster = EmergencyRoster(
        groupId: 'GRP-OUTAGE',
        fetchedAt: 0,
        validUntil: 1 << 50,
        cap: 10,
        members: members,
        emergencyContact: const RosterContact(name: 'Brother', phone: '+91 91234 56780'),
      );

      final plan = SmsPlanner.plan(
        roster: roster,
        contact: const RosterContact(name: 'Brother', phone: '+91 91234 56780'),
        lastPositions: {
          'u_pack1': posKm(1.5), // 1.5 km away
          'u_sweeper': posKm(0.8), // 0.8 km away
          'u_lead': posKm(3.0), // 3.0 km away
        },
        me: myPos,
        selfUserId: 'u_self',
        selfPhone: '+91 90000 99999',
      );

      // Verify recipient priority:
      // 1. Personal Emergency contact
      // 2. Lead
      // 3. Sweeper
      // 4. Nearest pack members
      expect(plan.recipients.map((r) => r.label).toList(), ['contact', 'lead', 'sweeper', 'rider']);
      expect(plan.recipients[0].phone, '+919123456780');
      expect(plan.recipients[1].phone, '+919000000003');
      expect(plan.recipients[2].phone, '+919000000002');
      expect(plan.recipients[3].phone, '+919000000001');

      // Duplicate phone numbers and self number are eliminated
      expect(plan.recipients.any((r) => r.phone.contains('99999')), isFalse, reason: 'Sender never receives own SOS');
      expect(plan.recipients.where((r) => r.phone == '+919000000001'), hasLength(1), reason: 'Duplicate phone deduplicated');

      // SMS body formatting & size budget
      final time = DateTime(2026, 10, 10, 14, 30);
      final smsBody = SmsText.sos(
        name: 'Rohan',
        auto: true,
        lat: latBangalore,
        lng: lngBangalore,
        at: time,
        convoyName: 'Nandi Hills Convoy',
      );

      expect(smsBody, contains('Rohan'));
      expect(smsBody, contains('crash'));
      expect(smsBody, contains('automatic'));
      expect(smsBody, contains('https://maps.google.com/?q=12.97160,77.59456'));
      expect(smsBody, contains('Nandi Hills Convoy'));

      // Crucial edge case: Body must strictly fit within 1 standard GSM 7-bit SMS part (160 characters)
      // so it delivers immediately over Indian 2G/SMS channels without multi-part reassembly delays!
      expect(SmsText.parts(smsBody), 1, reason: 'Emergency SMS fits in a single SMS part (<= 160 chars)');
    });
  });
}
