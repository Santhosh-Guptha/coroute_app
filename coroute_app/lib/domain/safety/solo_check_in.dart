import '../../core/constants/safety_constants.dart';

enum CheckInStep { prompt, noReply }

/// "Are you OK?" for a rider who has been far from the group for a long time.
///
/// Pure. [onSample] is called when the convoy changes (the caller throttles it);
/// [onTimeout] when the answer timer runs out. Steps:
/// far (more than the group's separation limit from the median of the riders
/// seen in the last 5 min) for [farFor] -> [CheckInStep.prompt]; no answer
/// within [answerWithin] -> [CheckInStep.noReply] (the lead is told). Not asked
/// again for [repeatAfter] after a prompt.
class SoloCheckIn {
  SoloCheckIn({
    this.farFor = SafetyConstants.checkInFarFor,
    this.answerWithin = SafetyConstants.checkInAnswerWithin,
    this.repeatAfter = SafetyConstants.checkInRepeatAfter,
  });

  final Duration farFor;
  final Duration answerWithin;
  final Duration repeatAfter;

  int? _farSince;
  int? _promptAt;
  int? _noReplyAt;
  int? _lastPromptAt;

  /// A prompt is open and has not been answered.
  bool get awaitingAnswer => _promptAt != null;

  /// The lead was told "No reply" for the open prompt (an "I'm OK" must then be sent).
  bool get noReplySent => _noReplyAt != null;

  /// [awayM] is null when no other rider was seen recently (nothing to compare with).
  CheckInStep? onSample({required int tMs, double? awayM, required double limitM}) {
    if (awayM == null || !awayM.isFinite || awayM <= limitM) {
      _farSince = null;
      // Back with the group before the lead was told: the question is answered.
      if (_promptAt != null && _noReplyAt == null) _promptAt = null;
      return null;
    }
    final since = _farSince ??= tMs;
    if (_promptAt != null || _noReplyAt != null) return null;
    if (tMs - since < farFor.inMilliseconds) return null;
    final last = _lastPromptAt;
    if (last != null && tMs - last < repeatAfter.inMilliseconds) return null;
    _promptAt = tMs;
    _lastPromptAt = tMs;
    return CheckInStep.prompt;
  }

  CheckInStep? onTimeout(int tMs) {
    final at = _promptAt;
    if (at == null || _noReplyAt != null) return null;
    if (tMs - at < answerWithin.inMilliseconds) return null;
    _noReplyAt = tMs;
    return CheckInStep.noReply;
  }

  /// The rider said "I'm OK". Far-time counting starts again; no new prompt for [repeatAfter].
  void answeredOk(int tMs) {
    _promptAt = null;
    _noReplyAt = null;
    _farSince = null;
  }

  void reset() {
    _farSince = null;
    _promptAt = null;
    _noReplyAt = null;
    _lastPromptAt = null;
  }
}
