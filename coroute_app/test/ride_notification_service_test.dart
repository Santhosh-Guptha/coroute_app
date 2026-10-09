import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/ride_notification_constants.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/network_models.dart';
import 'package:coroute_app/data/models/network_wire.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/sos_alert_model.dart';
import 'package:coroute_app/data/services/background_service.dart';
import 'package:coroute_app/data/services/ride_notification_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/domain/notify/notification_snapshot.dart';

const int t0 = 1700000000000;

class FakePort extends ChangeNotifier implements RideNotifPort {
  ConvoyModel? convoy;
  List<AssistRequest> assists = [];
  List<HazardWarning> hazardList = [];
  int sosOpened = 0;
  int waits = 0;
  final List<(String, AssistAnswer)> answers = [];

  void changed() => notifyListeners();

  @override
  ConvoyModel? get activeConvoy => convoy;
  @override
  String? get myUserId => 'me';
  @override
  List<AssistRequest> get assistRequests => assists;
  @override
  List<HazardWarning> get hazards => hazardList;
  @override
  void openSosFromNotification() => sosOpened++;
  @override
  void requestWaitFromNotification() => waits++;
  @override
  bool answerAssist(String incidentId, AssistAnswer answer) {
    answers.add((incidentId, answer));
    return true;
  }
}

class FakeChannel implements RideNotificationChannel {
  final List<Map<String, Object?>> shows = [];
  bool showResult = true;
  bool supportedResult = true;
  Object? throwOnShow;
  Map<String, Object?>? launch;
  int ensures = 0;
  bool ensureResult = true;
  int supportedCalls = 0;
  final StreamController<RideNotifAction> ctrl = StreamController<RideNotifAction>.broadcast();

  @override
  Future<bool> show(Map<String, Object?> args) async {
    final t = throwOnShow;
    if (t != null) throw t;
    shows.add(args);
    return showResult;
  }

  @override
  Future<bool> supported() async {
    supportedCalls++;
    return supportedResult;
  }

  @override
  Future<Map<String, Object?>?> takeLaunchAction() async {
    final l = launch;
    launch = null;
    return l;
  }

  @override
  Future<bool> ensure() async {
    ensures++;
    return ensureResult;
  }

  @override
  Stream<RideNotifAction> get actions => ctrl.stream;

  @override
  void dispose() {}
}

RiderModel rider(String id, String name, double lat) => RiderModel(userId: id, name: name, lat: lat, lng: 77.6, speedKmh: 40, lastSeenEpochMs: t0);

ConvoyModel ride({double aheadM = 1200, List<SosAlertModel> alerts = const [], String status = 'STARTED'}) => ConvoyModel(
      groupId: 'G1',
      name: 'Weekend Ride',
      joinCode: '123456',
      createdByUserId: 'a',
      createdByUserName: 'Arjun',
      createdAtEpochMs: t0,
      tripStatus: status,
      riders: {
        'me': rider('me', 'Kiran', 13.0),
        'a': rider('a', 'Arjun', 13.0 + aheadM / 111195),
      },
      activeAlerts: alerts,
    );

SosAlertModel sos() => SosAlertModel(alertId: 'AL1', userId: 'a', userName: 'Arjun', lat: 13.01, lng: 77.6, alertType: 'CRASH', timestamp: t0);

void main() {
  late FakePort port;
  late FakeChannel channel;
  late SettingsService settings;
  late int now;
  RideNotificationService? service;

  MedicalId? medical;
  int medicalAsked = 0;

  Future<void> setUp0(WidgetTester tester, {bool start = true}) async {
    SharedPreferences.setMockInitialValues({});
    BackgroundService.debugReset();
    port = FakePort();
    channel = FakeChannel();
    now = t0;
    medical = null;
    medicalAsked = 0;
    settings = SettingsService();
    await settings.load();
    if (start) {
      service = RideNotificationService.forPort(port, settings, channel: channel, clock: () => now, clockText: (ms) => 'T', medicalId: () {
        medicalAsked++;
        return medical;
      });
    }
  }

  Future<void> tearDown0() async {
    service?.dispose();
    service = null;
    BackgroundService.debugReset();
  }

  Future<void> advance(WidgetTester tester, Duration d) async {
    now += d.inMilliseconds;
    await tester.pump(d);
  }

  testWidgets('3.16: the medical ID provider is asked on every push; my own SOS shows it and the key changes', (tester) async {
    await setUp0(tester);
    port.convoy = ride();
    port.changed();
    await tester.pump();
    expect(channel.shows, hasLength(1));
    expect(medicalAsked, 1);
    final mine = SosAlertModel(alertId: 'AL2', userId: 'me', userName: 'Kiran', lat: 13.0, lng: 77.6, alertType: 'CRASH', timestamp: t0);
    port.convoy = ride(alerts: [mine]);
    port.changed();
    await tester.pump();
    expect(channel.shows, hasLength(2), reason: 'an emergency pushes at once');
    expect(channel.shows.last['publicText'], isNot(contains('Blood')));
    expect(medicalAsked, 2);

    // The setting switches on mid-SOS: the next push carries the medical line (new dedupe key).
    medical = const MedicalId(bloodGroup: 'AB+', allergies: 'none known', contactName: 'Asha', contactPhone: '98765 43210');
    await advance(tester, const Duration(seconds: 11));
    port.changed();
    await tester.pump();
    expect(channel.shows, hasLength(3));
    expect(channel.shows.last['publicText'], 'Your SOS is active. Blood group AB+. Allergies: none known. Emergency contact: Asha 98765 43210.');
    expect(channel.shows.last['subtitle'], contains('AB+'));
    expect(channel.shows.last['lockScreenPublic'], isTrue);

    // Unchanged content: no further push.
    await advance(tester, const Duration(seconds: 11));
    port.changed();
    await tester.pump();
    expect(channel.shows, hasLength(3));
    await tearDown0();
  });

  testWidgets('nothing without a ride; pushes at once when the ride starts', (tester) async {
    await setUp0(tester);
    await tester.pump();
    expect(channel.shows, isEmpty);
    expect(service!.richActive, isFalse);

    port.convoy = ride();
    port.changed();
    await tester.pump();
    expect(channel.shows, hasLength(1));
    expect(channel.shows.single['mode'], 'RIDE');
    expect(service!.richActive, isTrue);
    expect(BackgroundService.richActive, isTrue, reason: 'the plain notification is no longer updated');
    await tearDown0();
  });

  testWidgets('at most one push per 10 s, only when the content changed', (tester) async {
    await setUp0(tester);
    port.convoy = ride();
    port.changed();
    await tester.pump();
    expect(channel.shows, hasLength(1));

    // A burst of changes 2 s later: one timer, one push at the 10 s mark.
    await advance(tester, const Duration(seconds: 2));
    for (final m in [1500.0, 1800.0, 2100.0]) {
      port.convoy = ride(aheadM: m);
      port.changed();
      await tester.pump();
    }
    expect(channel.shows, hasLength(1));
    await advance(tester, const Duration(seconds: 7));
    expect(channel.shows, hasLength(1));
    await advance(tester, const Duration(seconds: 1));
    expect(channel.shows, hasLength(2));
    expect((channel.shows.last['rows'] as List).first, containsPair('detail', '2.1 km ahead'));

    // Same content again: no push (but the native side is asked whether ours still shows).
    await advance(tester, const Duration(seconds: 11));
    port.convoy = ride(aheadM: 2100);
    port.changed();
    await tester.pump();
    expect(channel.shows, hasLength(2));
    expect(channel.ensures, 1);
    await tearDown0();
  });

  testWidgets('an emergency is pushed at once (mode change), ignoring the 10 s window', (tester) async {
    await setUp0(tester);
    port.convoy = ride();
    port.changed();
    await tester.pump();
    await advance(tester, const Duration(seconds: 1));
    port.convoy = ride(alerts: [sos()]);
    port.changed();
    await tester.pump();
    expect(channel.shows, hasLength(2));
    expect(channel.shows.last['mode'], 'GROUP_EMERGENCY');
    expect(channel.shows.last['tone'], 'CRITICAL');
    expect(channel.shows.last['context'], NotifConstants.actionNavEmergency);

    // An assist request while the group emergency is open: the group emergency stays first.
    port.assists = [const AssistRequest(incidentId: 'NET-AAAAAAAAAAAA', lat: 13.02, lng: 77.6, receivedAt: t0)];
    port.changed();
    await tester.pump();
    expect(channel.shows.last['mode'], 'GROUP_EMERGENCY');

    // Resolved: back to the ride at once, then the request shows.
    port.convoy = ride();
    port.changed();
    await tester.pump();
    expect(channel.shows.last['mode'], 'ASSIST');
    expect(channel.shows.last['context'], NotifConstants.actionAssistAccept);
    await tearDown0();
  });

  testWidgets('three failures in a row fall back to the plain notification for the ride', (tester) async {
    await setUp0(tester);
    channel.showResult = false;
    port.convoy = ride();
    port.changed();
    await tester.pump();
    expect(service!.failures, 1);
    expect(service!.richActive, isFalse);
    for (final m in [1600.0, 2600.0]) {
      await advance(tester, const Duration(seconds: 10));
      port.convoy = ride(aheadM: m);
      port.changed();
      await tester.pump();
    }
    expect(channel.shows, hasLength(3));
    expect(service!.gaveUp, isTrue);
    expect(BackgroundService.richActive, isFalse);

    channel.showResult = true;
    await advance(tester, const Duration(seconds: 10));
    port.convoy = ride(aheadM: 3600);
    port.changed();
    await tester.pump();
    expect(channel.shows, hasLength(3), reason: 'given up for this ride');

    // A new ride tries again.
    port.convoy = null;
    port.changed();
    await tester.pump();
    port.convoy = ride().copyWith(groupId: 'G2');
    port.changed();
    await tester.pump();
    expect(channel.shows, hasLength(4));
    expect(service!.richActive, isTrue);
    await tearDown0();
  });

  testWidgets('a success after a failure clears the count; a throw counts as a failure', (tester) async {
    await setUp0(tester);
    port.convoy = ride();
    port.changed();
    await tester.pump();
    expect(service!.richActive, isTrue);
    channel.throwOnShow = PlatformException(code: 'X');
    await advance(tester, const Duration(seconds: 10));
    port.convoy = ride(aheadM: 3000);
    port.changed();
    await tester.pump();
    expect(service!.failures, 1);
    expect(service!.richActive, isFalse);
    expect(BackgroundService.richActive, isFalse, reason: 'the plain notification is posted again');
    channel.throwOnShow = null;
    await advance(tester, const Duration(seconds: 10));
    port.changed();
    await tester.pump();
    expect(service!.failures, 0);
    expect(service!.richActive, isTrue);
    await tearDown0();
  });

  testWidgets('no native side (MissingPluginException) or unsupported phone: plain notification', (tester) async {
    await setUp0(tester);
    channel.throwOnShow = MissingPluginException();
    port.convoy = ride();
    port.changed();
    await tester.pump();
    expect(service!.gaveUp, isTrue);
    expect(service!.richActive, isFalse);
    await tearDown0();

    await setUp0(tester);
    channel.supportedResult = false;
    port.convoy = ride();
    port.changed();
    await tester.pump();
    await advance(tester, const Duration(seconds: 10));
    port.changed();
    await tester.pump();
    expect(channel.shows, isEmpty);
    expect(service!.richActive, isFalse);
    expect(channel.supportedCalls, 1, reason: 'asked once');
    await tearDown0();
  });

  testWidgets('setting off: plain notification; on again: pushed again', (tester) async {
    await setUp0(tester);
    port.convoy = ride();
    port.changed();
    await tester.pump();
    expect(service!.richActive, isTrue);
    await settings.setRichNotification(false);
    await tester.pump();
    expect(service!.richActive, isFalse);
    expect(BackgroundService.richActive, isFalse);
    await advance(tester, const Duration(seconds: 10));
    port.changed();
    await tester.pump();
    expect(channel.shows, hasLength(1));
    await settings.setRichNotification(true);
    await tester.pump();
    expect(channel.shows, hasLength(2));
    expect(service!.richActive, isTrue);
    await tearDown0();
  });

  testWidgets('lock screen setting reaches the native side', (tester) async {
    await setUp0(tester);
    port.convoy = ride();
    port.changed();
    await tester.pump();
    expect(channel.shows.last['lockScreenPublic'], isTrue);
    await settings.setRideOnLockScreen(false);
    await advance(tester, const Duration(seconds: 10));
    expect(channel.shows.last['lockScreenPublic'], isFalse);
    await tearDown0();
  });

  testWidgets('ride end: rich off, nothing pushed', (tester) async {
    await setUp0(tester);
    port.convoy = ride();
    port.changed();
    await tester.pump();
    expect(service!.richActive, isTrue);
    port.convoy = ride(status: 'ENDED');
    port.changed();
    await tester.pump();
    expect(service!.richActive, isFalse);
    expect(BackgroundService.richActive, isFalse);
    await advance(tester, const Duration(seconds: 20));
    expect(channel.shows, hasLength(1));
    await tearDown0();
  });

  testWidgets('buttons: SOS opens the hold screen (never sends), Wait, I Can Help, Open map', (tester) async {
    await setUp0(tester);
    port.convoy = ride();
    port.changed();
    await tester.pump();
    final s = service!;

    channel.ctrl.add(const RideNotifAction(RideNotifActionKind.wait));
    await tester.pump();
    expect(port.waits, 1);
    expect(s.pendingUiAction.value, isNull);

    channel.ctrl.add(const RideNotifAction(RideNotifActionKind.sos));
    await tester.pump();
    expect(port.sosOpened, 1);
    expect(s.pendingUiAction.value, const RideNotifAction(RideNotifActionKind.sos));
    s.clearUiAction();
    expect(s.pendingUiAction.value, isNull);

    channel.ctrl.add(const RideNotifAction(RideNotifActionKind.assistAccept, 'NET-AAAAAAAAAAAA'));
    await tester.pump();
    expect(port.answers, [('NET-AAAAAAAAAAAA', AssistAnswer.accept)]);
    expect(s.pendingUiAction.value, const RideNotifAction(RideNotifActionKind.navigateEmergency, 'NET-AAAAAAAAAAAA'));

    channel.ctrl.add(const RideNotifAction(RideNotifActionKind.openMap));
    await tester.pump();
    expect(s.pendingUiAction.value?.kind, RideNotifActionKind.openMap);

    channel.ctrl.add(const RideNotifAction(RideNotifActionKind.navigateEmergency, 'AL1'));
    await tester.pump();
    expect(s.pendingUiAction.value, const RideNotifAction(RideNotifActionKind.navigateEmergency, 'AL1'));
    await tearDown0();
  });

  testWidgets('the button that started the app is taken once at start', (tester) async {
    await setUp0(tester, start: false);
    channel.launch = {'action': 'SOS', 'ref': ''};
    service = RideNotificationService.forPort(port, settings, channel: channel, clock: () => now);
    await tester.pump();
    expect(port.sosOpened, 1);
    expect(service!.pendingUiAction.value?.kind, RideNotifActionKind.sos);
    expect(channel.launch, isNull);
    await tearDown0();
  });

  testWidgets('service (re)start: pushed again at once and checked again 3 s later', (tester) async {
    await setUp0(tester);
    port.convoy = ride();
    port.changed();
    await tester.pump();
    expect(channel.shows, hasLength(1));
    expect(BackgroundService.onServiceStarted, isNotNull);
    BackgroundService.onServiceStarted!();
    await tester.pump();
    expect(channel.shows, hasLength(2), reason: 'same content, pushed anyway: the plugin replaced it');
    final before = channel.ensures;
    await advance(tester, NotifConstants.restartRecheck);
    expect(channel.ensures, before + 1);
    await tearDown0();
  });

  testWidgets('swiped away (ensure false): plain one back, ours again on the next change', (tester) async {
    await setUp0(tester);
    port.convoy = ride();
    port.changed();
    await tester.pump();
    channel.ensureResult = false;
    await advance(tester, const Duration(seconds: 10));
    port.changed();
    await tester.pump();
    expect(channel.ensures, 1);
    expect(service!.richActive, isFalse);
    channel.ensureResult = true;
    await advance(tester, const Duration(seconds: 10));
    port.changed();
    await tester.pump();
    expect(channel.shows, hasLength(2));
    expect(service!.richActive, isTrue);
    await tearDown0();
  });

  test('native action names map to kinds; unknown ones are ignored', () {
    expect(RideNotifAction.fromMap({'action': 'SOS'}), const RideNotifAction(RideNotifActionKind.sos));
    expect(RideNotifAction.fromMap({'action': 'WAIT', 'ref': ''}), const RideNotifAction(RideNotifActionKind.wait));
    expect(RideNotifAction.fromMap({'action': 'MAP'}), const RideNotifAction(RideNotifActionKind.openMap));
    expect(RideNotifAction.fromMap({'action': 'NAV_EMERGENCY', 'ref': 'AL1'}), const RideNotifAction(RideNotifActionKind.navigateEmergency, 'AL1'));
    expect(RideNotifAction.fromMap({'action': 'ASSIST_ACCEPT', 'ref': 'NET-1'}), const RideNotifAction(RideNotifActionKind.assistAccept, 'NET-1'));
    expect(RideNotifAction.fromMap({'action': 'ASSIST_ACCEPT'}), isNull, reason: 'needs the incident');
    expect(RideNotifAction.fromMap({'action': 'LEAVE'}), isNull);
    expect(RideNotifAction.fromMap(null), isNull);
  });
}
