// Round 10 rescue beacon, VICTIM side: runs RescueBeaconPlan on the phone of a rider who may be
// unconscious, and drives the siren, the near-ultrasonic locator, vibration, the light and the BLE
// locator advertisement. Docs: docs/features_355/rescue_beacon.md.
//
// It only ADDS behaviour after the existing safety flow:
//  * starts when the crash countdown ended with no answer (SafetyService sent the SOS as
//    CRASH_AUTO), or when an open SOS got no answer to "Still able to respond?" (3 min after it
//    was raised, 60 s to answer), or when the rider starts it by hand from their own open SOS;
//  * never starts without an open SOS, never before the countdown ends, never in a normal ride;
//  * stops when the SOS closes, when the rider says they are OK, and (siren only) on the
//    bystander's deliberate 3 s hold;
//  * the countdown, the SOS, the emergency texts and the Medical ID are not touched. Below the
//    battery reserve it goes quiet so SMS / SOS keep the battery.
// The timer runs only while an SOS of this rider is open (no cost in a normal ride).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../domain/diag/diag_log.dart';
import '../../domain/rescue/rescue_acoustics.dart';
import '../../domain/rescue/rescue_ble.dart';
import '../../domain/rescue/rescue_beacon_plan.dart';
import '../../domain/rescue/rescue_id.dart';
import '../../domain/rescue/rescue_strobe.dart';
import '../../domain/safety/sun_helper.dart';
import 'rescue_native.dart';

/// What the victim service reads on every evaluation (built from SafetyService + ConvoyService
/// by [RescueVictimPort]; a fake in tests).
class RescueVictimState {
  /// My SOS is open (server, still waiting to be sent, or the offline solo SOS).
  final bool sosOpen;

  /// The SOS key (its clientId, else its alertId): the rescue id comes from it.
  final String? sosKey;
  final String? alertId;

  /// The SOS was raised by the rider (button, "Need Help", notification): the response check applies.
  final bool raisedByRider;

  final bool alarmOpen;
  final bool alarmSent;
  final bool alarmUnresponsive;
  final bool alarmSirenActive;

  final int batteryPercent;
  final bool charging;
  final bool reserveActive;

  final double lat;
  final double lng;

  const RescueVictimState({
    this.sosOpen = false,
    this.sosKey,
    this.alertId,
    this.raisedByRider = false,
    this.alarmOpen = false,
    this.alarmSent = false,
    this.alarmUnresponsive = false,
    this.alarmSirenActive = false,
    this.batteryPercent = 100,
    this.charging = false,
    this.reserveActive = false,
    this.lat = 0,
    this.lng = 0,
  });

  int get rescueId => sosKey == null ? 0 : RescueId.fromKey(sosKey!);
}

abstract class RescueVictimPort implements Listenable {
  RescueVictimState read();
}

/// One line of the beacon's own log (shown to the rider after; also in the diagnostics log).
class RescueLogLine {
  final int atMs;
  final String text;
  const RescueLogLine(this.atMs, this.text);
}

class RescueBeaconService extends ChangeNotifier {
  RescueBeaconService(
    this._port, {
    RescueNativePort? native,
    int Function()? clock,
    RescuePlanConfig config = const RescuePlanConfig(),
    SosResponseCheck? check,
    this.sampleRate = 48000,
    this.runTimer = true,
    this.screenWake,
  })  : _native = native ?? RescueNative.instance,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        plan = RescueBeaconPlan(config: config),
        check = check ?? SosResponseCheck() {
    _port.addListener(_evaluate);
    _evaluate();
  }

  /// The app's instance (main.dart), for the mesh integration point and the lock-screen panel.
  static RescueBeaconService? instance;

  final RescueVictimPort _port;
  final RescueNativePort _native;
  final int Function() _clock;
  /// False in tests: [tick] is called by hand.
  final bool runTimer;

  /// Shows CoRoute over the lock screen with the screen on (main.dart: SafetyNative.alarmWindow).
  final void Function(bool on)? screenWake;
  final int sampleRate;

  final RescueBeaconPlan plan;
  final SosResponseCheck check;

  /// The locator bands this phone plays (from the speaker self-test; both until tested).
  BeaconBandMode bandMode = BeaconBandMode.both;

  Timer? _timer;
  bool _disposed = false;
  String? _ranForKey;
  String? _riderOkForKey;
  String? _lastKey;
  bool _sawSirenActive = false;
  bool _wasAsking = false;
  int _askSeconds = -1;
  int _lastTouchAt = -(1 << 40);
  RescueSensors _sensors = RescueSensors.unknown;
  int _sensorsAt = -(1 << 40);
  bool _strobeOn = false;
  bool _screenStrobe = false;
  BleAdvMode _ble = BleAdvMode.off;
  int _bleFlags = -1;
  RescueBleAdvState _bleState = RescueBleAdvState.off;
  bool _windowOn = false;
  bool _wakeHeld = false;
  bool _sessionOpen = false;
  int _wakeAt = 0;
  RescueVictimState _last = const RescueVictimState();
  final List<RescueLogLine> _log = [];
  final Map<String, Int16List> _pcm = {};
  late final RescueSynth _synth = RescueSynth(sampleRate: sampleRate);

  // ---------------------------------------------------------------- read side (UI)
  bool get active => plan.active;
  bool get bystanderStopped => plan.bystanderStopped;
  RescuePhase get phase => plan.phase;
  int get rescueId => _last.rescueId;
  bool get sosOpen => _last.sosOpen;

  /// "Still able to respond?" is on screen now.
  bool get askingResponse => check.asking(_clock()) && _last.sosOpen && !plan.active;
  int get responseSecondsLeft => check.secondsLeft(_clock());

  /// The torch could not be used: the screen flashes instead (RescueStrobeOverlay).
  bool get screenStrobe => _screenStrobe && _strobeOn;
  RescueBleAdvState get bleState => _bleState;
  List<RescueLogLine> get log => List.unmodifiable(_log);

  /// The rider may start the beacon by hand while their SOS is open (lost or trapped but awake).
  bool get canStartByHand => _last.sosOpen && !plan.active;

  // ---------------------------------------------------------------- actions
  /// The rider says they are OK: everything stops (the SOS itself stays as it is).
  void riderOk() {
    if (!plan.active) return;
    plan.stop(RescueStopReason.riderOk);
    _riderOkForKey = _last.sosKey;
    _note('Stopped by the rider ("I\'m OK").', 'rescue_stop', {'by': 'rider'});
    _tickNow();
  }

  /// The bystander's deliberate long press: the siren stops, the SOS stays open, logged.
  void bystanderStop() {
    if (plan.bystanderStop(_clock())) {
      _note('Siren stopped by someone at the phone ("Help is here"). The SOS stays open.', 'rescue_stop', {'by': 'bystander'});
      _tickNow();
    }
  }

  /// "I can respond" on the response check.
  void answerResponseCheck() {
    check.answer();
    _note('Rider answered "I can respond".', 'rescue_check_answered', const {});
    notifyListeners();
  }

  /// The rider starts the beacon from their own open SOS.
  bool startByHand() {
    final s = _port.read();
    if (!s.sosOpen || plan.active) return false;
    return _start(RescueTrigger.manualStart, s);
  }

  /// Someone touched the victim's screen (all sound pauses for a moment: ear safety).
  void noteTouch() => _lastTouchAt = _clock();

  /// A responder's "Ping the phone" (server message RESCUE_PING with my alert id).
  PingResult onPing({String? alertId, String fromName = ''}) {
    final s = _port.read();
    if (alertId != null && alertId.isNotEmpty && s.alertId != null && alertId != s.alertId) return PingResult.noSos;
    final r = plan.ping(_clock(), _env(s));
    if (r == PingResult.accepted) {
      _note(fromName.isEmpty ? 'A responder pinged the phone.' : '$fromName pinged the phone.', 'rescue_ping', {'ok': true});
      _ensureTimer();
      _tickNow();
    }
    return r;
  }

  /// INTEGRATION POINT (offline mesh, Agent A): a ping that arrived over the mesh for [id].
  PingResult onPingForRescueId(int id) {
    if (id <= 0 || id != _port.read().rescueId) return PingResult.noSos;
    return onPing();
  }

  /// Socket events (RealtimeService.events): RESCUE_PING for my open alert.
  StreamSubscription<Map<String, dynamic>> attachRealtime(Stream<Map<String, dynamic>> events) => events.listen((e) {
        if (e['type'] != 'RESCUE_PING') return;
        onPing(alertId: e['alertId']?.toString(), fromName: e['fromName']?.toString() ?? '');
      });

  // ---------------------------------------------------------------- evaluation
  void _evaluate() {
    if (_disposed) return;
    final now = _clock();
    final s = _port.read();
    _last = s;
    if (s.sosKey != _lastKey) {
      _lastKey = s.sosKey;
      _sawSirenActive = false;
    }
    // The response check is for an SOS the rider raised; a crash SOS with no answer starts at once.
    check.update(s.sosOpen && s.raisedByRider ? s.sosKey : null, now);
    if (s.alarmOpen && s.alarmSent && s.alarmSirenActive) _sawSirenActive = true;
    // The existing "I'm conscious, silence siren" button: the rider's answer (existing rule).
    if (plan.active && s.alarmOpen && s.alarmSent && _sawSirenActive && !s.alarmSirenActive && plan.trigger == RescueTrigger.crashUnanswered) {
      riderOk();
    }
    _maybeStart(s, now);
    if (s.sosOpen || plan.active) _ensureTimer();
    notifyListeners();
  }

  void _maybeStart(RescueVictimState s, int now) {
    if (plan.active) return;
    final trigger = RescueStartGate.decide(
      sosOpen: s.sosOpen,
      alarmOpen: s.alarmOpen,
      alarmSent: s.alarmSent,
      alarmUnresponsive: s.alarmUnresponsive,
      responseCheckExpired: s.raisedByRider && check.takeExpired(now),
      alreadyRanForSos: s.sosKey != null && _ranForKey == s.sosKey,
      riderOkForSos: s.sosKey != null && _riderOkForKey == s.sosKey,
    );
    if (trigger != null) _start(trigger, s);
  }

  bool _start(RescueTrigger t, RescueVictimState s) {
    plan.bandCount = bandMode.bands.length;
    if (!plan.start(t, _clock(), sosOpen: s.sosOpen)) return false;
    _ranForKey = s.sosKey;
    _pcm.clear();
    final why = switch (t) {
      RescueTrigger.crashUnanswered => 'No answer to the crash alarm',
      RescueTrigger.sosUnresponsive => 'No answer to "Still able to respond?"',
      RescueTrigger.manualStart => 'Started by the rider',
    };
    _note('Rescue beacon started: $why.', 'rescue_start', {'trigger': t.name, 'id': RescueId.hex(s.rescueId), 'bands': bandMode.name});
    _ensureTimer();
    _tickNow();
    return true;
  }

  void _ensureTimer() {
    if (!runTimer || _timer != null || _disposed) return;
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => tick());
  }

  void _tickNow() {
    tick();
    notifyListeners();
  }

  RescueEnv _env(RescueVictimState s) {
    final now = _clock();
    final t = DateTime.now();
    final dark = (s.lat == 0 && s.lng == 0) ? (t.hour >= 19 || t.hour < 6) : DarkCheck.isDark(t, s.lat, s.lng);
    return RescueEnv(
      batteryPercent: s.batteryPercent,
      charging: s.charging,
      reserveActive: s.reserveActive,
      sosOpen: s.sosOpen,
      flashOk: RescueStrobe.shouldFlash(lux: _sensors.lux, covered: _sensors.proximityNear, faceDown: _sensors.faceDown, isNight: dark),
      covered: _sensors.covered || _sensors.faceDown == true,
      touchedRecently: now - _lastTouchAt < plan.config.touchPause.inMilliseconds,
    );
  }

  /// One step (every 500 ms while an SOS is open). Public for tests.
  void tick() {
    if (_disposed) return;
    final now = _clock();
    final s = _port.read();
    _last = s;
    // The response check runs on the clock, between port notifications: its countdown on screen
    // (once a second) and its expiry.
    if (s.raisedByRider && s.sosOpen && !plan.active) {
      final asking = check.asking(now);
      final sec = asking ? check.secondsLeft(now) : -1;
      if (asking != _wasAsking || sec != _askSeconds) {
        _wasAsking = asking;
        _askSeconds = sec;
        notifyListeners();
      }
      _maybeStart(s, now);
    }
    // Light / proximity / tilt: read every 20 s while the beacon runs (one short sensor burst).
    if (plan.active && now - _sensorsAt > 20000) {
      _sensorsAt = now;
      _native.sensors().then((v) => _sensors = v).ignore();
    }
    final out = plan.tick(now, _env(s));
    _apply(out, s);
    final idle = !s.sosOpen && !plan.active && out.audio == null;
    if (idle) {
      _timer?.cancel();
      _timer = null;
      _shutDown();
    }
  }

  void _apply(RescueOutput out, RescueVictimState s) {
    final a = out.audio;
    if (a != null) _play(a, s);
    if (out.vibrate) _native.vibrate(_vibration).ignore();
    if (out.strobe != _strobeOn) {
      _strobeOn = out.strobe;
      if (_strobeOn) {
        _native.strobe(true, pattern: RescueStrobe.sosPattern()).then((how) {
          _screenStrobe = how != 'torch';
          if (_screenStrobe) notifyListeners();
        }).ignore();
      } else {
        _native.strobe(false).ignore();
        if (_screenStrobe) {
          _screenStrobe = false;
          notifyListeners();
        }
      }
    }
    final flags = (out.audio?.kind == RescueAudioKind.siren ? RescueBle.flagSiren : 0) |
        (out.phase == RescuePhase.reserve || out.phase == RescuePhase.critical ? RescueBle.flagReserve : 0) |
        (plan.bystanderStopped ? RescueBle.flagBystander : 0);
    if (out.ble != _ble || (out.ble != BleAdvMode.off && (flags & ~RescueBle.flagSiren) != (_bleFlags & ~RescueBle.flagSiren))) {
      _ble = out.ble;
      _bleFlags = flags;
      final id = s.rescueId;
      _native
          .bleAdvertise(on: _ble != BleAdvMode.off && id > 0, rescueId: id, flags: flags, lowPower: _ble == BleAdvMode.lowPower)
          .then((st) {
        _bleState = st;
        if (_ble != BleAdvMode.off) DiagLog.info(DiagCat.sos, 'rescue_ble', {'legacy': st.legacy, 'ext': st.extended, 'coded': st.coded, 'err': st.error});
      }).ignore();
    }
    final wake = out.screenWake || (_screenStrobe && _strobeOn);
    if (wake != _windowOn) {
      _windowOn = wake;
      screenWake?.call(wake);
    }
    final needWake = plan.active || out.audio != null;
    final now = _clock();
    if (needWake && (!_wakeHeld || now - _wakeAt > 60000)) {
      _wakeHeld = true;
      _wakeAt = now;
      _native.wakeLock(true, timeoutMs: 120000).ignore();
    } else if (!needWake && _wakeHeld && !_last.sosOpen) {
      _wakeHeld = false;
      _native.wakeLock(false).ignore();
    }
  }

  static const List<int> _vibration = [0, 250, 250, 250, 250, 250, 600, 750, 250, 750, 250, 750, 600, 250, 250, 250, 250, 250];

  void _play(RescueAudioCommand a, RescueVictimState s) {
    if (a.kind != RescueAudioKind.stop) _sessionOpen = true;
    switch (a.kind) {
      case RescueAudioKind.stop:
        if (!plan.active && _sessionOpen) {
          // The beacon (or a ping burst) is over: the rider's alarm volume / Do Not Disturb back now.
          _sessionOpen = false;
          _native.endSession().ignore();
        } else {
          _native.stopAudio().ignore();
        }
      case RescueAudioKind.beacon:
        final bands = bandMode.bands;
        final band = bands[a.bandIndex % bands.length];
        final id = s.rescueId;
        if (id <= 0) return;
        final pcm = _pcm.putIfAbsent('b|${band.name}|$id', () => RescueSynth.toPcm16(_synth.packet(id, band)));
        _native.playPcm(pcm, sampleRate: sampleRate).ignore();
      case RescueAudioKind.siren:
        final id = s.rescueId;
        final key = 's|${a.durationMs}|${a.level}|${a.sweepPeriodS}|$id|${bandMode.name}';
        final pcm = _pcm[key] ??
            RescueSynth.toPcm16(_synth.segment(
              seconds: a.durationMs / 1000,
              rescueId: id,
              sirenLevel: a.level,
              sweepPeriodS: a.sweepPeriodS,
              bands: bandMode.bands,
            ));
        if (_pcm.length > 8) _pcm.remove(_pcm.keys.first);
        _pcm[key] = pcm;
        _native.playPcm(pcm, sampleRate: sampleRate).ignore();
    }
  }

  void _shutDown() {
    if (_sessionOpen) {
      _sessionOpen = false;
      _native.endSession().ignore();
    }
    if (_strobeOn) {
      _strobeOn = false;
      _native.strobe(false).ignore();
    }
    _screenStrobe = false;
    if (_ble != BleAdvMode.off) {
      _ble = BleAdvMode.off;
      _native.bleAdvertise(on: false).ignore();
    }
    if (_windowOn) {
      _windowOn = false;
      screenWake?.call(false);
    }
    if (_wakeHeld) {
      _wakeHeld = false;
      _native.wakeLock(false).ignore();
    }
    // A finished SOS: a new one starts with a clean plan.
    if (!plan.active && plan.trigger != null) plan.reset();
    _pcm.clear();
    notifyListeners();
  }

  void _note(String text, String event, Map<String, Object?> fields) {
    _log.add(RescueLogLine(_clock(), text));
    if (_log.length > 50) _log.removeAt(0);
    DiagLog.warn(DiagCat.sos, event, fields);
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _port.removeListener(_evaluate);
    _timer?.cancel();
    _timer = null;
    if (_sessionOpen) _native.endSession().ignore();
    if (_ble != BleAdvMode.off) _native.bleAdvertise(on: false).ignore();
    if (_strobeOn) _native.strobe(false).ignore();
    if (_wakeHeld) _native.wakeLock(false).ignore();
    if (identical(instance, this)) instance = null;
    super.dispose();
  }
}
