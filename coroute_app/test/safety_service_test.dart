import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/emergency_roster.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/pending_sos.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/safety_wire.dart';
import 'package:coroute_app/data/services/accel_source.dart';
import 'package:coroute_app/data/services/safety_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/data/services/sms_sender.dart';
import 'package:coroute_app/domain/safety/accel_bucket.dart';
import 'package:coroute_app/domain/safety/crash_detector.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

const int t0 = 1700000000000;

class FakePort extends ChangeNotifier implements SafetyPort, SafetySourcePort {
  FakePort(this.clock);
  final int Function() clock;

  final StreamController<TrackPoint> fixes = StreamController<TrackPoint>.broadcast();
  ConvoyModel? convoy;
  PendingSos? pending;
  bool openAlert = false;
  EmergencyRoster? roster;
  RosterContact? contact = const RosterContact(name: 'Brother', phone: '+91 91234 56780');
  final List<Map<String, Object?>> raised = [];
  final List<(CheckInResult, double?)> checkIns = [];

  void changed() => notifyListeners();

  @override
  Stream<TrackPoint> get myFixes => fixes.stream;
  @override
  ConvoyModel? get activeConvoy => convoy;
  @override
  String? get myUserId => 'me';
  @override
  String get myName => 'Kiran';
  @override
  String? get myPhone => '+91 90000 99999';
  @override
  bool get rideActive => convoy != null && convoy!.tripStatus != 'ENDED';
  @override
  bool get hasOpenSos => pending != null || openAlert;
  @override
  PendingSos? get pendingSos => pending;
  @override
  EmergencyRoster? get emergencyRoster => roster;
  @override
  RosterContact? get myEmergencyContact => contact;

  @override
  SosDelivery raiseSos({
    required String type,
    required double lat,
    required double lng,
    bool auto = false,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAtMs,
  }) {
    raised.add({'type': type, 'lat': lat, 'lng': lng, 'auto': auto, 'speed': speedBeforeKmh, 'impactG': impactG, 'occurredAt': occurredAtMs});
    pending = PendingSos(clientId: 'me-${clock()}', groupId: 'G', lat: lat, lng: lng, type: type, createdAt: clock(), auto: auto);
    notifyListeners();
    return SosDelivery.queued;
  }

  /// 3.15: the crash alarm says where the SOS came from (Need Help or no answer).
  @override
  SosDelivery raiseSosFrom(
    EmergencySource source, {
    required String type,
    required double lat,
    required double lng,
    bool auto = false,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAtMs,
  }) {
    final r = raiseSos(type: type, lat: lat, lng: lng, auto: auto, speedBeforeKmh: speedBeforeKmh, impactG: impactG, occurredAtMs: occurredAtMs);
    raised.last['source'] = source;
    return r;
  }

  @override
  bool sendCheckIn(CheckInResult result, {double? awayM}) {
    checkIns.add((result, awayM));
    return true;
  }
}

class FakeAccel implements AccelSource {
  int listens = 0;
  int cancels = 0;
  StreamController<AccelBucket>? _ctrl;
  bool get running => _ctrl != null;

  @override
  Stream<AccelBucket> buckets({
    int samplingUs = SafetyConstants.accelSamplingUs,
    int maxLatencyUs = SafetyConstants.accelMaxLatencyUs,
  }) {
    late final StreamController<AccelBucket> c;
    c = StreamController<AccelBucket>(
      onListen: () => listens++,
      onCancel: () {
        cancels++;
        if (identical(_ctrl, c)) _ctrl = null;
      },
    );
    _ctrl = c;
    return c.stream;
  }

  void add(AccelBucket b) => _ctrl?.add(b);
}

class FakeSms implements SmsSender {
  SmsCapability cap = const SmsCapability(hasTelephony: true, permission: true, simReady: true);
  final List<(String, String)> sent = [];
  SmsStatus status = SmsStatus.sent;

  @override
  Future<SmsCapability> capability() async => cap;

  @override
  Future<SmsStatus> send(String to, String body) async {
    sent.add((to, body));
    return status;
  }
}

ConvoyModel convoyWith(Map<String, RiderModel> riders, {String status = 'STARTED'}) => ConvoyModel(
      groupId: 'G',
      name: 'Nandi Hills',
      joinCode: '123456',
      createdByUserId: 'lead',
      createdByUserName: 'Lead',
      createdAtEpochMs: t0,
      tripStatus: status,
      riders: riders,
      distanceThresholdMeters: 1000,
    );

void main() {
  late int now;
  late FakePort port;
  late FakeAccel accel;
  late FakeSms sms;
  late SettingsService settings;
  late SafetyService safety;

  Future<void> setUp0(WidgetTester tester, {Map<String, Object> prefs = const {}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    now = t0;
    port = FakePort(() => now);
    accel = FakeAccel();
    sms = FakeSms();
    settings = SettingsService();
    await settings.load();
    safety = SafetyService.forTest(port, settings, accel: accel, sms: sms, clock: () => now);
  }

  Future<void> tearDown0(WidgetTester tester) async {
    safety.dispose();
    await port.fixes.close();
    port.dispose();
    await tester.pump();
  }

  /// Advances the clock and fake time together, one second at a time.
  Future<void> wait(WidgetTester tester, Duration d) async {
    final steps = d.inSeconds;
    for (var i = 0; i < steps; i++) {
      now += 1000;
      await tester.pump(const Duration(seconds: 1));
    }
  }

  TrackPoint fix(int s, double kmh) => TrackPoint(ts: t0 + s * 1000, lat: 12.97, lng: 77.59, speedKmh: kmh);
  AccelBucket bucket(int s, {double peak = 1.3, double std = 0.3}) => AccelBucket(tMs: t0 + s * 1000, peakG: peak, meanG: 1.0, stdG: std);
  const crash = CrashEvent(impactAtMs: t0 - 30000, impactG: 6.2, speedBeforeKmh: 58, lat: 12.97, lng: 77.59);

  group('sensor only when needed (battery)', () {
    testWidgets('subscribed only during a ride, above 25 km/h, with crash detection on', (tester) async {
      await setUp0(tester);
      port.fixes.add(fix(0, 60));
      await tester.pump();
      expect(accel.running, isFalse, reason: 'no ride');

      port.convoy = convoyWith({'me': RiderModel(userId: 'me', name: 'Kiran', lat: 12.97, lng: 77.59, lastSeenEpochMs: t0)});
      port.changed();
      await tester.pump();
      expect(accel.running, isFalse, reason: 'ride, but not moving fast yet');

      port.fixes.add(fix(1, 20));
      await tester.pump();
      expect(accel.running, isFalse, reason: '20 km/h');

      port.fixes.add(fix(2, 40));
      await tester.pump();
      expect(accel.running, isTrue);
      expect(safety.detectorArmed, isTrue);

      // 31 s after the last fast fix the next bucket switches the sensor off.
      accel.add(bucket(20));
      await tester.pump();
      expect(accel.running, isTrue);
      accel.add(bucket(33));
      await tester.pump();
      expect(accel.running, isFalse);
      expect(safety.detectorArmed, isFalse);

      // Setting off: never subscribed, even when fast.
      await settings.setCrashDetection(false);
      port.fixes.add(fix(40, 70));
      await tester.pump();
      expect(accel.running, isFalse);
      await settings.setCrashDetection(true);
      port.fixes.add(fix(41, 70));
      await tester.pump();
      expect(accel.running, isTrue);
      await settings.setCrashDetection(false);
      await tester.pump();
      expect(accel.running, isFalse, reason: 'switching off unregisters at once');

      // Ride ends: off.
      await settings.setCrashDetection(true);
      port.fixes.add(fix(42, 70));
      await tester.pump();
      expect(accel.running, isTrue);
      port.convoy = null;
      port.changed();
      await tester.pump();
      expect(accel.running, isFalse);
      expect(accel.listens, accel.cancels);
      await tearDown0(tester);
    });

    testWidgets('a real fall from fixes and buckets opens the alarm', (tester) async {
      await setUp0(tester);
      port.convoy = convoyWith({});
      port.changed();
      for (var s = 0; s <= 30; s++) {
        port.fixes.add(fix(s, 55));
        await tester.pump();
        accel.add(bucket(s, peak: s == 30 ? 6.0 : 1.4, std: s == 30 ? 1.5 : 0.3));
        await tester.pump();
      }
      port.fixes.add(fix(33, 0));
      await tester.pump();
      for (var s = 33; s <= 54; s++) {
        accel.add(bucket(s, peak: 1.02, std: 0.02));
        await tester.pump();
      }
      expect(safety.alarm, isNotNull);
      expect(safety.alarm!.speedBeforeKmh, 55);
      safety.alarmImOk();
      await tester.pump();
      expect(port.raised, isEmpty);
      await tearDown0(tester);
    });
  });

  group('crash alarm', () {
    test('the countdown is 15 s (3.15, was 30 s)', () {
      expect(SafetyConstants.crashCountdown, const Duration(seconds: 15));
    });

    testWidgets('counts down from 15; I\'m OK closes it and sends nothing', (tester) async {
      await setUp0(tester);
      port.convoy = convoyWith({});
      port.changed();
      safety.debugRaiseCrash(crash);
      expect(safety.alarm?.secondsLeft, SafetyConstants.crashCountdown.inSeconds);
      await wait(tester, const Duration(seconds: 10));
      expect(safety.alarm?.secondsLeft, SafetyConstants.crashCountdown.inSeconds - 10);
      safety.alarmImOk();
      expect(safety.alarm, isNull);
      await wait(tester, const Duration(seconds: 40));
      expect(port.raised, isEmpty, reason: 'cancel sends nothing');
      await tearDown0(tester);
    });

    testWidgets('no answer in 15 s raises an automatic CRASH SOS with the details (CRASH_AUTO)', (tester) async {
      await setUp0(tester);
      port.convoy = convoyWith({});
      port.changed();
      safety.debugRaiseCrash(crash);
      await wait(tester, SafetyConstants.crashCountdown - const Duration(seconds: 1));
      expect(port.raised, isEmpty);
      await wait(tester, const Duration(seconds: 1));
      expect(port.raised, hasLength(1));
      final sos = port.raised.single;
      expect(sos['type'], SosTypes.crash);
      expect(sos['auto'], isTrue);
      expect(sos['source'], EmergencySource.crashAuto);
      expect(sos['speed'], 58);
      expect(sos['impactG'], 6.2);
      expect(sos['occurredAt'], crash.impactAtMs);
      expect(safety.alarm?.sent, isTrue, reason: 'the screen now shows the SOS sheet');
      safety.closeAlarm();
      expect(safety.alarm, isNull);
      await tearDown0(tester);
    });

    testWidgets('Need Help sends at once; no second alarm while an SOS is open', (tester) async {
      await setUp0(tester);
      port.convoy = convoyWith({});
      port.changed();
      safety.debugRaiseCrash(crash);
      safety.alarmSendNow();
      expect(port.raised, hasLength(1));
      expect(port.raised.single['source'], EmergencySource.needHelp, reason: '"Need Help" is the rider answering');
      safety.closeAlarm();
      safety.debugRaiseCrash(crash);
      expect(safety.alarm, isNull, reason: 'my SOS is already open');
      await tearDown0(tester);
    });

    testWidgets('crash detection off: no alarm', (tester) async {
      await setUp0(tester);
      port.convoy = convoyWith({});
      port.changed();
      await settings.setCrashDetection(false);
      safety.debugRaiseCrash(crash);
      expect(safety.alarm, isNull);
      await tearDown0(tester);
    });
  });

  group('emergency texts', () {
    EmergencyRoster roster() => EmergencyRoster(
          groupId: 'G',
          fetchedAt: t0,
          validUntil: t0 + const Duration(hours: 12).inMilliseconds,
          members: const [
            RosterMember(userId: 'lead', role: 'LEAD', phone: '+91 90000 00001'),
            RosterMember(userId: 'r2', role: 'PACK', phone: '+91 90000 00002'),
          ],
        );

    Future<void> startRide(WidgetTester tester) async {
      port.convoy = convoyWith({
        'lead': RiderModel(userId: 'lead', name: 'Lead', lat: 12.98, lng: 77.59, lastSeenEpochMs: t0),
        'r2': RiderModel(userId: 'r2', name: 'Arjun', lat: 12.975, lng: 77.59, lastSeenEpochMs: t0),
      });
      port.roster = roster();
      port.changed();
      await tester.pump();
    }

    void sosWaiting() {
      port.pending = PendingSos(clientId: 'me-1', groupId: 'G', lat: 12.97, lng: 77.59, type: 'EMERGENCY', createdAt: now);
      port.changed();
    }

    testWidgets('not opted in: nothing is texted', (tester) async {
      await setUp0(tester);
      await startRide(tester);
      sosWaiting();
      await wait(tester, const Duration(seconds: 60));
      expect(sms.sent, isEmpty);
      await tearDown0(tester);
    });

    testWidgets('opted in, SOS not delivered after 45 s: one round, contact first, once per SOS', (tester) async {
      await setUp0(tester, prefs: {SafetyConstants.keySmsFallback: true});
      await startRide(tester);
      sosWaiting();
      await wait(tester, const Duration(seconds: 44));
      expect(sms.sent, isEmpty);
      await wait(tester, const Duration(seconds: 2));
      await tester.pump();
      expect(sms.sent.map((s) => s.$1).toList(), ['+919123456780', '+919000000001', '+919000000002']);
      expect(sms.sent.first.$2, contains('https://maps.google.com/?q=12.97000,77.59000'));
      expect(safety.smsStatus?.state, SmsFallbackState.sent);
      expect(safety.smsStatus?.text, 'Texted your emergency contact and 2 riders.');
      expect(safety.smsAvailable, isFalse);

      // The same SOS again (any change): no second round, also not from the button.
      port.changed();
      await safety.sendSmsNow();
      await wait(tester, const Duration(seconds: 60));
      expect(sms.sent, hasLength(3));

      // The parts log has timestamps and counts only.
      final prefs = await SharedPreferences.getInstance();
      final log = prefs.getString(SafetyConstants.keySmsLog) ?? '';
      expect(log, isNotEmpty);
      expect(log, isNot(contains('+91')));
      expect(log, isNot(contains('9123456780')));
      expect(log, isNot(contains('maps.google')));
      await tearDown0(tester);
    });

    testWidgets('delivered within 45 s: nothing is texted', (tester) async {
      await setUp0(tester, prefs: {SafetyConstants.keySmsFallback: true});
      await startRide(tester);
      sosWaiting();
      await wait(tester, const Duration(seconds: 20));
      port.pending = null;
      port.changed();
      await wait(tester, const Duration(seconds: 60));
      expect(sms.sent, isEmpty);
      await tearDown0(tester);
    });

    testWidgets('"Text the group now" sends the round at once; no permission says so', (tester) async {
      await setUp0(tester, prefs: {SafetyConstants.keySmsFallback: true});
      await startRide(tester);
      sms.cap = const SmsCapability(hasTelephony: true, permission: false, simReady: true);
      sosWaiting();
      expect(safety.smsAvailable, isTrue);
      await safety.sendSmsNow();
      await tester.pump();
      expect(sms.sent, isEmpty);
      expect(safety.smsStatus?.state, SmsFallbackState.notAllowed);

      sms.cap = const SmsCapability(hasTelephony: true, permission: true, simReady: true);
      await safety.sendSmsNow();
      await tester.pump();
      expect(sms.sent, hasLength(3));
      await tearDown0(tester);
    });

    testWidgets('a crash SOS text says it is automatic', (tester) async {
      await setUp0(tester, prefs: {SafetyConstants.keySmsFallback: true});
      await startRide(tester);
      safety.debugRaiseCrash(crash);
      safety.alarmSendNow();
      await wait(tester, const Duration(seconds: 46));
      await tester.pump();
      expect(sms.sent, isNotEmpty);
      expect(sms.sent.first.$2.toLowerCase(), contains('automatic'));
      await tearDown0(tester);
    });

    // Regression (r314 behaviour test): a crash SOS carries the impact time as createdAt
    // (stillness + countdown, about a minute earlier). The 45 s wait must count from when the
    // SOS started waiting on this phone, or everyone is texted while the socket delivers it.
    void crashWaiting() {
      port.pending = PendingSos(
          clientId: 'me-crash', groupId: 'G', lat: 12.97, lng: 77.59, type: 'CRASH', createdAt: now - 60000, auto: true);
      port.changed();
    }

    testWidgets('crash SOS (createdAt = impact, a minute ago) delivered in 2 s: nothing is texted', (tester) async {
      await setUp0(tester, prefs: {SafetyConstants.keySmsFallback: true});
      await startRide(tester);
      crashWaiting();
      await tester.pump();
      await wait(tester, const Duration(seconds: 2));
      expect(sms.sent, isEmpty);
      port.pending = null; // the ALERT echo arrived
      port.changed();
      await wait(tester, const Duration(seconds: 60));
      expect(sms.sent, isEmpty);
      await tearDown0(tester);
    });

    testWidgets('crash SOS still waiting 45 s after it was raised: texted once, says automatic', (tester) async {
      await setUp0(tester, prefs: {SafetyConstants.keySmsFallback: true});
      await startRide(tester);
      crashWaiting();
      await wait(tester, const Duration(seconds: 44));
      expect(sms.sent, isEmpty);
      await wait(tester, const Duration(seconds: 2));
      await tester.pump();
      expect(sms.sent, hasLength(3));
      expect(sms.sent.first.$2.toLowerCase(), contains('automatic'));
      await tearDown0(tester);
    });
  });

  group('check-in through the service', () {
    Future<void> farRide(WidgetTester tester) async {
      port.convoy = convoyWith({
        'me': RiderModel(userId: 'me', name: 'Kiran', lat: 12.97, lng: 77.59, lastSeenEpochMs: now),
        'a': RiderModel(userId: 'a', name: 'A', lat: 13.05, lng: 77.59, lastSeenEpochMs: now),
      });
      port.changed();
      await tester.pump();
    }

    Future<void> tick(WidgetTester tester, int count) async {
      for (var i = 0; i < count; i++) {
        now += SafetyConstants.checkInEvalEvery.inMilliseconds;
        final c = port.convoy!;
        port.convoy = c.copyWith(riders: {
          for (final r in c.riders.values) r.userId: r.copyWith(lastSeenEpochMs: now),
        });
        port.changed();
        await tester.pump();
      }
    }

    testWidgets('far for 15 min asks; no answer in 2 min tells the lead; a later OK is sent', (tester) async {
      await setUp0(tester);
      await farRide(tester);
      await tick(tester, 61);
      expect(safety.prompts.map((p) => p.key), [SafetyConstants.promptCheckIn]);
      expect(safety.prompts.single.title, 'Are you OK?');
      now += SafetyConstants.checkInAnswerWithin.inMilliseconds;
      await tester.pump(SafetyConstants.checkInAnswerWithin);
      await tester.pump(const Duration(seconds: 1));
      expect(port.checkIns.map((c) => c.$1), [CheckInResult.noReply]);
      expect(port.checkIns.single.$2, greaterThan(1000));
      safety.answerPrompt(SafetyConstants.promptCheckIn);
      expect(port.checkIns.map((c) => c.$1), [CheckInResult.noReply, CheckInResult.ok]);
      expect(safety.prompts, isEmpty);
      await tearDown0(tester);
    });

    testWidgets('answering I\'m OK before the 2 min sends nothing', (tester) async {
      await setUp0(tester);
      await farRide(tester);
      await tick(tester, 61);
      expect(safety.prompts, hasLength(1));
      safety.answerPrompt(SafetyConstants.promptCheckIn);
      await tester.pump(const Duration(minutes: 3));
      expect(port.checkIns, isEmpty);
      await tearDown0(tester);
    });

    // Regression (r314 behaviour test): "ride active" includes PLANNING and PAUSED. Before the
    // start everyone rides from home to the meeting point; nobody should be asked, and the lead
    // must not get "No reply" for riders still on their way.
    testWidgets('not asked before the ride starts or while it is paused', (tester) async {
      await setUp0(tester);
      await farRide(tester);
      for (final status in ['PLANNING', 'PAUSED']) {
        port.convoy = port.convoy!.copyWith(tripStatus: status);
        port.changed();
        await tick(tester, 70);
        expect(safety.prompts, isEmpty, reason: status);
        await tester.pump(const Duration(minutes: 3));
        expect(port.checkIns, isEmpty, reason: status);
      }
      // Started: counting starts from now, not from the planning time.
      port.convoy = port.convoy!.copyWith(tripStatus: 'STARTED');
      port.changed();
      await tick(tester, 30);
      expect(safety.prompts, isEmpty, reason: '7.5 min into the ride');
      await tick(tester, 32);
      expect(safety.prompts.map((p) => p.key), [SafetyConstants.promptCheckIn]);
      await tearDown0(tester);
    });

    testWidgets('switched off: never asks', (tester) async {
      await setUp0(tester, prefs: {SafetyConstants.keySoloCheckIn: false});
      await farRide(tester);
      await tick(tester, 70);
      expect(safety.prompts, isEmpty);
      await tearDown0(tester);
    });
  });

  test('status line wording', () {
    const sent = SmsFallbackStatus(state: SmsFallbackState.sent, sent: 7, total: 7, capped: 3, at: 0, contactReached: true);
    expect(sent.text, 'Texted your emergency contact and 6 riders. Phones allow about 10 texts at once, so the nearest riders were chosen.');
    const partly = SmsFallbackStatus(state: SmsFallbackState.partly, sent: 6, total: 9, capped: 0, at: 0);
    expect(partly.text, startsWith('Texted 6 of 9'));
    const none = SmsFallbackStatus(state: SmsFallbackState.failed, sent: 0, total: 0, capped: 0, at: 0);
    expect(none.text, contains('112'));
  });
}
