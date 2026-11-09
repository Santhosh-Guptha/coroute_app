import '../tracking/geo_math.dart';
import 'group_safety_rider.dart';

/// What the phone should do after an [MissingRiderCheck.evaluate].
enum MissingRiderAction {
  none,

  /// Show "Are you OK? The group is moving on" (and say it once).
  ask,

  /// 90 s without an answer: tell the lead (CHECK_IN NO_REPLY through the existing path).
  sendNoReply,

  /// No answer, but the server's own STOPPED / SEPARATED rule told the lead in the last 5 min:
  /// nothing is sent (no duplicate alert); the card stays.
  noReplySuppressed,

  /// The rider moved on or the group came back: the card goes away, nothing is sent.
  clear,

  /// 3.55 pillion pair: the other phone on my bike (my rider or my seated pillion) answered this
  /// stop's check (I'm OK, a stop reason, Need help). The card closes here too and this phone
  /// sends no "no answer". When this phone had already told the lead
  /// ([MissingRiderCheck.closedAfterNoReply]), it sends I'm OK so the lead's entry closes.
  answeredOnOtherPhone,
}

enum MissingRiderPhase { idle, asking, noReplySent }

/// 3.55 missing-rider check, on the rider's own phone (pure, no timers: fed every few seconds).
///
/// Asks "Are you OK?" when ALL of these hold:
///  * I have been stopped for [stoppedFor] (slower than [stoppedKmh] and within [anchorM] of where
///    I stopped), or my phone saw no new fix for [stoppedFor] (silent phone);
///  * at least [movingShare] of the other fresh riders are moving ([movingKmh] or faster);
///  * the nearest moving rider is farther than [awayM] and that distance grew by [growM] since I
///    stopped (they are riding away, not parked around the corner);
///  * I gave no stop reason (fuel, photo...), no SOS / crash alarm is open, I did not answer in the
///    last [quietAfterAnswer] of this same stop.
/// No answer within [answerWithin] → [MissingRiderAction.sendNoReply] once, unless the server
/// already alerted the lead about me in the last [serverAlertWindow] (STOPPED / SEPARATED /
/// NO_REPLY / POSSIBLE_INCIDENT seen on my phone).
class MissingRiderCheck {
  MissingRiderCheck({
    this.stoppedFor = const Duration(minutes: 3),
    this.stoppedKmh = 5,
    this.anchorM = 80,
    this.movingKmh = 15,
    this.movingShare = 0.6,
    this.awayM = 1000,
    this.growM = 300,
    this.answerWithin = const Duration(seconds: 90),
    this.serverAlertWindow = const Duration(minutes: 5),
    this.quietAfterAnswer = const Duration(minutes: 15),
  });

  final Duration stoppedFor;
  final double stoppedKmh;
  final double anchorM;
  final double movingKmh;
  final double movingShare;
  final double awayM;
  final double growM;
  final Duration answerWithin;
  final Duration serverAlertWindow;
  final Duration quietAfterAnswer;

  MissingRiderPhase _phase = MissingRiderPhase.idle;
  MissingRiderPhase get phase => _phase;

  int? _stoppedSince;
  double? _anchorLat, _anchorLng;
  double? _nearestAtStop;
  double? _lastNearestM;
  int? _askedAt;
  int? _answeredAt;

  /// Distance to the nearest moving rider at the last evaluation (for the card text).
  double? get nearestMovingM => _lastNearestM;
  int? get askedAtMs => _askedAt;
  bool get showing => _phase != MissingRiderPhase.idle;

  /// When I stopped (null while moving).
  int? get stoppedSinceMs => _stoppedSince;

  /// After [MissingRiderAction.answeredOnOtherPhone]: this phone had already sent "no answer".
  bool closedAfterNoReply = false;

  /// Phones' clocks differ a little: a partner answer up to this much before my stop counts.
  static const int partnerClockSlackMs = 120000;

  /// True when the bike partner's answer ([partnerAnsweredAtMs], their status time) belongs to the
  /// stop I am in now (pure, for tests).
  bool partnerAnsweredThisStop(int? partnerAnsweredAtMs) =>
      partnerAnsweredAtMs != null && partnerAnsweredAtMs > 0 && _stoppedSince != null &&
      partnerAnsweredAtMs >= _stoppedSince! - partnerClockSlackMs;

  /// The rider answered (I'm OK / waiting for a reason / need help): the card goes, no new ask
  /// during this stop for [quietAfterAnswer].
  void answered(int nowMs) {
    _phase = MissingRiderPhase.idle;
    _answeredAt = nowMs;
    _askedAt = null;
  }

  void reset() {
    _phase = MissingRiderPhase.idle;
    _stoppedSince = null;
    _anchorLat = _anchorLng = null;
    _nearestAtStop = null;
    _lastNearestM = null;
    _askedAt = null;
    _answeredAt = null;
  }

  /// [me]: my own latest position (speed from GPS, [GroupSafetyRider.lastSeenMs] = my last fix).
  /// [others]: everyone else in the ride. [lastServerAlertMs]: newest server alert about me.
  MissingRiderAction evaluate({
    required int nowMs,
    required GroupSafetyRider me,
    required List<GroupSafetyRider> others,
    bool emergencyOpen = false,
    int? lastServerAlertMs,
    int? partnerAnsweredAtMs,
  }) {
    _track(nowMs, me);
    // 3.55 pillion pair: either phone answering counts for both (one bike, one answer).
    if (partnerAnsweredThisStop(partnerAnsweredAtMs)) {
      if (!showing) {
        // Nothing on screen: no ask during this stop (the quiet time after an answer).
        answered(nowMs);
        return MissingRiderAction.none;
      }
      closedAfterNoReply = _phase == MissingRiderPhase.noReplySent;
      answered(nowMs);
      return MissingRiderAction.answeredOnOtherPhone;
    }
    final fresh = others.where((r) => r.userId != me.userId && r.isFresh(nowMs)).toList();
    final moving = fresh.where((r) => r.speedKmh >= movingKmh).toList();
    double? nearest;
    if (me.hasPosition) {
      for (final r in moving) {
        final d = GeoMath.haversine(me.lat, me.lng, r.lat, r.lng);
        if (nearest == null || d < nearest) nearest = d;
      }
    }
    _lastNearestM = nearest;
    if (_stoppedSince != null && nearest != null) {
      _nearestAtStop = _nearestAtStop == null ? nearest : (nearest < _nearestAtStop! ? nearest : _nearestAtStop);
    }

    final stopped = _stoppedSince != null && nowMs - _stoppedSince! >= stoppedFor.inMilliseconds;
    final groupMoving = fresh.isNotEmpty && moving.length >= fresh.length * movingShare;
    final away = nearest != null && nearest > awayM && nearest - (_nearestAtStop ?? nearest) >= growM;
    final quiet = _answeredAt != null && nowMs - _answeredAt! < quietAfterAnswer.inMilliseconds;
    final conditions = stopped && groupMoving && away && me.statusReason.isEmpty && !emergencyOpen && !quiet;

    switch (_phase) {
      case MissingRiderPhase.idle:
        if (!conditions) return MissingRiderAction.none;
        _phase = MissingRiderPhase.asking;
        _askedAt = nowMs;
        return MissingRiderAction.ask;
      case MissingRiderPhase.asking:
        // I am riding again, the group came back, I gave a reason, or an alarm took over.
        if (_stoppedSince == null || me.statusReason.isNotEmpty || emergencyOpen || (nearest != null && nearest < awayM * 0.8)) {
          _phase = MissingRiderPhase.idle;
          _askedAt = null;
          return MissingRiderAction.clear;
        }
        if (nowMs - (_askedAt ?? nowMs) < answerWithin.inMilliseconds) return MissingRiderAction.none;
        _phase = MissingRiderPhase.noReplySent;
        final told = lastServerAlertMs != null && nowMs - lastServerAlertMs <= serverAlertWindow.inMilliseconds;
        return told ? MissingRiderAction.noReplySuppressed : MissingRiderAction.sendNoReply;
      case MissingRiderPhase.noReplySent:
        if (_stoppedSince == null || me.statusReason.isNotEmpty || emergencyOpen) {
          _phase = MissingRiderPhase.idle;
          _askedAt = null;
          return MissingRiderAction.clear;
        }
        return MissingRiderAction.none;
    }
  }

  void _track(int nowMs, GroupSafetyRider me) {
    final silent = me.lastSeenMs > 0 && nowMs - me.lastSeenMs >= stoppedFor.inMilliseconds;
    if (silent) {
      // No fix progress for the whole hold time: count it as stopped since the last fix.
      _stoppedSince ??= me.lastSeenMs;
      return;
    }
    if (!me.hasPosition) return;
    final slow = me.speedKmh < stoppedKmh;
    final anchored = _anchorLat != null && GeoMath.haversine(_anchorLat!, _anchorLng!, me.lat, me.lng) <= anchorM;
    if (slow && (_stoppedSince == null || anchored)) {
      if (_stoppedSince == null) {
        _stoppedSince = nowMs;
        _anchorLat = me.lat;
        _anchorLng = me.lng;
        _nearestAtStop = null;
      }
      return;
    }
    if (_stoppedSince != null && (me.speedKmh >= 10 || !anchored)) {
      // Riding again: a new stop starts a new check (the answer quiet time ends with the stop).
      _stoppedSince = null;
      _anchorLat = _anchorLng = null;
      _nearestAtStop = null;
      _answeredAt = null;
    }
  }
}
