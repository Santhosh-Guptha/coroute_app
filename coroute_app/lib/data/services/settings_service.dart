import 'dart:convert';
import '../../domain/safety/fuel_profile.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/network_constants.dart';
import '../../core/constants/safety_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../domain/audio/voice_clarity.dart';
import '../../domain/tracking/screen_awake_policy.dart';
import '../../domain/safety/settings_round9.dart';
import 'rider_score_service.dart';

/// Rider settings kept on the phone: only the choices a rider really makes.
/// Everything else is decided by the app (emergency voice, after-dark voice,
/// the rich ride notification, saving route maps on Wi-Fi, the helmet and
/// documents line, tunnel mode and how long a map alert stays are always on).
/// The one Settings screen (SettingsScreen) shows these.
///
/// Data saver halves the intercom data (8 kHz instead of 16 kHz), sends the
/// position every 5 seconds instead of every 2.5, loads fewer map tiles and
/// downloads a past trip's route only when asked. GPS settings do not change.
///
/// Ride safety: crash detection, emergency texts when there is no internet, the
/// break reminder and the "Are you OK?" check-in (all always on since 3.55), and
/// whether the brand battery guide was seen.
///
/// 3.16: language (safety screens and spoken alerts) and the tank range for the
/// fuel reminder. Medical ID is always on the lock screen during an SOS (riders
/// control it by editing their medical info).
///
/// 3.55 minimal settings (docs/SETTINGS_MINIMAL_v3.55.md): the safety features in
/// [alwaysOnKeys] are always on and have no switch. Their getters return true, a stored
/// "off" from an older version is ignored, [load] rewrites them to on once
/// ([keySafetyDefaultsVersion]), and their setters refuse "off".
///
/// Nov 11 (owner decision, migration v2): the give-way side is fixed to Automatic and the rider
/// score always uses the safety report; help / ask nearby riders are always on (server profile,
/// kept on by AuthService). Offline maps are automatic (OfflineMapRetentionService).
///
/// Round 9 (owner request "remove unnecessary setting options, make them on by default", migration v3,
/// docs/quality/ROUND9_SETTINGS_NOTES.md, [SettingsRound9]): bend warnings, the road speed limit sign,
/// the road overspeed warning, lowering music when speeding and wind-noise mode are always on; the
/// overspeed margin is automatic (+10 %, at least 5 km/h); when idle = Ride AOD; keep screen on = only
/// while moving; music is lowered (not paused) for warnings; noise reduction = Strong. Their getters
/// return the fixed value whatever is stored, their setters do nothing, and step 3 rewrites / deletes
/// the old keys once. Voice alerts and battery saver stay the rider's (quick controls in the ride screen).
class SettingsService extends ChangeNotifier {
  SettingsService([this._prefs]);

  SharedPreferences? _prefs;
  bool _lowData = false;
  bool _crashDetection = true;
  bool _smsFallback = true; // always on (3.55)
  bool _fatigueReminder = true;
  bool _soloCheckIn = true;
  // 3.55 solo check-in by ETA and no-signal ahead (on by default; docs/features_355/solo_guardian.md).
  bool _etaCheckIn = true;
  bool _noSignalAhead = true;
  bool _oemGuideSeen = false;
  bool _loaded = false;

  // 3.15: voice, accident warnings, lock screen, nearby riders consent.
  bool _voiceWarnings = true;
  bool _hazardAlerts = true;
  bool _rideOnLockScreen = true;
  bool _netConsentSeen = false;
  int _netConsentPrompts = 0;

  // 3.16.
  AppLanguage _language = AppLanguage.system;
  int _fuelRangeKm = 0;
  FuelProfile? _fuelProfile;
  bool _shareFuelEstimate = false;
  String? _fuelUser;
  bool _fuelScoped = false;
  int _fuelGeneration = 0;
  String _fuelKey(String base) => _fuelScoped ? '$base:user:${_fuelUser ?? "signed-out"}' : base;
  Future<void> selectFuelUser(String? userId) async {
    if (_fuelScoped && _fuelUser == userId) return;
    _fuelScoped = true; _fuelUser = userId;
    final generation = ++_fuelGeneration;
    _shareFuelEstimate = false; _fuelProfile = null; _fuelRangeKm = 0;
    notifyListeners();
    final prefs = await _p();
    if (generation != _fuelGeneration || userId == null) return;
    _shareFuelEstimate = prefs.getBool(_fuelKey('share_fuel_estimate_v1')) ?? false;
    _fuelRangeKm = _clampRange(prefs.getInt(_fuelKey(NetworkConstants.keyFuelRangeKm)) ?? 0);
    try {
      final raw = prefs.getString(_fuelKey('fuel_profile_v1'));
      final decoded = raw == null ? null : jsonDecode(raw);
      final profile = decoded is Map ? FuelProfile.fromJson(decoded) : null;
      _fuelProfile = profile?.valid == true ? profile : null;
    } catch (_) { _fuelProfile = null; }
    notifyListeners();
  }
  bool get shareFuelEstimate => _shareFuelEstimate;
  Future<void> setShareFuelEstimate(bool value) async {
    final generation = _fuelGeneration, key = _fuelKey('share_fuel_estimate_v1');
    final prefs = await _p();
    if (!await prefs.setBool(key, value)) throw StateError('Could not save sharing preference');
    if (generation != _fuelGeneration) return;
    _shareFuelEstimate = value;
    notifyListeners();
  }
  bool get hasFuelProfile => _fuelProfile != null;
  FuelProfile get fuelProfile => _fuelProfile ?? FuelProfile(fullRangeKm: _fuelRangeKm.toDouble());
  Future<void> setFuelProfile(FuelProfile profile) async {
    if (!profile.valid) throw ArgumentError('Invalid fuel profile');
    final generation = _fuelGeneration, key = _fuelKey('fuel_profile_v1');
    final prefs = await _p();
    if (!await prefs.setString(key, jsonEncode(profile.toJson()))) throw StateError('Fuel settings could not be saved');
    // 3.55: the rider's own fuel settings: the garage never replaces them.
    await prefs.remove(_fuelKey(_keyGarageFuel));
    if (generation != _fuelGeneration) return;
    _fuelProfile = profile;
    notifyListeners();
  }

  static const String _keyGarageFuel = 'fuel_profile_from_garage_v1';

  /// 3.55: fills the fuel profile from the active garage bike (tank, reserve, mileage) when the
  /// signed-in rider has set none (no profile and no simple range), or when the one there was
  /// filled from the garage before (a bike change or edit updates it). The rider's own settings
  /// always win. Reads storage directly, so a profile still loading is never overwritten.
  /// True when the profile changed.
  Future<bool> adoptGarageFuelProfile(FuelProfile profile) async {
    if (!profile.valid || !profile.litresMode || !_fuelScoped || _fuelUser == null) return false;
    final generation = _fuelGeneration;
    try {
      final prefs = await _p();
      if (generation != _fuelGeneration) return false;
      final key = _fuelKey('fuel_profile_v1'), markKey = _fuelKey(_keyGarageFuel);
      final stored = prefs.getString(key);
      final mark = prefs.getString(markKey);
      final rangeSet = (prefs.getInt(_fuelKey(NetworkConstants.keyFuelRangeKm)) ?? 0) > 0;
      final fromGarage = stored == null ? !rangeSet : (mark != null && stored == mark);
      final next = jsonEncode(profile.toJson());
      if (!fromGarage || stored == next) return false;
      if (!await prefs.setString(key, next)) return false;
      await prefs.setString(markKey, next);
      if (generation != _fuelGeneration) return true;
      _fuelProfile = profile;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('settings save note: $e');
      return false;
    }
  }
  bool _batterySaver = false;
  bool _hardwarePtt = false;
  int _speedLimitWarningKmh = 0;
  bool _autoReroute = true;

  bool get lowData => _lowData;
  /// Always on (3.55): crash detection.
  bool get crashDetection => _crashDetection;

  /// Always on (3.55): emergency texts when an SOS cannot go online. Without the SMS permission
  /// (the Play build) the texts open in the messages app, ready to send.
  bool get smsFallback => _smsFallback;

  /// Always on (3.55): the break reminder.
  bool get fatigueReminder => _fatigueReminder;

  /// Always on (3.55): the "Are you OK?" check-in when far from the group.
  bool get soloCheckIn => _soloCheckIn;

  /// 3.55: text my emergency contact when a solo ride with a destination is overdue and I do not answer.
  /// Always on (needs an emergency contact; admin switch `soloCheckIn`).
  bool get etaCheckIn => _etaCheckIn;

  /// 3.55: tell my group and guardians before a stretch that had no signal on my earlier rides.
  /// Always on (admin switch `noSignalAhead`).
  bool get noSignalAhead => _noSignalAhead;
  bool get oemGuideSeen => _oemGuideSeen;
  bool get isLoaded => _loaded;

  /// Spoken alerts: warnings, directions and announcements (on by default; also needs
  /// the group's voice switch). Emergency alerts are always spoken.
  bool get voiceWarnings => _voiceWarnings;

  /// Whether other audio (Spotify, music, podcasts) pauses for ordinary warnings instead of being
  /// lowered. Fixed off since round 9 (lowered); critical lines always pause it.
  bool get pauseOtherAudio => false;

  /// Accident warnings on my route (always on, 3.55).
  bool get hazardAlerts => _hazardAlerts;

  /// "Show cockpit on lock screen while riding" (default on; the rider's choice, docs/features_355/lock_screen_cockpit.md).
  /// The stored key is the one of 3.54's "Show ride on lock screen", so a choice made then stays. The ride
  /// notification and its SOS button stay on the lock screen either way (always, since 3.55).
  bool get rideOnLockScreen => _rideOnLockScreen;

  /// When idle: always the Ride AOD since round 9 (battery and heat fall back by themselves, see
  /// ScreenAwakePolicy). A stored Dim / Sleep from an older build is ignored.
  RideIdleMode get rideIdleMode => RideIdleMode.aod;

  /// Keep screen on: always "only while moving" since round 9. A stored "always" is ignored.
  KeepScreenOnMode get keepScreenOnMode => KeepScreenOnMode.whileMoving;

  /// The nearby riders consent sheet was answered with Continue.
  bool get netConsentSeen => _netConsentSeen;

  /// How many times the consent sheet was put off with Later.
  int get netConsentPrompts => _netConsentPrompts;

  /// Language of the safety screens and spoken alerts (system by default).
  AppLanguage get language => _language;

  /// Tank range in km for the fuel reminder; 0 = off.
  int get fuelRangeKm => _fuelRangeKm;

  /// Battery saver switched on by the rider (it also turns itself on at 20 % or less).
  bool get batterySaver => _batterySaver;

  /// Hardware button (volume down / media button on Bluetooth headset or handlebar remote) acts as PTT.
  bool get hardwarePtt => _hardwarePtt;

  /// My own speed warning in km/h (0 = use the group limit, off if none).
  int get speedLimitWarningKmh => _speedLimitWarningKmh;

  /// Round 7: "Sharp bend ahead" voice + chip (advisory). Always on since round 9.
  bool get curveWarnings => true;

  /// Round 7: the road's speed limit sign in the cockpit (from the map, or estimated "~"). Always on since round 9.
  bool get roadLimitDisplay => true;

  /// Round 7: warn when over the road's limit (voice once, then the sign only). Always on since round 9.
  bool get roadOverspeedWarning => true;

  /// Round 7: how far over the limit before the warning: automatic since round 9 (+10 %, never less
  /// than 5 km/h; no margin near schools and hospitals). A stored 5 / 15 / 20 is ignored.
  int get roadOverspeedTolerancePct => SettingsRound9.overspeedTolerancePct;

  static const String keyCurveWarnings = SettingsRound9.keyCurveWarnings;
  static const String keyRoadLimitDisplay = SettingsRound9.keyRoadLimitDisplay;
  static const String keyRoadOverspeedWarning = SettingsRound9.keyRoadOverspeedWarning;
  static const String keyRoadOverspeedTolerancePct = SettingsRound9.keyRoadOverspeedTolerancePct;

  /// Kept for callers (round 9): always on, nothing is stored.
  Future<void> setCurveWarnings(bool value) async {}

  /// Kept for callers (round 9): always on, nothing is stored.
  Future<void> setRoadLimitDisplay(bool value) async {}

  /// Kept for callers (round 9): always on, nothing is stored.
  Future<void> setRoadOverspeedWarning(bool value) async {}

  /// Kept for callers (round 9): the margin is automatic, nothing is stored.
  Future<void> setRoadOverspeedTolerancePct(int pct) async {}

  /// Auto re-route: a new route from where I am when I leave the planned one (always on, 3.55).
  bool get autoReroute => _autoReroute;

  Future<SharedPreferences> _p() async => _prefs ??= await SharedPreferences.getInstance();

  /// Reads the saved settings. Safe to call more than once.
  Future<void> load() async {
    try {
      final prefs = await _p();
      _lowData = prefs.getBool(AppConstants.keyLowData) ?? false;
      // 3.55: always-on safety settings ignore a stored "off" (see [alwaysOnKeys]).
      _crashDetection = true;
      _smsFallback = true;
      _fatigueReminder = true;
      _soloCheckIn = true;
      _etaCheckIn = true;
      _noSignalAhead = true;
      _oemGuideSeen = prefs.getBool(SafetyConstants.keyOemGuideSeen) ?? false;
      _voiceWarnings = prefs.getBool(NetworkConstants.keyVoiceWarnings) ?? true;
      _hazardAlerts = true;
      _rideOnLockScreen = prefs.getBool(NetworkConstants.keyRideOnLockScreen) ?? true;
      _netConsentSeen = prefs.getBool(NetworkConstants.keyNetConsentSeen) ?? false;
      _netConsentPrompts = prefs.getInt(NetworkConstants.keyNetConsentPrompts) ?? 0;
      _language = AppLanguage.fromCode(prefs.getString(NetworkConstants.keyLanguage));
      if (!_fuelScoped) {
      _shareFuelEstimate = prefs.getBool('share_fuel_estimate_v1') ?? false;
      _fuelRangeKm = _clampRange(prefs.getInt(NetworkConstants.keyFuelRangeKm) ?? 0);
      try {
        final raw = prefs.getString('fuel_profile_v1');
        final j = raw == null ? null : jsonDecode(raw);
        final p = j is Map ? FuelProfile.fromJson(j) : null;
        _fuelProfile = p?.valid == true ? p : null;
      } catch (_) { _fuelProfile = null; }
      }
      _batterySaver = prefs.getBool(keyBatterySaver) ?? false;
      _hardwarePtt = prefs.getBool(keyHardwarePtt) ?? false;
      // Round 9: a corrupt value (wrong type from an old build or a restored backup) never breaks loading.
      final speed = prefs.get(SafetyConstants.keySpeedLimitWarningKmh);
      _speedLimitWarningKmh = speed is int ? speed.clamp(0, SafetyConstants.speedWarningMaxKmh) : 0;
      _autoReroute = true;
      await _migrateSafetyDefaults(prefs);
    } catch (e) {
      debugPrint('settings load note: $e');
    }
    L10n.setLanguage(_language);
    _loaded = true;
    notifyListeners();
  }

  static int _clampRange(int km) => km.clamp(0, NetworkConstants.fuelRangeMaxKm);

  Future<void> _save(String key, bool value) async {
    try {
      final prefs = await _p();
      await prefs.setBool(key, value);
    } catch (e) {
      debugPrint('settings save note: $e');
    }
  }

  Future<void> setLowData(bool value) async {
    if (value == _lowData) return;
    _lowData = value;
    notifyListeners();
    await _save(AppConstants.keyLowData, value);
  }

  /// Always on (3.55): "off" is ignored.
  Future<void> setCrashDetection(bool value) async {
    if (!value || _crashDetection) return;
    _crashDetection = true;
    notifyListeners();
    await _save(SafetyConstants.keyCrashDetection, true);
  }

  /// Emergency texts: always on (3.55), "off" is ignored.
  Future<void> setSmsFallback(bool value) async {
    if (!value || _smsFallback) return;
    _smsFallback = true;
    notifyListeners();
    await _save(SafetyConstants.keySmsFallback, true);
  }

  // ---- 3.55 minimal settings: always-on safety settings and their one-time migration.

  /// Stored keys of the settings that are always on (no switch in the app).
  /// [NetworkConstants.keyRideOnLockScreen] left this list with the lock-screen cockpit: it is the rider's choice
  /// again ("Show cockpit on lock screen while riding", default on) and no migration ever rewrites it, so the value a
  /// rider chose in 3.54 stays (3.55 is not released, so the v1 step never forced it on a rider's phone).
  static const List<String> alwaysOnKeys = [
    SafetyConstants.keyCrashDetection,
    SafetyConstants.keySmsFallback,
    SafetyConstants.keyFatigueReminder,
    SafetyConstants.keySoloCheckIn,
    keyEtaCheckIn,
    keyNoSignalAhead,
    NetworkConstants.keyHazardAlerts,
    keyAutoReroute,
    keyVoiceCleanup,
  ];

  /// Keys the version-1 migration wrote to true. Siren alerts were always on in that round; they
  /// have a switch again (default on), so the value it wrote simply stays on until the rider turns
  /// it off. Nothing is ever forced off.
  static const List<String> safetyDefaultsV1Keys = [...alwaysOnKeys, keySirenAlerts];

  /// Version of the safety defaults written by [load]; bumped when a setting joins the fixed list.
  ///  * 3 (round 9, owner request): [SettingsRound9.plan]: bend warnings, road limit sign, road
  ///    overspeed warning, lower music when speeding and wind-noise mode written back as on; the
  ///    retired choice keys (overspeed margin, when idle, keep screen on, pause music, noise
  ///    reduction) deleted. Nothing consent-based is written.
  ///  * 1: [safetyDefaultsV1Keys] written to true.
  ///  * 2 (owner decision, Nov 11): give-way side fixed to Automatic ([keyGiveWaySide] = 'auto') and
  ///    "Use my safety report in my score" fixed on ([RiderScoreService.prefsUseReport] = true). Help
  ///    nearby riders / Ask nearby riders are always on too; they live on the server profile, so
  ///    AuthService writes them (PATCH /me) when the gateway still reports them off.
  static const String keySafetyDefaultsVersion = 'settings_safety_defaults_version';
  static const int safetyDefaultsVersion = 3;

  /// One time per step of [safetyDefaultsVersion]: only ever turns settings on (or back to their
  /// fixed default). A rider who upgrades several versions at once runs every missing step once.
  Future<void> _migrateSafetyDefaults(SharedPreferences prefs) async {
    final from = prefs.getInt(keySafetyDefaultsVersion) ?? 0;
    if (from >= safetyDefaultsVersion) return;
    if (from < 1) {
      for (final k in safetyDefaultsV1Keys) {
        await prefs.setBool(k, true);
      }
    }
    if (from < 2) {
      await prefs.setString(keyGiveWaySide, 'auto');
      await RiderScoreService.adoptAlwaysOn(prefs);
    }
    if (from < 3) {
      final step = SettingsRound9.plan({for (final k in [...SettingsRound9.alwaysOnKeys, ...SettingsRound9.retiredKeys]) k: prefs.get(k)}
        ..removeWhere((_, v) => v == null));
      for (final e in step.writes.entries) {
        await prefs.setBool(e.key, e.value);
      }
      for (final k in step.deletes) {
        await prefs.remove(k);
      }
    }
    await prefs.setInt(keySafetyDefaultsVersion, safetyDefaultsVersion);
  }

  /// Always on (3.55): "off" is ignored.
  Future<void> setFatigueReminder(bool value) async {
    if (!value || _fatigueReminder) return;
    _fatigueReminder = true;
    notifyListeners();
    await _save(SafetyConstants.keyFatigueReminder, true);
  }

  static const String keyEtaCheckIn = 'eta_check_in_v1';
  static const String keyNoSignalAhead = 'no_signal_ahead_v1';

  /// Always on (3.55): "off" is ignored.
  Future<void> setEtaCheckIn(bool value) async {
    if (!value || _etaCheckIn) return;
    _etaCheckIn = true;
    notifyListeners();
    await _save(keyEtaCheckIn, true);
  }

  /// Always on (3.55): "off" is ignored.
  Future<void> setNoSignalAhead(bool value) async {
    if (!value || _noSignalAhead) return;
    _noSignalAhead = true;
    notifyListeners();
    await _save(keyNoSignalAhead, true);
  }

  /// Always on (3.55): "off" is ignored.
  Future<void> setSoloCheckIn(bool value) async {
    if (!value || _soloCheckIn) return;
    _soloCheckIn = true;
    notifyListeners();
    await _save(SafetyConstants.keySoloCheckIn, true);
  }

  Future<void> setVoiceWarnings(bool value) async {
    if (value == _voiceWarnings) return;
    _voiceWarnings = value;
    notifyListeners();
    await _save(NetworkConstants.keyVoiceWarnings, value);
  }

  /// Kept for callers (round 9): music is always lowered for warnings, nothing is stored.
  Future<void> setPauseOtherAudio(bool value) async {}

  /// Always on (3.55): "off" is ignored.
  Future<void> setHazardAlerts(bool value) async {
    if (!value || _hazardAlerts) return;
    _hazardAlerts = true;
    notifyListeners();
    await _save(NetworkConstants.keyHazardAlerts, true);
  }

  /// "Show cockpit on lock screen while riding". Off turns the over-keyguard window off at once
  /// (LockScreenCockpitService listens). Same key as 3.54, so earlier choices stay.
  Future<void> setRideOnLockScreen(bool value) async {
    if (value == _rideOnLockScreen) return;
    _rideOnLockScreen = value;
    notifyListeners();
    await _save(NetworkConstants.keyRideOnLockScreen, value);
  }

  static const String keyRideIdleMode = SettingsRound9.keyRideIdleMode;
  static const String keyKeepScreenOnMode = SettingsRound9.keyKeepScreenOnMode;

  /// Kept for callers (round 9): always the Ride AOD, nothing is stored.
  Future<void> setRideIdleMode(RideIdleMode value) async {}

  /// Kept for callers (round 9): always "only while moving", nothing is stored.
  Future<void> setKeepScreenOnMode(KeepScreenOnMode value) async {}

  Future<void> markNetConsentSeen() async {
    if (_netConsentSeen) return;
    _netConsentSeen = true;
    notifyListeners();
    await _save(NetworkConstants.keyNetConsentSeen, true);
  }

  /// The consent sheet was put off ("Later"); it is offered at most [NetworkConstants.netConsentMaxPrompts] times.
  Future<void> bumpNetConsentPrompts() async {
    _netConsentPrompts++;
    notifyListeners();
    try {
      final prefs = await _p();
      await prefs.setInt(NetworkConstants.keyNetConsentPrompts, _netConsentPrompts);
    } catch (e) {
      debugPrint('settings save note: $e');
    }
  }

  /// Language of the safety screens and spoken alerts; applied at once through [L10n].
  Future<void> setLanguage(AppLanguage value) async {
    if (value == _language) return;
    _language = value;
    L10n.setLanguage(value);
    notifyListeners();
    try {
      final prefs = await _p();
      await prefs.setString(NetworkConstants.keyLanguage, value.code);
    } catch (e) {
      debugPrint('settings save note: $e');
    }
  }

  /// Tank range in km (0 turns the fuel reminder off; at most [NetworkConstants.fuelRangeMaxKm]).
  Future<void> setFuelRangeKm(int km) async {
    final key = _fuelKey(NetworkConstants.keyFuelRangeKm);
    final v = _clampRange(km);
    if (v == _fuelRangeKm) return;
    _fuelRangeKm = v;
    notifyListeners();
    try {
      final prefs = await _p();
      await prefs.setInt(key, v);
    } catch (e) {
      debugPrint('settings save note: $e');
    }
  }

  static const String keyBatterySaver = 'coroute_battery_saver_v1';
  static const String keyHardwarePtt = 'hardware_ptt_v1';
  static const String keyAutoReroute = 'auto_reroute_v1';

  /// Battery saver on (always) or automatic (on at 20 % or less, see BatterySaverPolicy).
  Future<void> setBatterySaver(bool value) async {
    if (value == _batterySaver) return;
    _batterySaver = value;
    notifyListeners();
    await _save(keyBatterySaver, value);
  }

  /// Synchronizes First Responder ICE card info (Blood group, allergies, conditions, contacts)
  /// to SharedPreferences so native Android MedicalTileService and MedicalIdActivity
  /// can render the ICE Card over the lock screen without requiring device unlock.
  Future<void> syncMedicalIdToLockScreen({
    required String name,
    required String bloodGroup,
    required String allergies,
    required String medicalNotes,
    required String contactName,
    required String contactPhone,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('flutter.medical_user_name', name);
    await p.setString('flutter.medical_blood_group', bloodGroup);
    await p.setString('flutter.medical_allergies', allergies);
    await p.setString('flutter.medical_notes', medicalNotes);
    await p.setString('flutter.medical_contact_name', contactName);
    await p.setString('flutter.medical_contact_phone', contactPhone);
    // Always available (no switch): the tile and the lock-screen card read this.
    await p.setBool('flutter.medical_enabled', true);
  }

  Future<void> markOemGuideSeen() async {
    if (_oemGuideSeen) return;
    _oemGuideSeen = true;
    notifyListeners();
    await _save(SafetyConstants.keyOemGuideSeen, true);
  }

  Future<void> setHardwarePtt(bool value) async {
    if (value == _hardwarePtt) return;
    _hardwarePtt = value;
    notifyListeners();
    await _save(keyHardwarePtt, value);
  }

  Future<void> setSpeedLimitWarningKmh(int kmh) async {
    final v = kmh.clamp(0, SafetyConstants.speedWarningMaxKmh);
    if (v == _speedLimitWarningKmh) return;
    _speedLimitWarningKmh = v;
    notifyListeners();
    try {
      final prefs = await _p();
      await prefs.setInt(SafetyConstants.keySpeedLimitWarningKmh, v);
    } catch (e) {
      debugPrint('settings save speedLimitWarningKmh note: $e');
    }
  }

  /// Always on (3.55): "off" is ignored.
  Future<void> setAutoReroute(bool value) async {
    if (!value || _autoReroute) return;
    _autoReroute = true;
    notifyListeners();
    await _save(keyAutoReroute, true);
  }

  // 3.55 audio (docs/features_355/audio_and_calls.md). Read lazily from the prefs that load() opened,
  // so load() itself is unchanged.
  static const String keyLowerMusicWhenSpeeding = SettingsRound9.keyLowerMusicWhenSpeeding;

  /// "Lower music when speeding": other apps' music is lowered step by step (then paused) while I ride
  /// well over the speed limit, and restored after. Always on since round 9 (the admin switch
  /// `speedAudio` still applies).
  bool get lowerMusicWhenSpeeding => true;

  /// Kept for callers (round 9): always on, nothing is stored.
  Future<void> setLowerMusicWhenSpeeding(bool value) async {}

  // ---- 3.55 sound awareness & intercom voice (docs/features_355/sound_awareness_and_intercom.md).
  // Loaded by [loadSoundSettings] (main.dart calls it after [load]); defaults until then.
  static const String keySirenAlerts = 'siren_alerts_v1';
  /// Removed in 3.55 (horn alerts are gone); the stored value is deleted by [loadSoundSettings].
  static const String legacyKeyHornAlerts = 'horn_alerts_mode_v1';
  static const String keyVoiceCleanup = 'voice_cleanup_v1';
  static const String keyGiveWaySide = 'give_way_side_v1'; // fixed to 'auto' since migration v2
  bool _sirenAlerts = true;
  bool _voiceCleanup = true;

  /// Emergency-vehicle siren alerts from the phone's own microphone during rides (switch in
  /// Settings > Ride, on by default; admin switch `sirenDetector`). Off releases the mic at once.
  /// Full spoken alert when the rider may not hear outside sound (earphones, music), else softer.
  bool get sirenAlerts => _sirenAlerts;

  /// "Clean up my voice" for the intercom (always on, 3.55).
  bool get voiceCleanup => _voiceCleanup;

  /// Side to keep to when giving way: always 'auto' since Nov 11 (owner decision): from the
  /// phone's country (India = left). No row in Settings any more; a stored left / right is ignored.
  String get giveWaySide => 'auto';

  Future<void> loadSoundSettings() async {
    try {
      final prefs = await _p();
      _sirenAlerts = prefs.getBool(keySirenAlerts) ?? true; // rider's choice, default on
      if (prefs.containsKey(legacyKeyHornAlerts)) await prefs.remove(legacyKeyHornAlerts); // horn alerts removed
      _voiceCleanup = true; // always on (3.55)
    } catch (e) {
      debugPrint('settings sound load note: $e');
    }
    notifyListeners();
  }

  /// Rider's choice (default on). Listeners (RideMicHub via the detector) release or open the mic.
  Future<void> setSirenAlerts(bool value) async {
    if (value == _sirenAlerts) return;
    _sirenAlerts = value;
    notifyListeners();
    await _save(keySirenAlerts, value);
  }

  /// Always on (3.55): "off" is ignored.
  Future<void> setVoiceCleanup(bool value) async {
    if (!value || _voiceCleanup) return;
    _voiceCleanup = true;
    notifyListeners();
    await _save(keyVoiceCleanup, true);
  }

  /// Fixed to 'auto' (Nov 11): kept for callers; any side is ignored and nothing is stored.
  Future<void> setGiveWaySide(String value) async {}

  // ---- Round 8 voice clarity (docs/features_355/voice_clarity.md). Round 9: fixed, no choices.
  static const String keyNoiseReduction = SettingsRound9.keyNoiseReduction;
  static const String keyWindNoiseMode = SettingsRound9.keyWindNoiseMode;

  /// "Noise reduction": always Strong since round 9 (a stored Normal / Off is ignored). The voice gate
  /// and level control run as before ("Clean up my voice" stays always on).
  NoiseReduction get noiseReduction => NoiseReduction.strong;

  /// Kept for callers (round 9): always Strong, nothing is stored.
  Future<void> setNoiseReduction(NoiseReduction value) async {}

  /// "Wind-noise mode": automatic since round 9 (always on): wind gusts are ducked fast (10 ms
  /// detector) while nobody speaks.
  bool get windNoiseMode => true;

  /// Kept for callers (round 9): always on, nothing is stored.
  Future<void> setWindNoiseMode(bool value) async {}
}
