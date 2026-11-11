import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/safety_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/sms_sender.dart';
import 'package:coroute_app/domain/safety/crash_detector.dart';
import 'package:coroute_app/domain/safety/emergency_texts.dart';

import 'safety_service_test.dart' show FakeAccel, FakePort, FakeSms, convoyWith, t0;

/// The native queue, in memory: dedupes ids, cancels only waiting jobs, reports on demand.
class FakeTextQueue implements EmergencyTextQueue {
  final List<EmergencyTextJob> jobs = [];
  final Map<String, EmergencyTextStatus> state = {};
  final List<List<String>> cancelled = [];
  final StreamController<List<EmergencyTextStatus>> _ctrl = StreamController<List<EmergencyTextStatus>>.broadcast();

  @override
  Future<List<String>> enqueue(List<EmergencyTextJob> jobs, {required List<int> retryDelaysMs}) async {
    final accepted = <String>[];
    for (final j in jobs) {
      if (state.containsKey(j.id)) continue;
      this.jobs.add(j);
      state[j.id] = EmergencyTextStatus(id: j.id, state: EmergencyTextState.queued);
      accepted.add(j.id);
    }
    return accepted;
  }

  @override
  Future<void> cancel(List<String> ids) async {
    cancelled.add(ids);
    for (final id in ids) {
      if (state[id]?.state == EmergencyTextState.queued) state[id] = EmergencyTextStatus(id: id, state: EmergencyTextState.cancelled);
    }
  }

  @override
  Future<List<EmergencyTextStatus>> statuses() async => state.values.toList();

  @override
  Stream<List<EmergencyTextStatus>> get updates => _ctrl.stream;

  void report(String id, EmergencyTextState s) {
    final next = EmergencyTextStatus(id: id, state: s, attempts: 1, last3: '780');
    state[id] = next;
    _ctrl.add([next]);
  }
}

/// 3.57 phone-first emergency texts through SafetyService: an SOS texts the emergency contact
/// from the phone's queue (once per incident), a cancel in the grace window texts nobody, a
/// resolve after a text went out sends "I'm safe now", a crash goes at once, denied falls back to
/// the messages app, and a test alarm never texts.
void main() {
  late int now;
  late FakePort port;
  late FakeSms sms;
  late FakeTextQueue queue;
  late SettingsService settings;
  late SafetyService safety;

  Future<void> setUp0(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    now = t0;
    port = FakePort(() => now);
    sms = FakeSms();
    queue = FakeTextQueue();
    settings = SettingsService();
    await settings.load();
    safety = SafetyService.forTest(port, settings, accel: FakeAccel(), sms: sms, clock: () => now, texts: queue);
    port.convoy = convoyWith({'me': RiderModel(userId: 'me', name: 'Kiran', lat: 12.97, lng: 77.59, lastSeenEpochMs: t0)});
    port.changed();
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump();
    }
  }

  Future<void> tearDown0(WidgetTester tester) async {
    safety.dispose();
    await port.fixes.close();
    port.dispose();
    await tester.pump();
  }

  testWidgets('an SOS press texts the emergency contact once after 10 s; resolved later: "safe now" once', (tester) async {
    await setUp0(tester);
    await safety.triggerManualSos();
    await settle(tester);
    expect(queue.jobs, hasLength(1));
    final job = queue.jobs.single;
    expect(job.to, '+919123456780');
    expect(job.kind, EmergencyTextKind.alert);
    expect(job.notBeforeMs, now + EmergencyTextPolicy.pressGrace.inMilliseconds);
    expect(job.body, startsWith('CoRoute SOS: Kiran needs help'));
    expect(safety.contactTextsLine, 'Texting your emergency contact from your phone...');

    // The same SOS again (resent, any change): never a second text.
    port.changed();
    await safety.triggerManualSos();
    await settle(tester);
    expect(queue.jobs, hasLength(1));

    queue.report(job.id, EmergencyTextState.delivered);
    await settle(tester);
    expect(safety.contactTextsLine, 'Texted your emergency contact from your phone. Delivered.');

    port.pending = null;
    port.changed();
    safety.noteMySosClosed();
    await settle(tester);
    expect(queue.jobs, hasLength(2));
    expect(queue.jobs.last.kind, EmergencyTextKind.safe);
    expect(queue.jobs.last.to, '+919123456780');
    expect(queue.jobs.last.body, contains('Kiran is safe now'));
    safety.noteMySosClosed(); // the lead's resolve arrives too
    await settle(tester);
    expect(queue.jobs, hasLength(2));
    await tearDown0(tester);
  });

  testWidgets('cancelled within the grace window: the text is cancelled, no "safe now"', (tester) async {
    await setUp0(tester);
    await safety.triggerManualSos();
    await settle(tester);
    final id = queue.jobs.single.id;
    port.pending = null;
    port.changed();
    safety.noteMySosClosed();
    await settle(tester);
    expect(queue.cancelled, [
      [id],
    ]);
    expect(queue.state[id]!.state, EmergencyTextState.cancelled);
    expect(queue.jobs, hasLength(1));
    expect(safety.contactTextsLine, contains('cancelled in time'));
    await tearDown0(tester);
  });

  testWidgets('a crash SOS texts at once and says "may have crashed"', (tester) async {
    await setUp0(tester);
    safety.debugRaiseCrash(CrashEvent(impactAtMs: now - 30000, impactG: 6.2, speedBeforeKmh: 58, lat: 12.97, lng: 77.59));
    safety.alarmSendNow();
    await settle(tester);
    expect(queue.jobs, hasLength(1));
    expect(queue.jobs.single.notBeforeMs, now);
    expect(queue.jobs.single.body, contains('may have crashed'));
    safety.closeAlarm();
    await tearDown0(tester);
  });

  testWidgets('texts not allowed: nothing queued; the line points to the messages app and Safety health', (tester) async {
    await setUp0(tester);
    sms.cap = const SmsCapability(hasTelephony: true, permission: false, simReady: true);
    await safety.triggerManualSos();
    await settle(tester);
    expect(queue.jobs, isEmpty);
    expect(safety.contactTextsLine, EmergencyTextSummary.composerFallback);
    await tearDown0(tester);
  });

  testWidgets('a test alarm (developer impact) never texts anyone', (tester) async {
    await setUp0(tester);
    safety.externalImpact(source: ExternalImpactSource.developer, g: 8.0, atMs: now);
    expect(safety.alarm, isNotNull);
    safety.alarmSendNow();
    await settle(tester);
    expect(port.raised, hasLength(1));
    expect(queue.jobs, isEmpty);
    safety.closeAlarm();
    await tearDown0(tester);
  });

  testWidgets('Safety health test text: one short text to the contact, only when asked', (tester) async {
    await setUp0(tester);
    expect(queue.jobs, isEmpty);
    expect(await safety.sendTestText(), EmergencyTestOutcome.queued);
    expect(queue.jobs.single.kind, EmergencyTextKind.test);
    expect(queue.jobs.single.body, EmergencyTexts.test);
    port.contact = null;
    expect(await safety.sendTestText(), EmergencyTestOutcome.noContact);
    await tearDown0(tester);
  });
}

