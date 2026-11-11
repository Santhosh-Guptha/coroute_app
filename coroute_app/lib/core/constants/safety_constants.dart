/// Rider safety (3.14): crash detection, emergency texts, break reminder and
/// the "Are you OK?" check-in. Every threshold lives here so it can be tuned
/// without touching the logic.
class SafetyConstants {
  SafetyConstants._();

  // ---------------------------------------------------------------- emergency numbers (India)
  /// National emergency number (ERSS), ambulance, police and the NHAI highway helpline.
  static const String emergencyNumber = '112';
  static const String ambulanceNumber = '108';
  static const String policeNumber = '100';
  static const String highwayHelpline = '1073';
  static const List<String> emergencyNumbers = [emergencyNumber, ambulanceNumber, policeNumber, highwayHelpline];

  // ---------------------------------------------------------------- crash detector
  /// Arming (3.54, was "a fix above 25 km/h in the last 30 s"): the detector arms after the
  /// rider kept at least [crashArmSpeedKmh] for [crashArmSustain] (slow city traffic counts, so a
  /// low-speed tip-over is no longer missed), or at once on a fix above [crashInstantArmKmh].
  /// Hysteresis: once armed it stays armed through stop-and-go traffic and only disarms after
  /// [crashDisarmAfter] without a fix at riding pace ([crashLowSpeedArmKmh]), i.e. parked or walking.
  /// [crashArmSpeedKmh] is also the "was the phone at riding speed?" line of the impact check.
  static const double crashArmSpeedKmh = 12;
  static const Duration crashArmSustain = Duration(seconds: 10);
  static const double crashInstantArmKmh = 25;
  static const Duration crashDisarmAfter = Duration(minutes: 3);

  /// Window of the low-speed fall check (a fix at [crashLowSpeedArmKmh] or more this recently),
  /// and the longest GPS gap that still counts as one sustained run.
  static const Duration crashArmWindow = Duration(seconds: 30);

  /// Low-speed falls (intersection drops / tip-overs) are armed by a fix at or above this
  /// in the arm window: faster than walking or jogging, so a phone dropped on foot is ignored.
  static const double crashLowSpeedArmKmh = 10;

  /// A one-second bucket with a raw peak at or above this (in g) is a possible impact.
  static const double crashImpactG = 4.0;

  /// Gravity-compensated dynamic linear impact threshold in g.
  static const double crashDynamicImpactG = 3.8;

  /// Lowside / motorcycle slide threshold in g when accompanied by rotational fall evidence.
  static const double crashSlideImpactG = 2.0;

  /// Angular velocity threshold (rad/s) indicating severe motorcycle roll, yaw or tumble.
  static const double crashRotationRadS = 1.8;

  /// Orientation tilt threshold (degrees) indicating the motorcycle has fallen onto its side.
  static const double crashTiltThresholdDeg = 45.0;

  /// Minimum impact impulse duration (ms) to reject sub-sample impulses like pebble hits.
  static const double crashMinDurationMs = 25.0;

  /// Jerk (da/dt) threshold in g/s to evaluate abrupt shock impact transitions.
  static const double crashPeakJerkGPerS = 35.0;

  /// High-side crash angular snap rotation threshold (rad/s).
  static const double crashHighsideRotationRadS = 2.5;

  /// High-side crash orientation tilt inversion threshold (degrees).
  static const double crashHighsideTiltDeg = 55.0;

  /// Low-speed drop tilt threshold (degrees).
  static const double crashLowSpeedDropTiltDeg = 45.0;

  /// Pothole and speed-breaker discrimination parameters.
  static const double crashPotholeMaxDurationMs = 35.0;
  static const double crashPotholeMaxRotationRadS = 0.8;
  static const double crashPotholeMaxTiltDeg = 15.0;

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

  /// 3.55 false-SOS review (docs/features_355/sensor_safety.md). A severe impact (raw peak at or
  /// above [crashSevereImpactG] or dynamic peak at or above [crashSevereDynG], lasting at least
  /// [crashSevereMinDurationMs] when the phone reports the duration) keeps the fast path: a stop
  /// and no riding on. A milder impact also needs post-impact evidence: in the
  /// [crashEvidenceWindow] after the settle, at least [crashEvidenceMinBuckets] seconds with the
  /// phone tilted [crashEvidenceTiltDeg] or more, and [crashEvidenceTiltGainDeg] more than while
  /// riding just before (a fallen bike or rider). Potholes, speed breakers, kerbs and a loose
  /// phone followed by an ordinary stop (a red light, a toll) no longer open the alarm.
  static const double crashSevereImpactG = 7.0;
  static const double crashSevereDynG = 6.0;
  static const double crashSevereMinDurationMs = 50.0;
  static const double crashEvidenceTiltDeg = 40.0;
  static const double crashEvidenceTiltGainDeg = 30.0;
  static const Duration crashEvidenceWindow = Duration(seconds: 15);
  static const int crashEvidenceMinBuckets = 4;

  /// Riding on after an impact (fixes above [crashResumeKmh] for this long, speed not collapsing)
  /// drops the candidate at once; during the alarm countdown it cancels the alarm.
  static const Duration crashRideOnFor = Duration(seconds: 3);

  /// An abrupt stop is post-impact evidence as well: from 20 km/h or more down to the stop fix at
  /// this average deceleration or more, counted from the impact (braking for a light: 1.5-3 m/s2).
  static const double crashAbruptStopMps2 = 4.5;

  /// The alarm ("Possible accident detected. Are you okay?") counts down this long before
  /// the SOS is sent (3.15: 15 s, was 30 s; 3.55 false-SOS review: 30 s again, so a rider with
  /// the phone in a pocket or a tank bag has time to hear it and answer; riding away cancels it).
  static const Duration crashCountdown = Duration(seconds: 30);

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
  static const String promptFuel = 'LOCAL:FUEL';
  static const String promptFollowUp = 'LOCAL:FOLLOW_UP';
  static const String promptOverspeed = 'LOCAL:OVERSPEED';
  static const int fuelId = 1104;
  static const int followUpId = 1105;
  static const int overspeedId = 1106;
  static const String keySpeedLimitWarningKmh = 'coroute_speed_warning_kmh';

  /// My own speed warning choices in Settings (0 = use the group limit) and its upper bound.
  static const List<int> speedWarningChoices = [0, 50, 60, 80, 100, 120];
  static const int speedWarningMaxKmh = 200;

  // ---------------------------------------------------------------- overspeed warning
  /// Speed tolerance above the limit before alerting (km/h).
  static const double overspeedToleranceKmh = 1.5;
  /// Immediate alert if speeding by this much over the limit (km/h).
  static const double overspeedImmediateOverKmh = 10.0;
  /// Required hold duration (ms) for minor overspeeding before alerting (suppresses single jitter point).
  static const int overspeedHoldMs = 1500;
  /// Minimum interval between voice announcements while continuously overspeeding (ms).
  static const int overspeedVoiceRenotifyMs = 20000;

  // ---------------------------------------------------------------- fuel range (3.16)
  /// The reminder comes when this share of the tank range was ridden since the last fill.
  static const double fuelWarnFraction = 0.8;
  static const int fuelMinRangeKm = 50;
  static const int fuelMaxRangeKm = 1500;

  /// A jump between two fixes larger than this, or a gap longer than [fuelMaxGap], is not
  /// counted as distance (GPS teleports, app restarts).
  static const double fuelMaxJumpM = 500;
  static const Duration fuelMaxGap = Duration(minutes: 5);

  /// Distance ridden since the last fill, for the current ride (survives a restart).
  static const String keyFuelState = 'coroute_fuel_state_v1';

  // ---------------------------------------------------------------- hard stops (3.16)
  /// A bucket peak between this and [crashImpactG] with a speed drop of at least
  /// [hardBrakeDropKmh] within [hardBrakeWindow] is one hard stop; one per [hardBrakeDedupe].
  static const double hardBrakePeakG = 1.6;
  static const double hardBrakeDropKmh = 20;
  static const Duration hardBrakeWindow = Duration(seconds: 6);
  static const Duration hardBrakeDedupe = Duration(seconds: 10);

  /// Fixes the counter keeps to judge a drop.
  static const Duration hardBrakeFixWindow = Duration(seconds: 8);

  /// Rider-only ride statistics (hard stops per trip), never uploaded.
  static const String keyRideStats = 'coroute_ride_stats_v1';
  static const int rideStatsMax = 50;

  // ---------------------------------------------------------------- post-crash follow-up (3.16)
  /// After "I'm OK" on a real impact: one "Still okay?" at the next stop of at least
  /// [followUpStopFor], or [followUpAfter] later, whichever comes first.
  static const Duration followUpStopFor = Duration(seconds: 60);
  static const Duration followUpAfter = Duration(minutes: 20);

  // ---------------------------------------------------------------- dark (3.16)
  /// "Dark in 40 min" shows when sunset is this close.
  static const Duration darkWarnBefore = Duration(minutes: 60);

  /// The day/night flag is recomputed from fixes at most this often (or after a 20 km move).
  static const Duration darkRecheckEvery = Duration(minutes: 5);
  static const double darkRecheckMoveM = 20000;

  // ---------------------------------------------------------------- wearable hook (3.16)
  /// Impact value of the hidden developer action (no device work this round).
  static const double wearableImpactG = 6.0;

  // ---------------------------------------------------------------- map tiles (3.16)
  /// Configurable offline tile cache budget range (300 MB to 500 MB, default 300 MB since Nov 11:
  /// the same cap as automatic trip maps, OfflineMapRetention.maxBytes). LRU by last use.
  static const int tileCacheMinBudgetBytes = 300 * 1024 * 1024;
  static const int tileCacheMaxBudgetBytes = 500 * 1024 * 1024;
  static const int tileCacheMaxBytes = 300 * 1024 * 1024;
  static const int tileMaxAgeDays = 30;
  static const List<int> prefetchZooms = [11, 12, 13, 14, 15, 16];
  static const List<int> prefetchZoomsHighDetail = [11, 12, 13, 14, 15, 16, 17];
  static const int prefetchMaxTiles = 600;
  static const int prefetchMaxTilesHighDetail = 2500;
  static const int prefetchMaxTilesCommunity = 300;
  static const int freeOfflinePacksLimit = 1;
  static const double prefetchCorridorRadiusM = 2500.0; // 2.5 km lateral corridor
  static const Duration prefetchSpacing = Duration(milliseconds: 150);
  static const int prefetchParallel = 2;
  static const Duration prefetchTimeout = Duration(seconds: 8);
  static const int prefetchMaxFailures = 5;
  static const double prefetchSampleM = 200;
  static const String keyTilesPrefetchedFor = 'coroute_tiles_prefetched_for';
  static const String keySavedMapPacks = 'coroute_saved_map_packs_v1';

  // ---------------------------------------------------------------- weather (3.16)
  static const Duration weatherCacheFor = Duration(minutes: 30);
  static const int weatherMaxPoints = 5;

  /// A sample point takes the name of a planned stop within this distance.
  static const double weatherStopNearM = 2000;
}
