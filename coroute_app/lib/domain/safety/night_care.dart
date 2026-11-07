/// Night riding care (3.55), pure: earlier break prompts after sunset and one spoken note at
/// sunset. The day / night flag comes from SafetyService (sunset computed on the phone).
///
/// * Break interval: [dayRideFor] (2 h) by day, [nightRideFor] (90 min) after sunset. The regular
///   2 h FatigueTracker prompt (with its confirmation and Lead escalation) stays as it is;
///   [earlyBreakDue] adds one softer, earlier break prompt per riding stretch at night.
/// * Sunset note: once per ride, only when the ride saw daylight first (a ride started at night
///   gets no "sun has set" line).
class NightCare {
  NightCare({
    this.dayRideFor = const Duration(hours: 2),
    this.nightRideFor = const Duration(minutes: 90),
  });

  final Duration dayRideFor;
  final Duration nightRideFor;

  static const String sunsetSpeech = 'Sun has set. Breaks come a little earlier tonight. Keep extra distance.';
  static const String sunsetTitle = 'Sun has set';
  static const String sunsetMessage = 'Breaks come a little earlier tonight. Keep extra distance.';

  bool _sawDay = false;
  bool _saidSunset = false;
  int? _earlyFor; // stretch start the early prompt was given for

  void reset() {
    _sawDay = _saidSunset = false;
    _earlyFor = null;
  }

  /// The break interval for the time of day.
  Duration breakInterval({required bool dark}) => dark ? nightRideFor : dayRideFor;

  /// True once when the day / night flag turns to night during a ride that saw daylight.
  bool onDark(bool dark) {
    if (!dark) {
      _sawDay = true;
      return false;
    }
    if (_sawDay && !_saidSunset) {
      _saidSunset = true;
      return true;
    }
    return false;
  }

  /// True once per riding stretch when it reaches the night interval after sunset, before the
  /// regular day prompt would come.
  bool earlyBreakDue({required int? stretchStartMs, required int nowMs, required bool dark}) {
    if (!dark || stretchStartMs == null) return false;
    if (_earlyFor == stretchStartMs) return false;
    final rode = nowMs - stretchStartMs;
    if (rode < nightRideFor.inMilliseconds || rode >= dayRideFor.inMilliseconds) return false;
    _earlyFor = stretchStartMs;
    return true;
  }
}
