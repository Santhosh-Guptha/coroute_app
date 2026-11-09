/// 3.55 "Lower music when speeding": a nudge to slow down. When the rider stays above the effective
/// speed limit (the stricter of the group limit and the rider's own, see effective_speed_limit.dart,
/// the same value SafetyService warns at), OTHER apps' music is lowered step by step:
///
/// | over the limit | music          |
/// |----------------|----------------|
/// | under 10 %     | unchanged      |
/// | 10 % or more   | 60 % volume    |
/// | 25 % or more   | 30 % volume    |
/// | 40 % or more   | paused         |
///
/// Rules (all pure, unit tested in test/speed_audio_policy_test.dart):
///  * Nothing happens before the rider has been over the limit for [minOverMs] (4 s) without a break.
///  * Within one episode the level only goes down (quieter), never back up, so the music does not
///    pump with every GPS fix around a threshold.
///  * The episode ends when the speed is at least [hysteresisKmh] (3 km/h) under the limit for
///    [restoreAfterMs] (5 s): the original volume is restored (smoothly, on the native side).
///  * When the rider changes the volume (or resumes the music) during the episode, the app stops
///    touching the volume for the rest of the episode and never "restores" over the rider's choice.
///  * Setting off, admin switch off, no limit, ride end or an SOS / crash alarm end the episode at
///    once (restore).
///
/// CoRoute's own alerts and intercom are never lowered (the native side keeps them at the rider's
/// original level while they play). The native side only applies a target fraction / pause.
library;

/// How far other apps' music is lowered.
enum SpeedAudioLevel {
  normal(1.0),
  duck60(0.6),
  duck30(0.3),
  pause(0.0);

  /// Fraction of the rider's original media volume (0 = paused).
  final double fraction;
  const SpeedAudioLevel(this.fraction);

  bool get isPause => this == SpeedAudioLevel.pause;
}

enum SpeedAudioCommandKind {
  /// Lower other apps' music to [SpeedAudioCommand.level] (or pause it).
  apply,

  /// Episode over: bring the original volume back (and resume paused music).
  restore,

  /// Episode over, but the rider took control of the volume: forget the saved volume, touch nothing.
  forget,
}

class SpeedAudioCommand {
  final SpeedAudioCommandKind kind;
  final SpeedAudioLevel level;
  const SpeedAudioCommand._(this.kind, this.level);

  const SpeedAudioCommand.apply(SpeedAudioLevel level) : this._(SpeedAudioCommandKind.apply, level);
  static const SpeedAudioCommand restore = SpeedAudioCommand._(SpeedAudioCommandKind.restore, SpeedAudioLevel.normal);
  static const SpeedAudioCommand forget = SpeedAudioCommand._(SpeedAudioCommandKind.forget, SpeedAudioLevel.normal);

  @override
  bool operator ==(Object other) => other is SpeedAudioCommand && other.kind == kind && other.level == level;

  @override
  int get hashCode => Object.hash(kind, level);

  @override
  String toString() => 'SpeedAudioCommand($kind, $level)';
}

class SpeedAudioPolicy {
  SpeedAudioPolicy({
    this.minOverMs = 4000,
    this.restoreAfterMs = 5000,
    this.hysteresisKmh = 3,
  });

  /// Continuous time over the limit before the music is touched.
  final int minOverMs;

  /// Continuous time back under (limit - [hysteresisKmh]) before the volume is restored.
  final int restoreAfterMs;
  final double hysteresisKmh;

  SpeedAudioLevel _applied = SpeedAudioLevel.normal;
  int? _overSince;
  int? _underSince;
  bool _userOverride = false;

  /// The level currently applied by the app (normal when nothing is lowered).
  SpeedAudioLevel get applied => _applied;

  /// The rider changed the volume during this episode; nothing more is changed until it ends.
  bool get userOverride => _userOverride;

  /// Something was lowered in this episode (by the app, or then taken over by the rider).
  bool get episodeActive => _applied != SpeedAudioLevel.normal || _userOverride;

  /// The level the speed asks for, ignoring timing: see the table in the library comment.
  static SpeedAudioLevel levelFor(double speedKmh, int limitKmh) {
    if (limitKmh <= 0 || !speedKmh.isFinite || speedKmh <= limitKmh) return SpeedAudioLevel.normal;
    final over = (speedKmh - limitKmh) / limitKmh;
    if (over >= 0.40) return SpeedAudioLevel.pause;
    if (over >= 0.25) return SpeedAudioLevel.duck30;
    if (over >= 0.10) return SpeedAudioLevel.duck60;
    return SpeedAudioLevel.normal;
  }

  /// One GPS sample. Returns the command to send to the native side, or null when nothing changes.
  ///
  /// [enabled] is the rider's setting AND the admin switch; [emergency] is an open SOS / crash alarm.
  SpeedAudioCommand? onSample({
    required double speedKmh,
    required int limitKmh,
    required int nowMs,
    bool enabled = true,
    bool emergency = false,
  }) {
    if (!enabled || emergency || limitKmh <= 0) return end();
    if (!speedKmh.isFinite || speedKmh < 0) return null; // no usable speed: keep the state

    if (speedKmh > limitKmh) {
      _underSince = null;
      final since = _overSince ??= nowMs;
      if (_userOverride) return null;
      final want = levelFor(speedKmh, limitKmh);
      if (want.index > _applied.index && nowMs - since >= minOverMs) {
        _applied = want;
        return SpeedAudioCommand.apply(want);
      }
      return null;
    }

    _overSince = null;
    if (!episodeActive) return null;
    if (speedKmh <= limitKmh - hysteresisKmh) {
      final since = _underSince ??= nowMs;
      if (nowMs - since >= restoreAfterMs) return end();
    } else {
      _underSince = null; // between (limit - hysteresis) and the limit: not back under yet
    }
    return null;
  }

  /// The rider changed the media volume or resumed the music during the episode.
  void noteUserAdjusted() {
    if (_applied == SpeedAudioLevel.normal) return;
    _userOverride = true;
  }

  /// Ends the episode now (ride end, SOS, setting off). Restore when the app had lowered something
  /// and the rider did not take over; forget when the rider took over; null when nothing was lowered.
  SpeedAudioCommand? end() {
    final lowered = _applied != SpeedAudioLevel.normal;
    final override = _userOverride;
    _applied = SpeedAudioLevel.normal;
    _overSince = null;
    _underSince = null;
    _userOverride = false;
    if (!lowered) return null;
    return override ? SpeedAudioCommand.forget : SpeedAudioCommand.restore;
  }
}
