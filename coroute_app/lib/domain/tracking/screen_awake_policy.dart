/// "Always on" ride screen (pure; see `test/screen_awake_policy_test.dart`).
///
/// While riding with the ride screen in front, the screen stays on (window
/// keep-screen-on flag) and dims itself after [dimAfter] without a touch
/// (window brightness, not the system setting). Keep-on is switched off, with
/// the reason shown, when the bike has been parked longer than [parkedOffAfter]
/// or the battery is below [minBatteryPercent] and not charging; the phone then
/// sleeps normally and the ride continues through the foreground service.
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
}

class ScreenAwakeDecision {
  /// Keep the screen on (window flag / wakelock).
  final bool keepOn;

  /// Lower the window brightness (only while [keepOn]).
  final bool dim;

  final ScreenAwakeReason reason;

  const ScreenAwakeDecision({required this.keepOn, required this.dim, required this.reason});

  /// Short line shown on the ride screen when the screen is allowed to sleep for a ride reason.
  String? get notice => switch (reason) {
        ScreenAwakeReason.parked => 'Screen can sleep: parked over 5 min. The ride keeps running.',
        ScreenAwakeReason.lowBattery => 'Screen can sleep: battery below 15%. The ride keeps running.',
        ScreenAwakeReason.riding || ScreenAwakeReason.notRiding => null,
      };

  @override
  bool operator ==(Object other) =>
      other is ScreenAwakeDecision && other.keepOn == keepOn && other.dim == dim && other.reason == reason;

  @override
  int get hashCode => Object.hash(keepOn, dim, reason);

  @override
  String toString() => 'ScreenAwakeDecision(keepOn: $keepOn, dim: $dim, $reason)';
}

class ScreenAwakePolicy {
  ScreenAwakePolicy._();

  static const Duration dimAfter = Duration(seconds: 30);
  static const Duration parkedOffAfter = Duration(minutes: 5);
  static const int minBatteryPercent = 15;

  /// Window brightness while dimmed (0..1 of the panel's range).
  static const double dimBrightness = 0.12;

  /// [parkedSinceMs] is when the bike stopped (0 = moving / unknown).
  /// [batteryPercent] < 0 means unknown (never blocks).
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
    if (parkedSinceMs > 0 && nowMs - parkedSinceMs > parkedOffAfter.inMilliseconds) {
      return const ScreenAwakeDecision(keepOn: false, dim: false, reason: ScreenAwakeReason.parked);
    }
    final idle = nowMs - lastTouchMs;
    return ScreenAwakeDecision(keepOn: true, dim: idle >= dimAfter.inMilliseconds, reason: ScreenAwakeReason.riding);
  }

  /// When the decision can next change on its own (for one timer instead of polling), or null.
  static int? nextChangeAt({
    required ScreenAwakeDecision current,
    required int nowMs,
    required int lastTouchMs,
    required int parkedSinceMs,
  }) {
    if (!current.keepOn) return null;
    final candidates = <int>[
      if (!current.dim) lastTouchMs + dimAfter.inMilliseconds,
      if (parkedSinceMs > 0) parkedSinceMs + parkedOffAfter.inMilliseconds + 1,
    ].where((t) => t > nowMs).toList()..sort();
    return candidates.isEmpty ? null : candidates.first;
  }
}
