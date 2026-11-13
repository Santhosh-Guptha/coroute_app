// Round 10 rescue beacon: WHEN the victim's phone sounds, flashes and advertises (pure Dart state
// machine, unit-tested; RescueBeaconService runs it on the phone).
//
// It only ever starts AFTER the existing safety flow already did its work:
//  * the crash countdown ran out with no answer (the SOS went out as CRASH_AUTO), or
//  * an SOS is open and the rider did not answer the "Still able to respond?" check, or
//  * the rider started it by hand from their own open SOS (lost / trapped but conscious).
// It never starts without an open SOS and stops on its own when the SOS closes. It never touches
// the countdown, the SOS, the emergency texts or the Medical ID.
//
// Schedule (a [RescuePlanConfig] can change the numbers in tests):
//   0 - 2 min     ESCALATING  siren continuously in 10 s chunks, level and sweep rate rising
//   2 - 15 min    DUTY FAST   10 s siren every 30 s
//   15 min -      DUTY SLOW   10 s siren every 60 s
//   battery reserve (the SOS battery reserve is on, or < 10 % and not charging)
//                 RESERVE     no siren, no locator sound; BLE in low power; a responder's ping
//                             still plays a short burst (at most one a minute)
//   <= 4 % battery CRITICAL   as RESERVE, pings at most one every 3 minutes
// Between siren windows: a near-ultrasonic locator packet every 2 s (also mixed into the siren).
// The light flashes (SOS Morse, <= 3 flashes/s) during siren windows when it is dark and the phone
// is not covered; the phone vibrates at the start of each window; the screen wakes in the first
// 15 minutes so a passer-by sees what is happening.
//
// Stops:
//  * the rider: "I'm OK" / "I'm conscious, silence siren" (the existing rule)  -> everything stops;
//  * a resolver: the SOS is resolved (rider's "I am safe", the group / app)       -> everything stops;
//  * a bystander: a deliberate 3 s hold on "Stop siren: help is here"            -> the siren, light
//    and vibration stop, the SOS stays open, the inaudible locator and BLE keep running so the
//    group can still find the spot, and it is logged.
// A touch on the victim's screen (someone reading the Medical ID or calling) pauses all sound for
// [RescuePlanConfig.touchPause]: a phone at full alarm volume next to an ear is harmful.

enum RescueTrigger { crashUnanswered, sosUnresponsive, manualStart }

enum RescueStopReason { riderOk, resolved }

enum RescuePhase { idle, escalating, dutyFast, dutySlow, reserve, critical, stopped }

enum BleAdvMode { off, balanced, lowPower }

enum PingResult { accepted, throttled, noSos, paused }

class RescuePlanConfig {
  final Duration escalation;
  final Duration fastUntil;
  final Duration fastPeriod;
  final Duration slowPeriod;
  final Duration sirenWindow;
  final Duration chunk;
  final Duration packetInterval;
  final Duration ping;
  final Duration pingReserve;
  final Duration pingGap;
  final Duration pingGapReserve;
  final Duration pingGapCritical;
  final Duration touchPause;
  final Duration screenWakeFor;
  final Duration bleBalancedFor;
  final int reservePercent;
  final int criticalPercent;

  const RescuePlanConfig({
    this.escalation = const Duration(minutes: 2),
    this.fastUntil = const Duration(minutes: 15),
    this.fastPeriod = const Duration(seconds: 30),
    this.slowPeriod = const Duration(seconds: 60),
    this.sirenWindow = const Duration(seconds: 10),
    this.chunk = const Duration(seconds: 10),
    this.packetInterval = const Duration(seconds: 2),
    this.ping = const Duration(seconds: 10),
    this.pingReserve = const Duration(seconds: 5),
    this.pingGap = const Duration(seconds: 15),
    this.pingGapReserve = const Duration(seconds: 60),
    this.pingGapCritical = const Duration(minutes: 3),
    this.touchPause = const Duration(seconds: 15),
    this.screenWakeFor = const Duration(minutes: 15),
    this.bleBalancedFor = const Duration(minutes: 30),
    this.reservePercent = 10,
    this.criticalPercent = 4,
  });
}

/// What the phone reads before every tick.
class RescueEnv {
  final int batteryPercent;
  final bool charging;

  /// The SOS battery reserve is on (SosBatteryReserve.isActive).
  final bool reserveActive;

  /// The rider's SOS is open (on the server, still waiting to be sent, or the offline solo SOS).
  final bool sosOpen;

  /// Dark and not covered: the light may flash (RescueStrobe.shouldFlash).
  final bool flashOk;

  /// The phone is face-down / in a pocket (proximity near): the screen is not woken.
  final bool covered;

  /// Someone touched the victim's screen within the touch pause.
  final bool touchedRecently;

  const RescueEnv({
    this.batteryPercent = 100,
    this.charging = false,
    this.reserveActive = false,
    this.sosOpen = true,
    this.flashOk = false,
    this.covered = false,
    this.touchedRecently = false,
  });
}

enum RescueAudioKind { siren, beacon, stop }

/// A sound to start now. [siren]: [durationMs] of siren at [level] with locator packets mixed in.
/// [beacon]: one locator packet (index [bandIndex] into the phone's band list). [stop]: silence.
class RescueAudioCommand {
  final RescueAudioKind kind;
  final int durationMs;
  final double level;
  final double sweepPeriodS;
  final int bandIndex;
  final bool ping;

  const RescueAudioCommand._(this.kind, {this.durationMs = 0, this.level = 0, this.sweepPeriodS = 1, this.bandIndex = 0, this.ping = false});

  const RescueAudioCommand.siren({required int durationMs, required double level, required double sweepPeriodS, bool ping = false})
      : this._(RescueAudioKind.siren, durationMs: durationMs, level: level, sweepPeriodS: sweepPeriodS, ping: ping);
  const RescueAudioCommand.beacon(int bandIndex) : this._(RescueAudioKind.beacon, bandIndex: bandIndex);
  const RescueAudioCommand.stop() : this._(RescueAudioKind.stop);

  @override
  String toString() => switch (kind) {
        RescueAudioKind.siren => 'siren(${durationMs}ms, ${level.toStringAsFixed(2)}${ping ? ', ping' : ''})',
        RescueAudioKind.beacon => 'beacon($bandIndex)',
        RescueAudioKind.stop => 'stop',
      };
}

class RescueOutput {
  final RescuePhase phase;

  /// A sound command to issue now; null keeps what is playing.
  final RescueAudioCommand? audio;

  /// The light should be flashing now.
  final bool strobe;

  /// Start one vibration burst now.
  final bool vibrate;
  final BleAdvMode ble;

  /// Wake the screen (over the lock screen) now.
  final bool screenWake;

  const RescueOutput({
    required this.phase,
    this.audio,
    this.strobe = false,
    this.vibrate = false,
    this.ble = BleAdvMode.off,
    this.screenWake = false,
  });

  static const RescueOutput idle = RescueOutput(phase: RescuePhase.idle);
}

class RescueBeaconPlan {
  RescueBeaconPlan({this.config = const RescuePlanConfig(), this.bandCount = 2});

  final RescuePlanConfig config;

  /// How many locator bands the phone alternates (1 or 2).
  int bandCount;

  RescueTrigger? _trigger;
  int _startedAt = 0;
  RescueStopReason? _stopReason;
  bool _bystanderStopped = false;
  int _bystanderAt = 0;
  int _sirenUntil = 0;
  int _nextPacketAt = 0;
  int _band = 0;
  int _lastPingAt = -(1 << 40);
  int _pingUntil = 0;
  bool _pingPending = false;
  int _lastWindowVibrated = -1;
  bool _stopIssued = true;
  RescuePhase _phase = RescuePhase.idle;

  RescueTrigger? get trigger => _trigger;
  RescueStopReason? get stopReason => _stopReason;
  bool get active => _trigger != null && _stopReason == null;
  bool get bystanderStopped => _bystanderStopped;
  int get bystanderAt => _bystanderAt;
  int get startedAt => _startedAt;
  RescuePhase get phase => _phase;

  /// Starts the beacon. Refused (false) without an open SOS or when already running.
  bool start(RescueTrigger t, int nowMs, {required bool sosOpen}) {
    if (!sosOpen || active) return false;
    _trigger = t;
    _startedAt = nowMs;
    _stopReason = null;
    _bystanderStopped = false;
    _bystanderAt = 0;
    _sirenUntil = 0;
    _nextPacketAt = nowMs;
    _band = 0;
    _lastWindowVibrated = -1;
    _stopIssued = false;
    return true;
  }

  void stop(RescueStopReason r) {
    if (_trigger == null || _stopReason != null) return;
    _stopReason = r;
  }

  /// Forgets everything (a new SOS later starts fresh).
  void reset() {
    _trigger = null;
    _stopReason = null;
    _bystanderStopped = false;
    _bystanderAt = 0;
    _sirenUntil = 0;
    _pingUntil = 0;
    _pingPending = false;
    _lastPingAt = -(1 << 40);
    _phase = RescuePhase.idle;
    _stopIssued = true;
  }

  /// The deliberate bystander stop: siren, light and vibration off; locator and BLE stay; the SOS
  /// stays open. True when it changed something.
  bool bystanderStop(int nowMs) {
    if (!active || _bystanderStopped) return false;
    _bystanderStopped = true;
    _bystanderAt = nowMs;
    return true;
  }

  RescuePhase _phaseFor(int nowMs, RescueEnv env) {
    if (!env.charging && env.batteryPercent >= 0 && env.batteryPercent <= config.criticalPercent) return RescuePhase.critical;
    if (!env.charging && (env.reserveActive || (env.batteryPercent >= 0 && env.batteryPercent < config.reservePercent))) {
      return RescuePhase.reserve;
    }
    final e = nowMs - _startedAt;
    if (e < config.escalation.inMilliseconds) return RescuePhase.escalating;
    if (e < config.fastUntil.inMilliseconds) return RescuePhase.dutyFast;
    return RescuePhase.dutySlow;
  }

  /// A responder asked for a loud burst ("Ping the phone"). Works while the SOS is open, also
  /// when the beacon itself is not running (a conscious rider whose phone is in a bag).
  PingResult ping(int nowMs, RescueEnv env) {
    if (!env.sosOpen) return PingResult.noSos;
    if (env.touchedRecently) return PingResult.paused;
    final ph = _phaseFor(nowMs, env);
    final gap = switch (ph) {
      RescuePhase.critical => config.pingGapCritical,
      RescuePhase.reserve => config.pingGapReserve,
      _ => config.pingGap,
    };
    if (nowMs - _lastPingAt < gap.inMilliseconds) return PingResult.throttled;
    _lastPingAt = nowMs;
    final len = (ph == RescuePhase.reserve || ph == RescuePhase.critical) ? config.pingReserve : config.ping;
    _pingUntil = nowMs + len.inMilliseconds;
    _pingPending = true;
    _stopIssued = false;
    return PingResult.accepted;
  }

  /// Siren level 0.40 -> 0.78 in four steps over the escalation, then the maximum.
  double levelAt(int elapsedMs) {
    final steps = [0.40, 0.52, 0.65, 0.78];
    final q = config.escalation.inMilliseconds ~/ 4;
    if (q <= 0) return steps.last;
    return steps[(elapsedMs ~/ q).clamp(0, 3)];
  }

  /// Sweep period 1.2 s (slow wail) -> 0.3 s (fast yelp) over the escalation.
  double sweepAt(int elapsedMs) {
    final steps = [1.2, 0.8, 0.5, 0.3];
    final q = config.escalation.inMilliseconds ~/ 4;
    if (q <= 0) return steps.last;
    return steps[(elapsedMs ~/ q).clamp(0, 3)];
  }

  RescueOutput tick(int nowMs, RescueEnv env) {
    // The SOS closed (resolved anywhere): everything stops, whatever started it.
    if (_trigger != null && _stopReason == null && !env.sosOpen) _stopReason = RescueStopReason.resolved;
    final pingOn = _pingUntil > nowMs && env.sosOpen;
    if (!active) {
      _phase = _trigger == null ? RescuePhase.idle : RescuePhase.stopped;
      // Ping bursts outside the beacon (or after it stopped while the SOS is still open).
      if (pingOn) return _pingOutput(nowMs, env, _phase, BleAdvMode.off);
      if (!_stopIssued) {
        _stopIssued = true;
        _sirenUntil = 0;
        _pingUntil = 0;
        return RescueOutput(phase: _phase, audio: const RescueAudioCommand.stop());
      }
      return RescueOutput(phase: _phase);
    }
    final ph = _phaseFor(nowMs, env);
    _phase = ph;
    final elapsed = nowMs - _startedAt;
    final lowPower = ph == RescuePhase.reserve || ph == RescuePhase.critical || elapsed >= config.bleBalancedFor.inMilliseconds;
    final ble = lowPower ? BleAdvMode.lowPower : BleAdvMode.balanced;

    if (pingOn) return _pingOutput(nowMs, env, ph, ble);

    // Someone is holding / reading the phone: no sound at all for a moment.
    if (env.touchedRecently) {
      return RescueOutput(phase: ph, audio: _silence(nowMs), ble: ble);
    }

    if (ph == RescuePhase.reserve || ph == RescuePhase.critical) {
      return RescueOutput(phase: ph, audio: _silence(nowMs), ble: ble);
    }

    // Siren window?
    int windowStart, windowEnd, windowIndex;
    if (ph == RescuePhase.escalating) {
      windowIndex = 0;
      windowStart = _startedAt;
      windowEnd = _startedAt + config.escalation.inMilliseconds;
    } else {
      final esc = config.escalation.inMilliseconds;
      final fastEnd = config.fastUntil.inMilliseconds;
      int base, period, idxBase;
      if (ph == RescuePhase.dutyFast) {
        base = esc;
        period = config.fastPeriod.inMilliseconds;
        idxBase = 1;
      } else {
        base = fastEnd;
        period = config.slowPeriod.inMilliseconds;
        idxBase = 1 + ((fastEnd - esc) ~/ config.fastPeriod.inMilliseconds) + 1;
      }
      final k = (elapsed - base) ~/ period;
      windowIndex = idxBase + k;
      windowStart = _startedAt + base + k * period;
      windowEnd = windowStart + config.sirenWindow.inMilliseconds;
    }
    final inWindow = nowMs >= windowStart && nowMs < windowEnd;
    final sirenAllowed = !_bystanderStopped;

    RescueAudioCommand? audio;
    var vibrate = false;
    if (inWindow && sirenAllowed) {
      if (nowMs >= _sirenUntil - 50) {
        final remain = windowEnd - nowMs;
        final dur = remain < config.chunk.inMilliseconds ? remain : config.chunk.inMilliseconds;
        if (dur >= 1000) {
          final level = ph == RescuePhase.escalating ? levelAt(elapsed) : levelAt(1 << 30);
          final sweep = ph == RescuePhase.escalating ? sweepAt(elapsed) : sweepAt(1 << 30);
          audio = RescueAudioCommand.siren(durationMs: dur, level: level, sweepPeriodS: sweep);
          _sirenUntil = nowMs + dur;
          _stopIssued = false;
        }
      }
      if (_lastWindowVibrated != windowIndex || (ph == RescuePhase.escalating && audio != null)) {
        _lastWindowVibrated = windowIndex;
        vibrate = true;
      }
    } else if (nowMs >= _sirenUntil) {
      // Quiet gap (or the bystander stopped the siren): locator packets only.
      if (nowMs >= _nextPacketAt) {
        audio = RescueAudioCommand.beacon(_band % (bandCount <= 0 ? 1 : bandCount));
        _band++;
        final step = config.packetInterval.inMilliseconds ~/ (bandCount <= 1 ? 1 : bandCount);
        _nextPacketAt = nowMs + step;
        _stopIssued = false;
      }
    } else if (!sirenAllowed && _sirenUntil > nowMs) {
      audio = const RescueAudioCommand.stop();
      _sirenUntil = nowMs;
    }
    final sirenNow = sirenAllowed && inWindow;
    return RescueOutput(
      phase: ph,
      audio: audio,
      strobe: sirenNow && env.flashOk,
      vibrate: vibrate && sirenAllowed,
      ble: ble,
      screenWake: sirenNow && !env.covered && elapsed < config.screenWakeFor.inMilliseconds,
    );
  }

  RescueAudioCommand? _silence(int nowMs) {
    if (_sirenUntil > nowMs || !_stopIssued) {
      _sirenUntil = 0;
      _stopIssued = true;
      return const RescueAudioCommand.stop();
    }
    return null;
  }

  RescueOutput _pingOutput(int nowMs, RescueEnv env, RescuePhase ph, BleAdvMode ble) {
    RescueAudioCommand? audio;
    if (_pingPending) {
      _pingPending = false;
      final dur = _pingUntil - nowMs;
      audio = RescueAudioCommand.siren(durationMs: dur < 1000 ? 1000 : dur, level: RescueBeaconPlanLevels.max, sweepPeriodS: 0.3, ping: true);
      _sirenUntil = _pingUntil;
      _stopIssued = false;
    }
    return RescueOutput(
      phase: ph,
      audio: audio,
      strobe: env.flashOk,
      vibrate: audio != null,
      ble: ble,
      screenWake: audio != null && !env.covered,
    );
  }
}

class RescueBeaconPlanLevels {
  RescueBeaconPlanLevels._();
  static const double max = 0.78;
}

/// "Still able to respond?" after an SOS the rider raised (or "Need Help"): asked [askAfter] after
/// the SOS opened; no answer within [answerWithin] and the beacon starts. One check per SOS.
class SosResponseCheck {
  SosResponseCheck({this.askAfter = const Duration(minutes: 3), this.answerWithin = const Duration(seconds: 60)});

  final Duration askAfter;
  final Duration answerWithin;

  String? _key;
  int _openedAt = 0;
  bool _answered = false;
  bool _expiredReported = false;

  String? get key => _key;

  /// The SOS this check is for ([sosKey] null: no SOS of this kind is open).
  void update(String? sosKey, int nowMs) {
    if (sosKey == _key) return;
    _key = sosKey;
    _openedAt = nowMs;
    _answered = false;
    _expiredReported = false;
  }

  /// The rider answered "I can respond": no beacon from this check.
  void answer() => _answered = true;

  bool get answered => _answered;

  bool asking(int nowMs) {
    if (_key == null || _answered) return false;
    final a = _openedAt + askAfter.inMilliseconds;
    return nowMs >= a && nowMs < a + answerWithin.inMilliseconds;
  }

  int secondsLeft(int nowMs) {
    final end = _openedAt + askAfter.inMilliseconds + answerWithin.inMilliseconds;
    final s = ((end - nowMs) / 1000).ceil();
    return s < 0 ? 0 : s;
  }

  /// True ONCE, when the answer window passed without an answer.
  bool takeExpired(int nowMs) {
    if (_key == null || _answered || _expiredReported) return false;
    if (nowMs >= _openedAt + askAfter.inMilliseconds + answerWithin.inMilliseconds) {
      _expiredReported = true;
      return true;
    }
    return false;
  }
}

/// What the victim's phone knows when deciding whether to start (pure, tested).
class RescueStartGate {
  RescueStartGate._();

  /// The trigger to start with now, or null.
  ///  * [alarmSent] && [alarmUnresponsive]: the crash countdown ran out with no answer;
  ///  * [responseCheckExpired]: the "still able to respond?" check of an open SOS got no answer.
  /// Never without [sosOpen]; never twice for the same SOS ([alreadyRanForSos]); never after the
  /// rider said they are OK for this SOS ([riderOkForSos]).
  static RescueTrigger? decide({
    required bool sosOpen,
    required bool alarmOpen,
    required bool alarmSent,
    required bool alarmUnresponsive,
    required bool responseCheckExpired,
    required bool alreadyRanForSos,
    required bool riderOkForSos,
  }) {
    if (!sosOpen || alreadyRanForSos || riderOkForSos) return null;
    if (alarmOpen && !alarmSent) return null; // the countdown is still running: never before it ends
    if (alarmOpen && alarmSent && alarmUnresponsive) return RescueTrigger.crashUnanswered;
    if (responseCheckExpired) return RescueTrigger.sosUnresponsive;
    return null;
  }
}
