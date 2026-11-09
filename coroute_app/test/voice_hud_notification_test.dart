import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coroute_app/core/constants/network_constants.dart';
import 'package:coroute_app/core/l10n/l10n.dart';
import 'package:coroute_app/core/theme/app_palette.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/core/theme/theme_controller.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/network_models.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/data/services/alert_service.dart';
import 'package:coroute_app/data/services/auth_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/timeline_service.dart';
import 'package:coroute_app/data/services/voice_service.dart';
import 'package:coroute_app/domain/notify/alert_policy.dart';
import 'package:coroute_app/presentation/account/appearance_sheet.dart';
import 'package:coroute_app/presentation/alerts/alert_tiers.dart';
import 'package:coroute_app/presentation/ride/group_settings_sheet.dart';
import 'package:coroute_app/presentation/settings/settings_screen.dart';

class MockVoiceEngine implements VoiceEngine, VoiceEngineLanguage {
  final List<String> spokenLines = [];
  final List<(String, bool)> spokenCalls = [];
  bool initResult = true;

  @override
  String language = 'en';

  @override
  Future<bool> init() async => initResult;

  @override
  Future<bool> speak(
    String text, {
    required bool interrupt,
    required String id,
    bool isEmergency = false,
    bool pauseOthers = false,
  }) async {
    spokenLines.add(text);
    spokenCalls.add((text, interrupt));
    return true;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> release() async {}
}

class FakeConvoyService extends ChangeNotifier implements ConvoyService {
  @override
  String? activeGroupId = 'GRP-TEST-1';

  @override
  ConvoyModel? activeConvoy;

  @override
  String? myUserId = 'user_rider';

  @override
  int networkRevision = 0;

  @override
  bool canEditRoute = true;
  @override
  bool get canChangeGroupSettings => canEditRoute;
  @override
  bool get isSettingsOnlyTripHead => false;
  @override
  bool get canEndTrip => canEditRoute;

  @override
  bool isOnline = true;

  @override
  bool isRealGpsActive = true;

  @override
  String? lastError;

  @override
  Map<String, ConvoyModel> allConvoys = {};

  @override
  List<AssistRequest> assistRequests = const [];

  @override
  List<AssistNotice> assistNotices = const [];

  @override
  List<HazardWarning> hazards = const [];

  @override
  List<Encounter> encounters = const [];

  @override
  SettingsService? settings;

  @override
  bool supports(String feature) => true;

  @override
  bool get supportsRideRoles => true;

  void triggerNotify() => notifyListeners();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeTimelineService extends ChangeNotifier implements TimelineService {
  @override
  String? groupId = 'GRP-TEST-1';

  @override
  List<TimelineEventModel> events = const [];

  void triggerNotify() => notifyListeners();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ConvoyModel makeConvoy({
  required String groupId,
  required String myId,
  String tripStatus = 'STARTED',
}) {
  return ConvoyModel(
    groupId: groupId,
    name: 'Test Convoy',
    joinCode: '123456',
    tripStatus: tripStatus,
    createdByUserId: myId,
    createdByUserName: 'Lead Rider',
    createdAtEpochMs: 1000,
    voiceGuidanceEnabled: true,
    riders: {
      myId: RiderModel(
        userId: myId,
        name: 'Lead Rider',
        role: 'LEAD',
        lat: 12.9000,
        lng: 77.5000,
        lastSeenEpochMs: 1000,
      ),
    },
    routeBreadcrumbs: const [
      {'lat': 12.9000, 'lng': 77.5000},
      {'lat': 12.9100, 'lng': 77.5100},
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    L10n.setLanguage(AppLanguage.en);
  });

  tearDown(() {
    AppTheme.use(AppPalette.dark);
    L10n.setLanguage(AppLanguage.en);
  });

  // "Announce all alerts" and the map alert time are no longer settings: alerts without
  // their own line are always read out (with Spoken alerts on), and an ordinary alert
  // leaves the map after a fixed time.
  group('Spoken alerts and the map alert time', () {
    test('spoken alerts are on by default and the map alert time is fixed', () async {
      final s = SettingsService();
      await s.load();
      expect(s.voiceWarnings, isTrue);
      expect(NetworkConstants.mapAlertDismissSeconds, 5);
    });
  });

  group('Voice notifications TTS speaking logic', () {
    test('speaks alerts and falls back to title and body when speech text is null', () async {
      final s = SettingsService();
      await s.load();
      final engine = MockVoiceEngine();
      final voice = VoiceService(s, engine: engine);
      final convoys = FakeConvoyService()..settings = s;
      final timeline = FakeTimelineService();
      final alertService = AlertService(convoys, timeline, voice: voice);

      // Alert with explicit speech.
      const specWithSpeech = AlertSpec(
        'STOPPED:u1',
        AlertChannel.alerts,
        'Rider stopped',
        'Stopped for 5 min',
        speech: 'Rahul has been stopped for 5 minutes',
      );
      // Alert with null speech (falls back to title and body).
      const specWithoutSpeech = AlertSpec(
        'EV:overspeed',
        AlertChannel.alerts,
        'Speed alert',
        'Slow down now',
      );

      alertService.speakAlerts([specWithSpeech, specWithoutSpeech]);
      await Future<void>.delayed(Duration.zero);

      expect(engine.spokenLines, contains('Rahul has been stopped for 5 minutes'));
      expect(engine.spokenLines, contains('Speed alert. Slow down now'));

      // Deduplication: re-speaking the same specs does not duplicate.
      final countBefore = engine.spokenLines.length;
      alertService.speakAlerts([specWithSpeech, specWithoutSpeech]);
      await Future<void>.delayed(Duration.zero);
      expect(engine.spokenLines.length, countBefore);

      voice.dispose();
      alertService.dispose();
    });

    test('suppresses non-critical alerts when spoken alerts are off; emergencies still speak', () async {
      final s = SettingsService();
      await s.load();
      await s.setVoiceWarnings(false);

      final engine = MockVoiceEngine();
      final voice = VoiceService(s, engine: engine);
      final convoys = FakeConvoyService()..settings = s;
      final timeline = FakeTimelineService();
      final alertService = AlertService(convoys, timeline, voice: voice);

      // Warning alert without speech.
      const specWarning = AlertSpec(
        'EV:overspeed',
        AlertChannel.updates,
        'Speed alert',
        'Slow down now',
      );

      alertService.speakAlerts([specWarning]);
      await Future<void>.delayed(Duration.zero);
      expect(engine.spokenLines, isEmpty);

      // A critical alert always speaks.
      const specCritical = AlertSpec(
        'SOS:u9',
        AlertChannel.sos,
        'Emergency SOS',
        'Help needed',
        speech: 'Emergency assistance requested',
      );
      alertService.speakAlerts([specCritical]);
      await Future<void>.delayed(Duration.zero);
      expect(engine.spokenLines, contains('Emergency assistance requested'));

      voice.dispose();
      alertService.dispose();
    });

    test('speaks one-shot timeline events aloud via TTS', () async {
      final s = SettingsService();
      await s.load();
      final engine = MockVoiceEngine();
      final voice = VoiceService(s, engine: engine);
      final convoy = makeConvoy(groupId: 'GRP-TEST-1', myId: 'user_rider');
      final convoys = FakeConvoyService()
        ..activeGroupId = 'GRP-TEST-1'
        ..activeConvoy = convoy
        ..myUserId = 'user_rider'
        ..settings = s;
      final timeline = FakeTimelineService()..groupId = 'GRP-TEST-1';
      final alertService = AlertService(convoys, timeline, voice: voice);

      // Initial load with a prior event so subsequent events are live.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      timeline.events = [
        TimelineEventModel(
          eventId: 'ev_init_1',
          groupId: 'GRP-TEST-1',
          userId: 'user_rider',
          userName: 'Lead Rider',
          type: 'JOINED',
          startedAt: nowMs - 10000,
        ),
      ];
      convoys.triggerNotify();
      await alertService.reconcile();

      // Add one-shot live event to timeline.
      timeline.events = [
        ...timeline.events,
        TimelineEventModel(
          eventId: 'ev_overspeed_1',
          groupId: 'GRP-TEST-1',
          userId: 'user_other',
          userName: 'Vikram',
          type: 'OVERSPEED',
          startedAt: nowMs,
          data: const {'maxKmh': 95, 'limitKmh': 80, 'notify': true},
        ),
      ];

      await alertService.reconcile();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(engine.spokenLines.any((line) => line.contains('Vikram is over')), isTrue);

      voice.dispose();
      alertService.dispose();
    });
  });

  group('Map HUD auto-dismiss and notification tray retention', () {
    test('overlay dismissal removes from HUD but retains in notifications list', () async {
      const nowMs = 1800000000000;
      final events = [
        TimelineEventModel(
          eventId: 'e_stopped',
          groupId: 'GRP-TEST-1',
          userId: 'user_other',
          userName: 'Kiran',
          type: 'STOPPED',
          startedAt: nowMs - 25 * 60000,
          open: true,
        ),
      ];

      const viewer = AlertViewer(userId: 'user_rider', isLead: true);
      // Alerts list for the notifications tab.
      final notifications = inAppAlerts(events, viewer, nowMs: nowMs);
      expect(notifications.map((a) => a.key).toList(), ['STOPPED:user_other']);

      // Simulated HUD dismiss set on map screen.
      final dismissedOnHud = <String>{};
      expect(notifications.where((a) => !dismissedOnHud.contains(a.key)), isNotEmpty);

      // Auto-dismiss occurs on the map HUD.
      dismissedOnHud.add('STOPPED:user_other');

      // The HUD has dismissed it.
      final hudVisible = notifications.where((a) => !dismissedOnHud.contains(a.key)).toList();
      expect(hudVisible, isEmpty);

      // But in the notifications tab/tray, the alert remains intact!
      final preservedTrayAlerts = inAppAlerts(events, viewer, nowMs: nowMs);
      expect(preservedTrayAlerts, hasLength(1));
      expect(preservedTrayAlerts.first.key, 'STOPPED:user_other');
      expect(preservedTrayAlerts.first.spec.title, contains('Kiran has been stopped'));
    });
  });

  group('Configuration UI widgets', () {
    testWidgets('Settings has one spoken alerts switch and no alert duration chooser', (tester) async {
      final s = SettingsService();
      await s.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeFor(AppPalette.dark),
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsService>.value(value: s),
              Provider<AuthService?>.value(value: null),
              Provider<ConvoyService?>.value(value: null),
            ],
            child: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings_spoken_alerts')), findsOneWidget);
      expect(find.text('Announce all alerts'), findsNothing);
      expect(find.text('Map alert banner duration'), findsNothing);

      await tester.ensureVisible(find.byKey(const ValueKey('settings_spoken_alerts')));
      await tester.tap(find.byKey(const ValueKey('settings_spoken_alerts')));
      await tester.pumpAndSettle();
      expect(s.voiceWarnings, isFalse);
    });

    testWidgets('AppearanceSheet only chooses the look', (tester) async {
      final theme = ThemeController();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeFor(AppPalette.dark),
          home: Scaffold(
            body: ChangeNotifierProvider<ThemeController>.value(
              value: theme,
              child: const SingleChildScrollView(child: AppearanceSheet()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Automatic'), findsOneWidget);
      expect(find.text('MAP HUD & ALERTS'), findsNothing);
      expect(find.text('3s'), findsNothing);
    });

    testWidgets('GroupSettingsView keeps the group spoken alerts switch and no rider settings', (tester) async {
      final s = SettingsService();
      await s.load();
      final convoy = makeConvoy(groupId: 'GRP-TEST-1', myId: 'user_rider');
      final convoys = FakeConvoyService()
        ..activeConvoy = convoy
        ..allConvoys = {'GRP-TEST-1': convoy}
        ..settings = s;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeFor(AppPalette.dark),
          home: Scaffold(
            body: MultiProvider(
              providers: [
                ChangeNotifierProvider<SettingsService>.value(value: s),
                ChangeNotifierProvider<ConvoyService>.value(value: convoys),
              ],
              child: const SingleChildScrollView(child: GroupSettingsView(convoyId: 'GRP-TEST-1')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Spoken alerts'), findsWidgets);
      expect(find.text('Announce all alerts'), findsNothing);
      expect(find.text('Map alert banner duration'), findsNothing);
      expect(find.text('Lead voice first'), findsNothing);
      expect(find.text('Send stops and regroup points'), findsNothing);
    });
  });
}
