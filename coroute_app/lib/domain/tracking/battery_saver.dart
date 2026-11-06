/// Battery saver for a ride (pure; see `test/battery_saver_test.dart`).
///
/// Automatic at 20 % or less (not charging), or switched on by the rider in
/// Settings. While it is on the ride trades a little smoothness for runtime:
///  * GPS one band gentler ([gpsLowBattery], `LocationCadence.lowBattery`),
///  * the follow camera at most 15 frames a second ([cameraFrame]),
///  * telemetry on the data-saver cadence (5 s moving, [slowTelemetry]),
///  * the dark map / dark ride theme ([forceDarkMap]).
/// Safety is never reduced: crash detection, SOS, alerts and the socket keep
/// their normal behaviour, and an open emergency always uses the fast cadence.
library;

/// Why battery saver is on (or not), for the settings row and the ride banner.
enum BatterySaverReason { off, user, lowBattery }

class BatterySaverState {
  final bool active;
  final BatterySaverReason reason;
  const BatterySaverState(this.active, this.reason);

  static const BatterySaverState off = BatterySaverState(false, BatterySaverReason.off);

  /// Short line for the settings row / ride banner, empty when off.
  String get label => switch (reason) {
        BatterySaverReason.off => '',
        BatterySaverReason.user => 'Battery saver on',
        BatterySaverReason.lowBattery => 'Battery saver on (low battery)',
      };

  @override
  bool operator ==(Object other) => other is BatterySaverState && other.active == active && other.reason == reason;

  @override
  int get hashCode => Object.hash(active, reason);

  @override
  String toString() => 'BatterySaverState($active, $reason)';
}

/// Decides when battery saver is on, with hysteresis so it does not flap
/// around the threshold: on at <= [enterPercent], off again at >= [exitPercent]
/// or as soon as the phone charges. A rider switch wins at any level.
class BatterySaverPolicy {
  BatterySaverPolicy({this.enterPercent = defaultEnterPercent, this.exitPercent = defaultExitPercent});

  /// Battery saver turns itself on at or below this battery level, and off again at [defaultExitPercent].
  static const int defaultEnterPercent = 20;
  static const int defaultExitPercent = 25;

  final int enterPercent;
  final int exitPercent;

  bool _auto = false;

  /// True while the automatic (low battery) part is engaged.
  bool get autoEngaged => _auto;

  /// [percent] outside 0..100 (unknown) keeps the previous automatic state.
  BatterySaverState update({required int percent, required bool charging, required bool userOn}) {
    if (charging) {
      _auto = false;
    } else if (percent >= 0 && percent <= 100) {
      if (percent <= enterPercent) _auto = true;
      if (percent >= exitPercent) _auto = false;
    }
    if (userOn) return const BatterySaverState(true, BatterySaverReason.user);
    if (_auto) return const BatterySaverState(true, BatterySaverReason.lowBattery);
    return BatterySaverState.off;
  }

  void reset() => _auto = false;
}

/// What the ride does differently while battery saver is on.
class BatterySaverProfile {
  BatterySaverProfile._();

  /// Follow-camera frame caps: 30 fps while riding, 15 fps in battery saver.
  static const Duration frameRiding = Duration(microseconds: 33333);
  static const Duration frameSaver = Duration(microseconds: 66666);

  /// The minimum time between two camera frames, or null for no frames at all
  /// (app in the background, screen off, or nothing left to animate).
  static Duration? cameraFrame({required bool saver, required bool foreground, required bool screenOn, required bool settled}) {
    if (!foreground || !screenOn || settled) return null;
    return saver ? frameSaver : frameRiding;
  }

  /// Frames per second for [cameraFrame] (0 = stopped), for diagnostics and docs.
  static int cameraFps({required bool saver, required bool foreground, required bool screenOn, required bool settled}) {
    final f = cameraFrame(saver: saver, foreground: foreground, screenOn: screenOn, settled: settled);
    if (f == null) return 0;
    return (1000000 / f.inMicroseconds).round();
  }

  /// GPS on the gentler `LocationCadence.lowBattery` table.
  static bool gpsLowBattery(BatterySaverState s) => s.active;

  /// Telemetry on the data-saver cadence (5 s moving instead of 1-2.5 s).
  /// An open emergency is never slowed down.
  static bool slowTelemetry(BatterySaverState s, {required bool critical}) => s.active && !critical;

  /// Dark map and dark ride theme (less light on OLED screens).
  static bool forceDarkMap(BatterySaverState s) => s.active;

  /// Ride notification refresh: 10 s normally, 20 s in battery saver; an
  /// emergency change is always pushed at once by the notification service.
  static Duration notificationInterval(BatterySaverState s) =>
      s.active ? const Duration(seconds: 20) : const Duration(seconds: 10);
}
