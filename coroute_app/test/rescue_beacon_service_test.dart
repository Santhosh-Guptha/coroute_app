// Round 10 rescue beacon: the victim-side service with a fake port and a fake native channel.
// Needs the Flutter SDK (ChangeNotifier): run with `flutter test test/rescue_beacon_service_test.dart`.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/services/rescue_beacon_service.dart';
import 'package:coroute_app/data/services/rescue_native.dart';
import 'package:coroute_app/domain/rescue/rescue_beacon_plan.dart';

class _FakeNative implements RescueNativePort {
  final List<String> calls = [];
  int plays = 0;
  bool bleOn = false;

  @override
  Future<bool> playPcm(Int16List pcm, {required int sampleRate, bool alarm = true, bool maxVolume = true}) async {
    plays++;
    calls.add('play:${pcm.length}');
    return true;
  }

  @override
  Future<void> stopAudio() async => calls.add('stop');
  @override
  Future<void> endSession() async => calls.add('end');
  @override
  Future<void> vibrate(List<int> pattern) async => calls.add('vibrate');
  @override
  Future<String> strobe(bool on, {List<int> pattern = const []}) async {
    calls.add('strobe:$on');
    return 'torch';
  }

  @override
  Future<RescueSensors> sensors() async => const RescueSensors(lux: 500, proximityNear: false, faceDown: false);
  @override
  Future<RescueBleAdvState> bleAdvertise({required bool on, int rescueId = 0, int flags = 0, bool lowPower = false}) async {
    bleOn = on;
    calls.add('ble:$on');
    return on ? const RescueBleAdvState(legacy: true) : RescueBleAdvState.off;
  }

  @override
  Future<bool> bleScan({required bool on, bool lowLatency = true}) async => true;
  @override
  Stream<RescueBleSighting> get sightings => const Stream.empty();
  @override
  Future<void> wakeLock(bool on, {int timeoutMs = 120000}) async => calls.add('wake:$on');
  @override
  Future<Map<String, dynamic>> audioState() async => const {};
}

class _FakePort extends ChangeNotifier implements RescueVictimPort {
  RescueVictimState state = const RescueVictimState();
  void set(RescueVictimState s) {
    state = s;
    notifyListeners();
  }

  @override
  RescueVictimState read() => state;
}

void main() {
  late _FakeNative native;
  late _FakePort port;
  late int now;
  late RescueBeaconService svc;

  setUp(() {
    native = _FakeNative();
    port = _FakePort();
    now = 1000000;
    svc = RescueBeaconService(port, native: native, clock: () => now, runTimer: false);
  });

  tearDown(() => svc.dispose());

  void run(int ms) {
    final end = now + ms;
    while (now < end) {
      now += 500;
      svc.tick();
    }
  }

  const crashSent = RescueVictimState(
    sosOpen: true, sosKey: 'client-1', alertId: 'SOS-1', alarmOpen: true, alarmSent: true, alarmUnresponsive: true, alarmSirenActive: true,
  );

  test('a normal ride (no SOS) never touches the speaker, torch or Bluetooth', () {
    port.set(const RescueVictimState(batteryPercent: 80));
    run(600000);
    expect(native.calls, isEmpty);
    expect(svc.active, isFalse);
  });

  test('never while the countdown runs', () {
    port.set(const RescueVictimState(sosOpen: true, sosKey: 'k', alarmOpen: true, alarmSent: false));
    run(30000);
    expect(native.plays, 0);
    expect(svc.active, isFalse);
  });

  test('countdown ended with no answer: siren, BLE and wake lock start', () async {
    port.set(crashSent);
    await Future<void>.delayed(Duration.zero);
    expect(svc.active, isTrue);
    expect(native.plays, greaterThan(0));
    expect(native.bleOn, isTrue);
    expect(native.calls, contains('wake:true'));
    expect(svc.rescueId, isNonZero);
  });

  test('the existing "I\'m conscious, silence siren" button counts as the rider\'s answer', () async {
    port.set(crashSent);
    port.set(const RescueVictimState(sosOpen: true, sosKey: 'client-1', alertId: 'SOS-1', alarmOpen: true, alarmSent: true, alarmUnresponsive: true, alarmSirenActive: false));
    await Future<void>.delayed(Duration.zero);
    expect(svc.active, isFalse);
    expect(svc.plan.stopReason, RescueStopReason.riderOk);
    run(2000);
    expect(native.calls, contains('end'), reason: 'volume / Do Not Disturb restored');
  });

  test('bystander hold: siren stops, BLE stays, logged, SOS untouched', () async {
    port.set(crashSent);
    run(3000);
    svc.bystanderStop();
    expect(svc.bystanderStopped, isTrue);
    expect(svc.active, isTrue);
    expect(native.bleOn, isTrue);
    expect(svc.log.last.text, contains('Help is here'));
  });

  test('the SOS closes anywhere: everything stops and the session ends', () async {
    port.set(crashSent);
    run(3000);
    port.set(const RescueVictimState());
    run(1000);
    expect(svc.active, isFalse);
    expect(native.bleOn, isFalse);
    expect(native.calls, contains('end'));
    expect(native.calls, contains('wake:false'));
  });

  test('manual SOS: "Still able to respond?" after 3 min; no answer in 60 s starts the beacon; an answer prevents it', () async {
    port.set(const RescueVictimState(sosOpen: true, sosKey: 'man-1', raisedByRider: true));
    run(179000);
    expect(svc.askingResponse, isFalse);
    run(2000);
    expect(svc.askingResponse, isTrue);
    run(60000);
    expect(svc.active, isTrue);
    expect(svc.plan.trigger, RescueTrigger.sosUnresponsive);

    final svc2 = RescueBeaconService(_FakePort()..state = const RescueVictimState(sosOpen: true, sosKey: 'man-2', raisedByRider: true),
        native: _FakeNative(), clock: () => now, runTimer: false);
    final start = now;
    while (now < start + 185000) {
      now += 500;
      svc2.tick();
    }
    expect(svc2.askingResponse, isTrue);
    svc2.answerResponseCheck();
    while (now < start + 400000) {
      now += 500;
      svc2.tick();
    }
    expect(svc2.active, isFalse);
    svc2.dispose();
  });

  test('a responder ping plays a burst even without the beacon; other alert ids are ignored', () async {
    port.set(const RescueVictimState(sosOpen: true, sosKey: 'man-3', alertId: 'SOS-3', raisedByRider: true));
    final events = StreamController<Map<String, dynamic>>();
    svc.attachRealtime(events.stream);
    events.add({'type': 'RESCUE_PING', 'alertId': 'SOS-other'});
    await Future<void>.delayed(Duration.zero);
    expect(native.plays, 0);
    events.add({'type': 'RESCUE_PING', 'alertId': 'SOS-3', 'fromName': 'Arjun'});
    await Future<void>.delayed(Duration.zero);
    expect(native.plays, 1);
    expect(svc.log.last.text, contains('Arjun'));
    await events.close();
  });

  test('battery reserve: the siren goes quiet', () async {
    port.set(crashSent);
    run(3000);
    final before = native.plays;
    port.set(const RescueVictimState(
      sosOpen: true, sosKey: 'client-1', alertId: 'SOS-1', alarmOpen: true, alarmSent: true, alarmUnresponsive: true, alarmSirenActive: true,
      batteryPercent: 8,
    ));
    run(120000);
    expect(native.plays, before);
    expect(svc.phase, RescuePhase.reserve);
  });
}
