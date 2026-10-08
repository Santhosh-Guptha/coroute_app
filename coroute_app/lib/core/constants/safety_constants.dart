/// Rider safety (3.14): crash detection, emergency texts, break reminder and
/// the "Are you OK?" check-in. Every threshold lives here so it can be tuned
/// without touching the logic.
class SafetyConstants {
  SafetyConstants._();

  // ---------------------------------------------------------------- crash detector
  /// The detector is armed only while a fix in the last [crashArmWindow] was faster than this.
  static const double crashArmSpeedKmh = 25;
  static const Duration crashArmWindow = Duration(seconds: 30);

  /// A one-second bucket with a peak at or above this (in g) is a possible impact.
  static const double crashImpactG = 4.0;

  /// After the impact the phone must stop (<= [crashStopSpeedKmh]) within this time...
  static const Duration crashStopWithin = Duration(seconds: 10);
  static const double crashStopSpeedKmh = 5;

  /// ...and then the alarm opens [crashStillFor] after the stop, unless the rider rides on
  /// within that time: a fix faster than [crashResumeKmh], or farther than [crashStillMaxMoveM]
  /// from the stop. Getting up and walking about does NOT cancel it (product decision r314:
  /// the rider answers "I'm OK" on the alarm). Only when the GPS gave no fix at all after the
  /// impact (no proof of a stop) must every bucket also be calmer than [crashStillStdG].
  static const Duration crashStillFor = Duration(seconds: 20);
  static const double crashStillStdG = 0.15;
  static const double crashStillMaxMoveM = 80;
  static const double crashResumeKmh = 15;

  /// The first seconds after the stop are not judged for stillness (the slide ends, GPS speed lags).
  static const Duration crashSettle = Duration(seconds: 2);

  /// The alarm ("Possible accident detected. Are you okay?") counts down this long before
  /// the SOS is sent (3.15: 15 s, was 30 s).
  static const Duration crashCountdown = Duration(seconds: 15);

  /// No new alarm for this long after an alarm was answered.
  static const Duration crashCooldown = Duration(minutes: 2);

  /// Accelerometer: 50 Hz, delivered in hardware batches of up to 2 s so the phone can sleep.
  static const int accelSamplingUs = 20000;
  static const int accelMaxLatencyUs = 2000000;

  // ---------------------------------------------------------------- break reminder
  static const Duration fatigueRideFor = Duration(hours: 2);
  static const Duration fatigueBreakFor = Duration(minutes: 10);
  static const Duration fatigueRemindAgain = Duration(minutes: 60);

  /// Speed at or above which a fix counts as riding for the break reminder.
  static const double fatigueMovingKmh = 5;

  // ---------------------------------------------------------------- solo check-in
  static const Duration checkInFarFor = Duration(minutes: 15);
  static const Duration checkInAnswerWithin = Duration(minutes: 2);
  static const Duration checkInOthersFresh = Duration(minutes: 5);
  static const Duration checkInRepeatAfter = Duration(minutes: 30);
  static const Duration checkInEvalEvery = Duration(seconds: 15);

  // ---------------------------------------------------------------- emergency texts
  /// At most this many people are texted per SOS (Android limits bulk texts).
  static const int smsMaxRecipients = 10;

  /// An SOS that has not reached the group after this long is texted (when allowed).
  static const Duration smsFallbackAfter = Duration(seconds: 45);

  /// Text parts this phone sends in any [smsBudgetWindow] (Android asks the user at about 30).
  static const int smsMaxPartsPer30Min = 20;
  static const Duration smsBudgetWindow = Duration(minutes: 30);

  /// One text gets a result (sent or failed) within this time, else it counts as a timeout.
  static const Duration smsSendTimeout = Duration(seconds: 20);

  // ---------------------------------------------------------------- storage keys
  static const String keyCrashDetection = 'coroute_crash_detection';
  static const String keySmsFallback = 'coroute_sms_fallback';
  static const String keyFatigueReminder = 'coroute_fatigue_reminder';
  static const String keySoloCheckIn = 'coroute_solo_check_in';
  static const String keyOemGuideSeen = 'coroute_oem_guide_seen';

  /// Timestamps and part counts of sent texts (never numbers or text).
  static const String keySmsLog = 'coroute_sms_log';

  // ---------------------------------------------------------------- notifications
  static const String channelCrash = 'coroute_crash';
  static const String channelSafety = 'coroute_safety';
  static const String channelAdminAlarm = 'coroute_admin_alarm';

  static const int crashAlarmId = 1101;
  static const int checkInId = 1102;
  static const int fatigueId = 1103;
  static const int adminAlarmId = 1110;

  /// Keys of the local prompts (the same keys AlertPolicy uses).
  static const String promptFatigue = 'LOCAL:FATIGUE';
  static const String promptCheckIn = 'LOCAL:CHECK_IN';
}
