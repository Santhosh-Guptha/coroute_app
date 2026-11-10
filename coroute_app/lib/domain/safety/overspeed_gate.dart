// 3.55 alert latency review: the rider's own overspeed warning (group / personal limit), pure Dart.
//
// Before: warn above limit + 1.5 km/h after a 1.5 s hold (two to three fixes at 1 Hz, so about
// 2 s), the episode ended the moment the speed touched the limit, and a new episode spoke again at
// once: hovering at the limit (79-82 in an 80 zone) repeated the voice every few seconds and kept
// the speech queue busy, which delayed the next real alert.
//
// Now:
//  * warn above limit + [warnOverKmh] (2 km/h) once that has held for [hold] (1 s: the second
//    fix over the line), or at once at limit + [immediateOverKmh] (10 km/h);
//  * the card hides when the speed is back at or under the limit, but the episode stays armed:
//    riding over again within it shows the card again without a new voice line;
//  * the episode ends (re-armed) only after [rearmFor] (5 s) under limit - [rearmBelowKmh] (3);
//  * while still over the line, a voice reminder every [repeatEvery] (25 s), never every fix.
enum OverspeedStep {
  /// Nothing changes.
  none,

  /// Warn now: show the card, buzz and speak (first warning of an episode, or a reminder).
  warn,

  /// Show / refresh the card without speaking (over again within the episode, speed changed).
  show,

  /// Hide the card (back at or under the limit); the episode is still armed.
  hide,

  /// The episode is over (re-armed, the limit is gone or changed): hide the card.
  clear,
}

class OverspeedGate {
  OverspeedGate({
    this.warnOverKmh = 2,
    this.immediateOverKmh = 10,
    this.hold = const Duration(seconds: 1),
    this.rearmBelowKmh = 3,
    this.rearmFor = const Duration(seconds: 5),
    this.repeatEvery = const Duration(seconds: 25),
  });

  final double warnOverKmh;
  final double immediateOverKmh;
  final Duration hold;
  final double rearmBelowKmh;
  final Duration rearmFor;
  final Duration repeatEvery;

  bool _active = false;
  bool _shown = false;
  int _overSince = 0;
  int _belowSince = 0;
  int _lastVoiceAt = 0;
  int _limit = 0;

  /// An episode is running (warned and not re-armed yet).
  bool get active => _active;

  /// The card should be showing.
  bool get showing => _shown;

  /// One fix: [speedKmh] against [limitKmh] (0 = no limit) at [nowMs].
  OverspeedStep update({required double speedKmh, required int limitKmh, required int nowMs}) {
    if (limitKmh != _limit) {
      // A new limit (Settings, the lead, a town zone): judge afresh, speak the new limit.
      final was = _active || _shown;
      _limit = limitKmh;
      _active = false;
      _shown = false;
      _overSince = 0;
      _belowSince = 0;
      _lastVoiceAt = 0;
      if (limitKmh <= 0 || !speedKmh.isFinite) return was ? OverspeedStep.clear : OverspeedStep.none;
      final next = update(speedKmh: speedKmh, limitKmh: limitKmh, nowMs: nowMs);
      return next == OverspeedStep.none && was ? OverspeedStep.clear : next;
    }
    if (limitKmh <= 0 || !speedKmh.isFinite) return OverspeedStep.none;
    final over = speedKmh > limitKmh + warnOverKmh;
    if (!_active) {
      if (!over) {
        _overSince = 0;
        return OverspeedStep.none;
      }
      if (_overSince == 0) _overSince = nowMs;
      final immediate = speedKmh >= limitKmh + immediateOverKmh;
      if (!immediate && nowMs - _overSince < hold.inMilliseconds) return OverspeedStep.none;
      _active = true;
      _shown = true;
      _belowSince = 0;
      _lastVoiceAt = nowMs;
      return OverspeedStep.warn;
    }
    // Episode running.
    if (speedKmh < limitKmh - rearmBelowKmh) {
      if (_belowSince == 0) _belowSince = nowMs;
      if (nowMs - _belowSince >= rearmFor.inMilliseconds) {
        _active = false;
        _shown = false;
        _overSince = 0;
        _belowSince = 0;
        return OverspeedStep.clear;
      }
    } else {
      _belowSince = 0;
    }
    if (over) {
      _shown = true;
      if (nowMs - _lastVoiceAt >= repeatEvery.inMilliseconds) {
        _lastVoiceAt = nowMs;
        return OverspeedStep.warn;
      }
      return OverspeedStep.show;
    }
    if (speedKmh <= limitKmh && _shown) {
      _shown = false;
      return OverspeedStep.hide;
    }
    return OverspeedStep.none;
  }

  /// The rider tapped "Slowing down": the card goes, the next reminder waits a full [repeatEvery].
  void acknowledge(int nowMs) {
    _shown = false;
    _lastVoiceAt = nowMs;
  }

  void reset() {
    _active = false;
    _shown = false;
    _overSince = 0;
    _belowSince = 0;
    _lastVoiceAt = 0;
    _limit = 0;
  }
}
