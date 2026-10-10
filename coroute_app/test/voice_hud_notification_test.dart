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
import 'package:coroute_app/presentation/safety/safety_settings_sheet.dart';

class MockVoiceEngine implements VoiceEngine, VoiceEngineLanguage {
  final List<String> spokenLines = [];
  final List<(String, bool)> spokenCalls = [];
  bool initResult = true;

  @override
  String language = 'en';

  @override
  Future<bool> init() async => initResult;

  @override
  Future<bool> speak(String text, {required bool interrupt, required String id}) async {
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

  group('SettingsService voiceAnnounceAllAlerts and mapAlertDismissSeconds', () {
    test('default settings values are voiceAnnounceAllAlerts=true and mapAlertDismissSeconds=5', () async {
      final s = SettingsService();
      await s.load();
      expect(s.voiceAnnounceAllAlerts, isTrue);
      expect(s.mapAlertDismissSeconds, 5);
    });

    test('updating voiceAnnounceAllAlerts notifies listeners and persists', () async {
      final s = SettingsService();
      await s.load();
      var notified = false;
      s.addListener(() => notified = true);

      await s.setVoiceAnnounceAllAlerts(false);
      expect(s.voiceAnnounceAllAlerts, isFalse);
      expect(notified, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(NetworkConstants.keyVoiceAnnounceAllAlerts), isFalse);
    });

    test('updating mapAlertDismissSeconds notifies listeners and persists', () async {
      final s = SettingsService();
      await s.load();
      var notified = false;
      s.addListener(() => notified = true);

      await s.setMapAlertDismissSeconds(8);
      expect(s.mapAlertDismissSeconds, 8);
      expect(notified, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(NetworkConstants.keyMapAlertDismissSeconds), 8);

      // Clamping negative values to 0 (manual mode).
      await s.setMapAlertDismissSeconds(-5);
      expect(s.mapAlertDismissSeconds, 0);
    });

    test('settings load restores persisted values', () async {
      SharedPreferences.setMockInitialValues({
        NetworkConstants.keyVoiceAnnounceAllAlerts: false,
        NetworkConstants.keyMapAlertDismissSeconds: 12,
      });

      final s = SettingsService();
      await s.load();
      expect(s.voiceAnnounceAllAlerts, isFalse);
      expect(s.mapAlertDismissSeconds, 12);
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
      final alertService = AlertService(convoys, timeline, voice: voice, settings: s);

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

    test('suppresses non-critical alerts when voiceAnnounceAllAlerts is false', () async {
      final s = SettingsService();
      await s.load();
      await s.setVoiceAnnounceAllAlerts(false);

      final engine = MockVoiceEngine();
      final voice = VoiceService(s, engine: engine);
      final convoys = FakeConvoyService()..settings = s;
      final timeline = FakeTimelineService();
      final alertService = AlertService(convoys, timeline, voice: voice, settings: s);

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

      // Critical alert still speaks if voiceCritical is on.
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
      final alertService = AlertService(convoys, timeline, voice: voice, settings: s);

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
    testWidgets('SafetySettingsSheet renders Announce all alerts and duration selector', (tester) async {
      final s = SettingsService();
      await s.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeFor(AppPalette.dark),
          home: Scaffold(
            body: MultiProvider(
              providers: [
                ChangeNotifierProvider<SettingsService>.value(value: s),
                Provider<AuthService?>.value(value: null),
                Provider<ConvoyService?>.value(value: null),
              ],
              child: const SingleChildScrollView(child: SafetySettingsSheet()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Find "Announce all alerts" switch.
      final voiceSwitch = find.text('Announce all alerts');
      expect(voiceSwitch, findsOneWidget);

      // Find "Map alert banner duration".
      expect(find.text('Map alert banner duration'), findsOneWidget);
      expect(find.text('5s'), findsWidgets);
      expect(find.text('Manual'), findsWidgets);

      // Scroll to and tap on 8s choice chip.
      await tester.ensureVisible(find.text('8s').first);
      await tester.tap(find.text('8s').first);
      await tester.pumpAndSettle();
      expect(s.mapAlertDismissSeconds, 8);

      // Scroll to and tap on Manual choice chip.
      await tester.ensureVisible(find.text('Manual').first);
      await tester.tap(find.text('Manual').first);
      await tester.pumpAndSettle();
      expect(s.mapAlertDismissSeconds, 0);
    });

    testWidgets('AppearanceSheet renders Map HUD duration choices', (tester) async {
      final s = SettingsService();
      await s.load();
      final theme = ThemeController();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeFor(AppPalette.dark),
          home: Scaffold(
            body: MultiProvider(
              providers: [
                ChangeNotifierProvider<SettingsService>.value(value: s),
                ChangeNotifierProvider<ThemeController>.value(value: theme),
              ],
              child: const SingleChildScrollView(child: AppearanceSheet()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Map HUD & Alerts'), findsOneWidget);
      expect(find.text('3s'), findsWidgets);
      expect(find.text('5s'), findsWidgets);

      await tester.tap(find.text('3s').first);
      await tester.pumpAndSettle();
      expect(s.mapAlertDismissSeconds, 3);
    });

    testWidgets('GroupSettingsView renders Announce all alerts and HUD duration choices', (tester) async {
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

      // Find "Announce all alerts" switch.
      expect(find.text('Announce all alerts'), findsOneWidget);

      // Find "Map alert banner duration".
      expect(find.text('Map alert banner duration'), findsOneWidget);
      expect(find.text('12s'), findsWidgets);

      await tester.ensureVisible(find.text('12s').first);
      await tester.tap(find.text('12s').first);
      await tester.pumpAndSettle();
      expect(s.mapAlertDismissSeconds, 12);
    });
  });
}
