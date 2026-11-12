/// "Always on" ride screen and the Ride AOD (pure; see `test/screen_awake_policy_test.dart` and
/// `test/ride_aod_policy_test.dart`, docs/features_355/lock_screen_cockpit.md).
///
/// While riding with the ride screen in front, the screen stays on (window keep-screen-on flag). After
/// [dimAfter] without a touch (or an alert) the idle display takes over, as the rider chose in Settings ›
/// Ride screen › When idle: the OLED-friendly Ride AOD (default), a plain dim, or letting the screen sleep.
/// Keep-on is switched off, with the reason shown, when:
///  * the battery is below [minBatteryPercent] and not charging;
///  * the phone is too hot (thermal status critical or worse); severe heat shows the Ride AOD sooner instead;
///  * the bike has been parked longer than [parkedOffAfter];
///  * "Keep screen on: only while moving" (default) and the bike has stood still longer than [stoppedGrace].
/// The phone then sleeps normally and the ride continues through the foreground service; the power button brings
/// the cockpit back over the lock screen (lock_screen_cockpit_policy.dart).
library;

enum ScreenAwakeReason {
  /// Riding, screen kept on.
  riding,

  /// No ride, ride screen not in front, app in the background or rider switched it off.
  notRiding,

  /// Parked longer than [ScreenAwakePolicy.parkedOffAfter].
  parked,

  /// Battery below [ScreenAwakePolicy.minBatteryPercent] and not charging.
  lowBattery,

  /// "Only while moving": stopped longer than [ScreenAwakePolicy.stoppedGrace].
  stopped,

  /// Thermal status severe: kept on, but the simple Ride AOD comes sooner.
  hot,

  /// Thermal status critical or worse: the screen may sleep.
  tooHot,
}

/// Settings › Ride screen › When idle.
enum RideIdleMode {
  aod('aod'),
  dim('dim'),
  sleep('sleep');

  const RideIdleMode(this.id);
  final String id;

  static RideIdleMode fromId(String? id) => values.firstWhere((m) => m.id == id, orElse: () => RideIdleMode.aod);

  String get label => switch (this) {
        RideIdleMode.aod => 'Ride AOD',
        RideIdleMode.dim => 'Dim',
        RideIdleMode.sleep => 'Let the screen sleep',
      };
}

/// Settings › Ride screen › Keep screen on.
enum KeepScreenOnMode {
  whileMoving('moving'),
  always('always');

  const KeepScreenOnMode(this.id);
  final String id;

  static KeepScreenOnMode fromId(String? id) => values.firstWhere((m) => m.id == id, orElse: () => KeepScreenOnMode.whileMoving);

  String get label => switch (this) {
        KeepScreenOnMode.whileMoving => 'Only while moving',
        KeepScreenOnMode.always => 'Always during a ride',
      };
}

/// What the ride screen shows.
enum RideDisplay {
  /// The full cockpit at normal brightness.
  full,

  /// The black, minimal Ride AOD at very low window brightness.
  aod,

  /// The cockpit at low window brightness.
  dim,

  /// Not kept on: the phone sleeps by its own timeout.
  off,
}

class ScreenAwakeDecision {
  /// Keep the screen on (window flag / wakelock).
  final bool keepOn;

  /// Lower the window brightness (only while [keepOn]): dimmed cockpit or Ride AOD.
  final bool dim;

  final ScreenAwakeReason reason;

  final RideDisplay display;

  const ScreenAwakeDecision({required this.keepOn, required this.dim, required this.reason, RideDisplay? display})
      : display = display ?? (keepOn ? (dim ? RideDisplay.dim : RideDisplay.full) : RideDisplay.off);

  /// Window brightness to set (0..1 of the panel range), null = the system's own.
  double? get brightness => switch (display) {
        RideDisplay.aod => ScreenAwakePolicy.aodBrightness,
        RideDisplay.dim => ScreenAwakePolicy.dimBrightness,
        RideDisplay.full || RideDisplay.off => null,
      };

  /// Short line shown on the ride screen when the screen changes for a ride reason.
  String? get notice => switch (reason) {
        ScreenAwakeReason.parked => 'Screen can sleep: parked over 5 min. The ride keeps running.',
        ScreenAwakeReason.lowBattery => 'Screen can sleep: battery below 15%. The ride keeps running.',
        ScreenAwakeReason.stopped => 'Screen can sleep while you are stopped. Press power to see your ride.',
        ScreenAwakeReason.hot => 'Phone is hot: ride screen simplified to cool it down.',
        ScreenAwakeReason.tooHot => 'Phone is too hot: screen can sleep. The ride keeps running.',
        ScreenAwakeReason.riding || ScreenAwakeReason.notRiding => null,
      };

  @override
  bool operator ==(Object other) =>
      other is ScreenAwakeDecision && other.keepOn == keepOn && other.dim == dim && other.reason == reason && other.display == display;

  @override
  int get hashCode => Object.hash(keepOn, dim, reason, display);

  @override
  String toString() => 'ScreenAwakeDecision(keepOn: $keepOn, dim: $dim, $reason, $display)';
}

class ScreenAwakePolicy {
  ScreenAwakePolicy._();

  static const Duration dimAfter = Duration(seconds: 30);

  /// Severe heat: the Ride AOD (or sleep) after this instead of [dimAfter].
  static const Duration hotIdleAfter = Duration(seconds: 10);
  static const Duration parkedOffAfter = Duration(minutes: 5);

  /// "Only while moving": a red light or a short stop keeps the screen on this long.
  static const Duration stoppedGrace = Duration(minutes: 2);
  static const int minBatteryPercent = 15;

  /// Window brightness while dimmed (0..1 of the panel's range).
  static const double dimBrightness = 0.12;

  /// Window brightness of the Ride AOD (the native side never goes below 0.01).
  static const double aodBrightness = 0.03;

  /// PowerManager thermal status (API 29+): 3 severe, 4 critical (5 emergency, 6 shutdown).
  static const int thermalSevere = 3;
  static const int thermalCritical = 4;

  /// The Ride AOD content moves by up to this many pixels, once every [burnInStep].
  static const int burnInMaxPx = 6;
  static const Duration burnInStep = Duration(seconds: 60);

  /// [parkedSinceMs] is when the bike stopped (0 = moving / unknown).
  /// [batteryPercent] < 0 means unknown (never blocks).
  /// [lastAlertMs]: when an alert last came (siren, off-route, regroup...): it wakes the full cockpit like a touch.
  /// [thermalStatus]: PowerManager thermal status, 0 when unknown.
  ///
  /// The defaults of [idleMode] and [keepOnMode] keep the behaviour of the first always-on screen (dim, kept on
  /// until parked); the app passes the rider's settings (Ride AOD, only while moving by default).
  static ScreenAwakeDecision decide({
    required bool riding,
    required bool foreground,
    required bool userKeepOn,
    required int nowMs,
    required int lastTouchMs,
    required int parkedSinceMs,
    required int batteryPercent,
    required bool charging,
    bool emergencyOpen = false,
    RideIdleMode idleMode = RideIdleMode.dim,
    KeepScreenOnMode keepOnMode = KeepScreenOnMode.always,
    int lastAlertMs = 0,
    int thermalStatus = 0,
  }) {
    if (!riding || !foreground || !userKeepOn) {
      return const ScreenAwakeDecision(keepOn: false, dim: false, reason: ScreenAwakeReason.notRiding);
    }
    // An open emergency (crash countdown, SOS) keeps the screen on at full brightness.
    if (emergencyOpen) {
      return const ScreenAwakeDecision(keepOn: true, dim: false, reason: ScreenAwakeReason.riding);
    }
    if (!charging && batteryPercent >= 0 && batteryPercent < minBatteryPercent) {
      return const ScreenAwakeDecision(keepOn: false, dim: false, reason: ScreenAwakeReason.lowBattery);
    }
    if (thermalStatus >= thermalCritical) {
      return const ScreenAwakeDecision(keepOn: false, dim: false, reason: ScreenAwakeReason.tooHot);
    }
    if (parkedSinceMs > 0 && nowMs - parkedSinceMs > parkedOffAfter.inMilliseconds) {
      return const ScreenAwakeDecision(keepOn: false, dim: false, reason: ScreenAwakeReason.parked);
    }
    if (keepOnMode == KeepScreenOnMode.whileMoving && parkedSinceMs > 0 && nowMs - parkedSinceMs > stoppedGrace.inMilliseconds) {
      return const ScreenAwakeDecision(keepOn: false, dim: false, reason: ScreenAwakeReason.stopped);
    }
    final hot = thermalStatus >= thermalSevere;
    final reason = hot ? ScreenAwakeReason.hot : ScreenAwakeReason.riding;
    final anchor = lastAlertMs > lastTouchMs ? lastAlertMs : lastTouchMs;
    final idleAfter = hot ? hotIdleAfter : dimAfter;
    if (nowMs - anchor < idleAfter.inMilliseconds) {
      return ScreenAwakeDecision(keepOn: true, dim: false, reason: reason, display: RideDisplay.full);
    }
    // Severe heat: the black AOD is cooler than a dimmed map (fewer lit pixels, no map redraws).
    final mode = hot && idleMode == RideIdleMode.dim ? RideIdleMode.aod : idleMode;
    return switch (mode) {
      RideIdleMode.aod => ScreenAwakeDecision(keepOn: true, dim: true, reason: reason, display: RideDisplay.aod),
      RideIdleMode.dim => ScreenAwakeDecision(keepOn: true, dim: true, reason: reason, display: RideDisplay.dim),
      // Released: the phone's own screen timeout takes it from here.
      RideIdleMode.sleep => ScreenAwakeDecision(keepOn: false, dim: false, reason: reason, display: RideDisplay.off),
    };
  }

  /// When the decision can next change on its own (for one timer instead of polling), or null.
  static int? nextChangeAt({
    required ScreenAwakeDecision current,
    required int nowMs,
    required int lastTouchMs,
    required int parkedSinceMs,
    int lastAlertMs = 0,
    KeepScreenOnMode keepOnMode = KeepScreenOnMode.always,
  }) {
    if (!current.keepOn) return null;
    final anchor = lastAlertMs > lastTouchMs ? lastAlertMs : lastTouchMs;
    final idleAfter = current.reason == ScreenAwakeReason.hot ? hotIdleAfter : dimAfter;
    final candidates = <int>[
      if (current.display == RideDisplay.full) anchor + idleAfter.inMilliseconds,
      if (parkedSinceMs > 0) parkedSinceMs + parkedOffAfter.inMilliseconds + 1,
      if (parkedSinceMs > 0 && keepOnMode == KeepScreenOnMode.whileMoving) parkedSinceMs + stoppedGrace.inMilliseconds + 1,
    ].where((t) => t > nowMs).toList()..sort();
    return candidates.isEmpty ? null : candidates.first;
  }

  static const List<(int, int)> _shiftCycle = [
    (0, 0), (4, 2), (-3, 5), (5, -4), (-5, -2), (2, -6), (-2, 4), (6, 3), (-6, 1), (1, -3),
  ];

  /// Burn-in protection for the Ride AOD: a small offset that changes once every [burnInStep] and never exceeds
  /// [burnInMaxPx] in either direction (deterministic, so tests and screenshots repeat).
  static ({int dx, int dy}) burnInShift(int nowMs) {
    final step = (nowMs ~/ burnInStep.inMilliseconds) % _shiftCycle.length;
    final (dx, dy) = _shiftCycle[step < 0 ? step + _shiftCycle.length : step];
    return (dx: dx.clamp(-burnInMaxPx, burnInMaxPx), dy: dy.clamp(-burnInMaxPx, burnInMaxPx));
  }

  /// When the burn-in offset (and the AOD clock) next changes.
  static int nextShiftAt(int nowMs) => (nowMs ~/ burnInStep.inMilliseconds + 1) * burnInStep.inMilliseconds;
}

/// Rough battery cost of the ride screen, for the Settings hints. Estimates for a typical phone at moderate
/// brightness, on top of the ride itself (GPS, connection); to be confirmed by the device measurement in the QA
/// checklist (docs/NEXT_AGENT_PROMPT_v3.55_round3.md §8).
class RideScreenBattery {
  RideScreenBattery._();

  static const String screenOn = 'about 6–10% per hour with the screen on';
  static const String aod = 'about 2–4% per hour on OLED screens';
  static const String dim = 'about 3–6% per hour';
  static const String sleep = 'no screen cost while it sleeps';

  static String forIdle(RideIdleMode m) => switch (m) {
        RideIdleMode.aod => aod,
        RideIdleMode.dim => dim,
        RideIdleMode.sleep => sleep,
      };

  static String idleHint(RideIdleMode m) => 'After 30 s without a touch. ${m.label}: ${forIdle(m)}. Alerts bring the full screen back.';

  static String keepOnHint(KeepScreenOnMode m) => switch (m) {
        KeepScreenOnMode.whileMoving => 'Sleeps after 2 min stopped. Screen on: $screenOn. Below 15% battery or when hot it can sleep.',
        KeepScreenOnMode.always => 'Stays on at stops (sleeps after 5 min parked). Screen on: $screenOn. Below 15% battery or when hot it can sleep.',
      };
}
