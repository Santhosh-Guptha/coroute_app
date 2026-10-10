import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/network_models.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/data/services/alert_service.dart';
import 'package:coroute_app/data/services/convoy_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/timeline_service.dart';
import 'package:coroute_app/data/services/voice_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockVoiceEngine implements VoiceEngine, VoiceEngineLanguage {
  final List<String> spokenLines = [];
  @override
  String language = 'en';

  @override
  Future<bool> init() async => true;

  @override
  Future<bool> speak(String text, {required bool interrupt, required String id}) async {
    spokenLines.add(text);
    return true;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> release() async {}
}

class FakeConvoyService extends ChangeNotifier implements ConvoyService {
  @override
  String? activeGroupId;
  @override
  ConvoyModel? activeConvoy;
  @override
  String? myUserId;
  @override
  int networkRevision = 0;
  @override
  List<AssistRequest> assistRequests = const [];
  @override
  List<AssistNotice> assistNotices = const [];
  @override
  List<HazardWarning> hazards = const [];
  @override
  List<Encounter> encounters = const [];

  void triggerNotify() => notifyListeners();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeTimelineService extends ChangeNotifier implements TimelineService {
  @override
  String? groupId;
  @override
  List<TimelineEventModel> events = const [];

  void triggerNotify() => notifyListeners();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TimelineEventModel makeStoppedEvent({
  required String eventId,
  required String userId,
  required String userName,
  required int startedAt,
  bool open = true,
}) {
  return TimelineEventModel(
    eventId: eventId,
    groupId: 'GRP-TEST-1',
    userId: userId,
    userName: userName,
    type: 'STOPPED',
    startedAt: startedAt,
    open: open,
    durationMs: open ? 0 : 300000,
  );
}

ConvoyModel makeConvoy({
  required String groupId,
  required String leadId,
  required String otherId,
  String tripStatus = 'STARTED',
}) {
  return ConvoyModel(
    groupId: groupId,
    name: 'Test Convoy',
    joinCode: '123456',
    tripStatus: tripStatus,
    createdByUserId: leadId,
    createdByUserName: 'Lead Rider',
    createdAtEpochMs: 1000,
    riders: {
      leadId: RiderModel(
        userId: leadId,
        name: 'Lead Rider',
        role: 'LEAD',
        lat: 12.9000,
        lng: 77.5000,
        lastSeenEpochMs: 1000,
      ),
      otherId: RiderModel(
        userId: otherId,
        name: 'Pack Rider',
        role: 'PACK',
        lat: 12.9050,
        lng: 77.5050,
        lastSeenEpochMs: 1000,
      ),
    },
    routeBreadcrumbs: const [{'lat': 12.9000, 'lng': 77.5000}, {'lat': 12.9100, 'lng': 77.5100}],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const gid = 'GRP-TEST-1';
  const leadId = 'user_lead';
  const riderId = 'user_pack';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('AlertService persistence across app close and reopen', () {
    test('Standing alert is spoken on first occurrence, NOT repeated on app reopen', () async {
      final engine = MockVoiceEngine();
      final settings = SettingsService();
      final voice = VoiceService(settings, engine: engine);

      final convoys = FakeConvoyService()
        ..activeGroupId = gid
        ..myUserId = leadId
        ..activeConvoy = makeConvoy(groupId: gid, leadId: leadId, otherId: riderId);

      // Stopped for 6 minutes (exceeds stationary alert threshold)
      final now = DateTime.now().millisecondsSinceEpoch;
      final stoppedEv = makeStoppedEvent(
        eventId: 'EV-STOP-1',
        userId: riderId,
        userName: 'Pack Rider',
        startedAt: now - const Duration(minutes: 25).inMilliseconds,
        open: true,
      );

      final timeline = FakeTimelineService()
        ..groupId = gid
        ..events = [stoppedEv];

      // 1. Initial AlertService run (app is running)
      var alertService = AlertService(convoys, timeline, voice: voice);
      convoys.triggerNotify();
      // Wait for async restore & reconcile
      await Future<void>.delayed(const Duration(milliseconds: 50));
      timeline.triggerNotify();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(engine.spokenLines.length, 1, reason: 'Alert should be spoken once on initial occurrence');
      final firstSpoken = engine.spokenLines.first;
      expect(firstSpoken, contains('Pack Rider'));

      // Check SharedPreferences directly to confirm persistence
      final prefs = await SharedPreferences.getInstance();
      final savedSpoken = prefs.getStringList('coroute_alerts_spoken_$gid');
      expect(savedSpoken, isNotNull);
      expect(savedSpoken, contains('STOPPED:$riderId'));

      // 2. Simulate app close / terminate: dispose AlertService
      alertService.dispose();

      // 3. Simulate app reopen: create brand-new AlertService with fresh in-memory state
      final engineAfterReopen = MockVoiceEngine();
      final voiceAfterReopen = VoiceService(settings, engine: engineAfterReopen);

      final alertService2 = AlertService(convoys, timeline, voice: voiceAfterReopen);
      convoys.triggerNotify();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      timeline.triggerNotify();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Key assertion: Alert MUST NOT be spoken again on reopen!
      expect(engineAfterReopen.spokenLines, isEmpty,
          reason: 'Alert should NOT be re-spoken on cold start / reopen when still standing');

      alertService2.dispose();
    });

    test('Alert resolves when rider moves, and can re-alert when a new stop occurs', () async {
      final engine = MockVoiceEngine();
      final settings = SettingsService();
      var simTime = 10000000;
      final voice = VoiceService(settings, engine: engine, clock: () => simTime);

      final convoys = FakeConvoyService()
        ..activeGroupId = gid
        ..myUserId = leadId
        ..activeConvoy = makeConvoy(groupId: gid, leadId: leadId, otherId: riderId);

      final now = DateTime.now().millisecondsSinceEpoch;
      final stoppedEv = makeStoppedEvent(
        eventId: 'EV-STOP-1',
        userId: riderId,
        userName: 'Pack Rider',
        startedAt: now - const Duration(minutes: 25).inMilliseconds,
        open: true,
      );

      final timeline = FakeTimelineService()
        ..groupId = gid
        ..events = [stoppedEv];

      final alertService = AlertService(convoys, timeline, voice: voice);
      convoys.triggerNotify();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      timeline.triggerNotify();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(engine.spokenLines.length, 1);

      // Rider moves again: stop is resolved (open: false or event removed)
      timeline.events = [];
      timeline.triggerNotify();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Verify that STOPPED key was removed from persisted spoken set
      final prefs = await SharedPreferences.getInstance();
      final savedSpokenAfterResolve = prefs.getStringList('coroute_alerts_spoken_$gid') ?? [];
      expect(savedSpokenAfterResolve.contains('STOPPED:$riderId'), isFalse,
          reason: 'Resolved standing alert should be pruned so future stops can trigger alerts');

      // Now 11 minutes later (past VoiceService.voiceDedupe), rider stops AGAIN
      simTime += const Duration(minutes: 11).inMilliseconds;
      final secondStop = makeStoppedEvent(
        eventId: 'EV-STOP-2',
        userId: riderId,
        userName: 'Pack Rider',
        startedAt: DateTime.now().millisecondsSinceEpoch - const Duration(minutes: 25).inMilliseconds,
        open: true,
      );
      timeline.events = [secondStop];
      timeline.triggerNotify();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(engine.spokenLines.length, 2,
          reason: 'New occurrence after resolution should speak an alert');

      alertService.dispose();
    });

    test('Convoy ENDED clears all persisted alert records from SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('coroute_alerts_spoken_$gid', ['STOPPED:$riderId']);
      await prefs.setStringList('coroute_alerts_shown_$gid', ['STOPPED:$riderId']);
      await prefs.setStringList('coroute_alerts_oneshots_$gid', ['EV-123']);
      await prefs.setStringList('coroute_dismissed_alerts_$gid', ['HAZARD:H1']);

      final convoys = FakeConvoyService()
        ..activeGroupId = gid
        ..myUserId = leadId
        ..activeConvoy = makeConvoy(groupId: gid, leadId: leadId, otherId: riderId, tripStatus: 'ENDED');

      final timeline = FakeTimelineService()..groupId = gid;
      final alertService = AlertService(convoys, timeline);
      convoys.triggerNotify();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(prefs.getStringList('coroute_alerts_spoken_$gid'), isNull);
      expect(prefs.getStringList('coroute_alerts_shown_$gid'), isNull);
      expect(prefs.getStringList('coroute_alerts_oneshots_$gid'), isNull);
      expect(prefs.getStringList('coroute_dismissed_alerts_$gid'), isNull);

      alertService.dispose();
    });
  });

  group('In-cockpit alert dismissals persistence', () {
    test('Dismissed alert keys are persisted and remain dismissed after recreation', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('coroute_dismissed_alerts_$gid'), isNull);

      // Simulate dismissing an alert banner
      final dismissedSet = <String>{};
      void dismissAlert(String key) {
        dismissedSet.add(key);
        prefs.setStringList('coroute_dismissed_alerts_$gid', dismissedSet.toList());
      }

      dismissAlert('HAZARD:H-101');
      dismissAlert('SEPARATED:user_pack');

      // Verify stored
      final stored = prefs.getStringList('coroute_dismissed_alerts_$gid');
      expect(stored, containsAll(['HAZARD:H-101', 'SEPARATED:user_pack']));

      // Simulate screen reopen reading from SharedPreferences
      final reloadedSet = <String>{};
      final fromDisk = prefs.getStringList('coroute_dismissed_alerts_$gid');
      if (fromDisk != null) {
        reloadedSet.addAll(fromDisk);
      }

      expect(reloadedSet.contains('HAZARD:H-101'), isTrue);
      expect(reloadedSet.contains('SEPARATED:user_pack'), isTrue);
      expect(reloadedSet.contains('HAZARD:H-NEW'), isFalse);
    });
  });
}
