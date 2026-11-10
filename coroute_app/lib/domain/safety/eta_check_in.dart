import '../../core/constants/app_constants.dart';

/// 3.55 "Solo check-in timer" (switch `soloCheckIn`): the emergency contact is texted when a solo
/// rider does not arrive or answer by the ETA plus a margin.
///
/// Pure: no timers, no clock. The caller ([SoloGuardianService]) calls [tick] about every 30 s and
/// on every ETA it computes on the phone (route pace, works without signal).
///
/// Flow:
///  * [arm] when a solo ride with a destination starts: deadline = now + ETA + margin, where the
///    margin is max(20 min, 25 % of the ETA).
///  * [updateEta] while the rider is moving: the deadline only ever moves LATER (traffic, a longer
///    road), and a re-arm never sets it sooner than 10 min from now. While stopped the deadline is
///    left alone, so a rider who has fallen and is not moving is still checked on.
///  * At the deadline: [EtaCheckInAction.ask] ("Are you OK? Tap if you're fine", voice + prompt),
///    then, with no answer within [askFor] (3 min): [EtaCheckInAction.escalate] (text the emergency
///    contact once, with the last known position link). Riding on while asked ([ridingOn]) counts
///    as "I'm fine": a moving rider is never reported overdue.
///  * [imFine] / [extend] (+30 min) from the prompt; after an escalation [imFine] says that a "fine
///    now" text should follow. Arriving or ending the ride: [disarm].
enum EtaCheckInPhase { idle, armed, asking, escalated }

enum EtaCheckInAction { none, ask, escalate }

class EtaCheckIn {
  EtaCheckIn({
    this.minMargin = const Duration(minutes: 20),
    this.marginShare = 0.25,
    this.minLead = const Duration(minutes: 10),
    this.askFor = const Duration(minutes: 3),
    this.extendBy = const Duration(minutes: 30),
  });

  final Duration minMargin;
  final double marginShare;
  final Duration minLead;
  final Duration askFor;
  final Duration extendBy;

  EtaCheckInPhase _phase = EtaCheckInPhase.idle;
  int? _deadlineMs;
  int? _askedAtMs;
  int? _escalatedAtMs;

  EtaCheckInPhase get phase => _phase;
  bool get active => _phase != EtaCheckInPhase.idle;
  bool get asking => _phase == EtaCheckInPhase.asking;
  bool get escalated => _phase == EtaCheckInPhase.escalated;

  /// When the rider is asked (null when not armed).
  int? get deadlineMs => _phase == EtaCheckInPhase.armed ? _deadlineMs : null;
  int? get askedAtMs => _askedAtMs;
  int? get escalatedAtMs => _escalatedAtMs;

  /// Margin added to an ETA: max([minMargin], [marginShare] of the ETA).
  Duration marginFor(Duration eta) {
    final share = Duration(milliseconds: (eta.inMilliseconds * marginShare).round());
    return share > minMargin ? share : minMargin;
  }

  int _target(int nowMs, Duration eta) {
    final e = eta.isNegative ? Duration.zero : eta;
    return nowMs + e.inMilliseconds + marginFor(e).inMilliseconds;
  }

  /// Starts the timer (ride start with a destination and an ETA).
  void arm({required int nowMs, required Duration eta}) {
    _phase = EtaCheckInPhase.armed;
    _deadlineMs = _target(nowMs, eta);
    _askedAtMs = null;
    _escalatedAtMs = null;
  }

  /// A new ETA while moving. Returns true when the deadline moved (only ever later, and never to
  /// less than [minLead] from now).
  bool updateEta({required int nowMs, required Duration eta}) {
    if (_phase != EtaCheckInPhase.armed) return false;
    final cur = _deadlineMs ?? 0;
    var next = _target(nowMs, eta);
    if (next <= cur) return false;
    final floor = nowMs + minLead.inMilliseconds;
    if (next < floor) next = floor;
    _deadlineMs = next;
    return true;
  }

  /// What to do now (call about every 30 s; at most one step per call).
  EtaCheckInAction tick(int nowMs) {
    switch (_phase) {
      case EtaCheckInPhase.armed:
        final d = _deadlineMs;
        if (d == null || nowMs < d) return EtaCheckInAction.none;
        _phase = EtaCheckInPhase.asking;
        _askedAtMs = nowMs;
        return EtaCheckInAction.ask;
      case EtaCheckInPhase.asking:
        final at = _askedAtMs ?? nowMs;
        if (nowMs - at < askFor.inMilliseconds) return EtaCheckInAction.none;
        _phase = EtaCheckInPhase.escalated;
        _escalatedAtMs = nowMs;
        return EtaCheckInAction.escalate;
      case EtaCheckInPhase.idle:
      case EtaCheckInPhase.escalated:
        return EtaCheckInAction.none;
    }
  }

  /// "I'm fine": armed again for max([extendBy], ETA + margin). Returns true when the contact was
  /// already texted (a "fine now" text should follow).
  bool imFine({required int nowMs, Duration? eta}) {
    if (_phase == EtaCheckInPhase.idle) return false;
    final told = _phase == EtaCheckInPhase.escalated;
    final byEta = eta == null ? 0 : _target(nowMs, eta);
    final byExtend = nowMs + extendBy.inMilliseconds;
    _phase = EtaCheckInPhase.armed;
    _deadlineMs = byEta > byExtend ? byEta : byExtend;
    _askedAtMs = null;
    _escalatedAtMs = null;
    return told;
  }

  /// "+30 min": the deadline moves [extendBy] past the later of now and the current deadline.
  /// Returns true when the contact was already texted.
  bool extend({required int nowMs}) {
    if (_phase == EtaCheckInPhase.idle) return false;
    final told = _phase == EtaCheckInPhase.escalated;
    final base = _phase == EtaCheckInPhase.armed && (_deadlineMs ?? 0) > nowMs ? _deadlineMs! : nowMs;
    _phase = EtaCheckInPhase.armed;
    _deadlineMs = base + extendBy.inMilliseconds;
    _askedAtMs = null;
    _escalatedAtMs = null;
    return told;
  }

  /// 3.55 false-SOS review: asked, then the rider rode on (fresh fix at riding speed) without
  /// tapping: they are fine. Armed again as after "I'm fine", so no text goes to the contact while
  /// they are riding. True when this closed an open question.
  bool ridingOn({required int nowMs, Duration? eta}) {
    if (_phase != EtaCheckInPhase.asking) return false;
    imFine(nowMs: nowMs, eta: eta);
    return true;
  }

  /// Arrived, ride ended, setting off: nothing more happens.
  void disarm() {
    _phase = EtaCheckInPhase.idle;
    _deadlineMs = null;
    _askedAtMs = null;
    _escalatedAtMs = null;
  }
}

/// The texts of the solo check-in (plain GSM text, a map link, no phone numbers).
class EtaCheckInSms {
  EtaCheckInSms._();

  static String _two(int v) => v < 10 ? '0$v' : '$v';
  static String _hm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

  /// "CoRoute check-in: Asha has not reached Manali by 16:40 and did not answer.
  /// Last known position at 15:58: <link>"
  static String overdue({
    required String name,
    required String destination,
    required DateTime expectedBy,
    double? lat,
    double? lng,
    DateTime? fixAt,
  }) {
    final who = name.trim().isEmpty ? 'A rider' : name.trim();
    final dest = destination.trim();
    final where = dest.isEmpty ? 'the destination' : dest;
    final hasPos = lat != null && lng != null && !(lat == 0 && lng == 0);
    final pos = hasPos
        ? ' Last known position${fixAt != null ? ' at ${_hm(fixAt)}' : ''}: ${AppConstants.mapsLink(lat, lng, digits: 5)}'
        : ' No recent position.';
    return 'CoRoute check-in: $who has not reached $where by ${_hm(expectedBy)} and did not answer.$pos';
  }

  /// Sent after [overdue] when the rider then taps "I'm fine".
  static String fineNow({required String name, required DateTime at}) {
    final who = name.trim().isEmpty ? 'The rider' : name.trim();
    return 'CoRoute check-in: $who answered "I\'m fine" at ${_hm(at)}.';
  }
}
