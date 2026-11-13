// Round 9 "fewer settings, sensible defaults on" (docs/quality/ROUND9_SETTINGS_NOTES.md), pure Dart.
//
// Owner request: "remove unnecessary setting options toggles make them on default reduce the settings".
// The settings below lost their switch or picker. SettingsService reads them as fixed values (a stored
// value from an older build is ignored, so nothing can crash on an old key) and, once, migration
// step 3 ([SettingsService.safetyDefaultsVersion] = 3) applies [plan]: the switches are written back
// as on and the retired multi-choice keys are deleted.
//
// Never touched by any step: consent and privacy choices ("Help make roads safer" lives on the server and
// in intel_settings_v1's 'con'; marketing / push kinds; leaderboards; the lock-screen cockpit), app lock,
// language, theme, data saver, voice alerts and battery saver (quick controls in the ride screen),
// siren alerts, the speed warning and hardware PTT.
class SettingsRound9 {
  SettingsRound9._();

  // Stored keys (same strings as SettingsService and NetworkConstants use).
  static const String keyCurveWarnings = 'road_curve_warnings';
  static const String keyRoadLimitDisplay = 'road_limit_display';
  static const String keyRoadOverspeedWarning = 'road_overspeed_warning';
  static const String keyRoadOverspeedTolerancePct = 'road_overspeed_tolerance_pct';
  static const String keyRideIdleMode = 'ride_idle_mode_v1';
  static const String keyKeepScreenOnMode = 'ride_keep_screen_on_v1';
  static const String keyLowerMusicWhenSpeeding = 'lower_music_when_speeding_v1';
  static const String keyPauseOtherAudio = 'coroute_pause_other_audio';
  static const String keyNoiseReduction = 'noise_reduction_v1';
  static const String keyWindNoiseMode = 'wind_noise_mode_v1';

  /// Switches that are always on now: written back as true once (a stored "off" is ignored anyway).
  static const List<String> alwaysOnKeys = [
    keyCurveWarnings,
    keyRoadLimitDisplay,
    keyRoadOverspeedWarning,
    keyLowerMusicWhenSpeeding,
    keyWindNoiseMode,
  ];

  /// Multi-choice keys collapsed to one smart default: deleted once (their getters return the default).
  static const List<String> retiredKeys = [
    keyRoadOverspeedTolerancePct, // automatic: +10 %, at least 5 km/h (0 near schools and hospitals)
    keyRideIdleMode, // Ride AOD; battery and heat rules fall back by themselves
    keyKeepScreenOnMode, // only while moving
    keyPauseOtherAudio, // music is lowered for warnings; critical lines always pause it
    keyNoiseReduction, // Strong
  ];

  /// The fixed values (what the removed controls now always are).
  static const int overspeedTolerancePct = 10;

  /// Keys this round never writes or deletes (consent, privacy and the rider's real choices). Tests
  /// check [plan] stays away from them.
  static const List<String> neverTouched = [
    'coroute_voice_warnings',
    'coroute_battery_saver_v1',
    'coroute_low_data',
    'coroute_ride_lock_screen',
    'siren_alerts_v1',
    'coroute_speed_warning_kmh',
    'hardware_ptt_v1',
    'intel_settings_v1',
    'push_news_enabled',
    'push_kind_partner_perks',
  ];

  /// Step 3 for the keys stored now ([stored]: key -> value): what to write and what to delete.
  /// Writes only "on" (true) and deletes only retired choice keys; never anything consent-based.
  static ({Map<String, bool> writes, List<String> deletes}) plan(Map<String, Object?> stored) {
    final writes = <String, bool>{
      for (final k in alwaysOnKeys)
        if (stored[k] != true) k: true,
    };
    final deletes = [for (final k in retiredKeys) if (stored.containsKey(k)) k];
    return (writes: writes, deletes: deletes);
  }
}
