import 'dart:convert';
import '../../domain/safety/fuel_profile.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/network_constants.dart';
import '../../core/constants/safety_constants.dart';
import '../../core/l10n/l10n.dart';

/// Rider settings kept on the phone: data saver ("low data") mode and the ride
/// safety switches.
///
/// Data saver halves the intercom data (8 kHz instead of 16 kHz), sends the
/// position every 5 seconds instead of every 2.5, loads fewer map tiles and
/// downloads a past trip's route only when asked. GPS settings do not change.
///
/// Ride safety: crash detection (on by default), emergency texts when there is
/// no internet (off until the rider opts in and allows SMS), the break reminder
/// and the "Are you OK?" check-in (both on), and whether the brand battery
/// guide was seen.
///
/// 3.16: language (safety screens and spoken alerts), tank range for the fuel
/// reminder, "speak more after dark", medical ID on the lock screen during an SOS,
/// the helmet and documents reminder, and saving route maps on Wi-Fi.
class SettingsService extends ChangeNotifier {
  SettingsService([this._prefs]);

  SharedPreferences? _prefs;
  bool _lowData = false;
  bool _crashDetection = true;
  bool _smsFallback = false;
  bool _fatigueReminder = true;
  bool _soloCheckIn = true;
  bool _oemGuideSeen = false;
  bool _loaded = false;

  // 3.15: voice, accident warnings, ride notification, nearby riders consent.
  bool _voiceCritical = true;
  bool _voiceWarnings = true;
  bool _hazardAlerts = true;
  bool _rideOnLockScreen = true;
  bool _richNotification = true;
  bool _netConsentSeen = false;
  int _netConsentPrompts = 0;

  // 3.16.
  AppLanguage _language = AppLanguage.system;
  int _fuelRangeKm = 0;
  FuelProfile? _fuelProfile;
  bool _shareFuelEstimate = false;
  bool get shareFuelEstimate => _shareFuelEstimate;
  Future<void> setShareFuelEstimate(bool value) async {
    final prefs = await _p();
    if (!await prefs.setBool('share_fuel_estimate_v1', value)) throw StateError('Could not save sharing preference');
    _shareFuelEstimate = value;
    notifyListeners();
  }
  FuelProfile get fuelProfile => _fuelProfile ?? FuelProfile(fullRangeKm: _fuelRangeKm.toDouble());
  Future<void> setFuelProfile(FuelProfile profile) async {
    if (!profile.valid) throw ArgumentError('Invalid fuel profile');
    final prefs = await _p();
    if (!await prefs.setString('fuel_profile_v1', jsonEncode(profile.toJson()))) throw StateError('Fuel settings could not be saved');
    _fuelProfile = profile;
    notifyListeners();
  }
  bool _speakMoreAfterDark = true;
  bool _medicalIdOnLockScreen = false;
  bool _documentsReminder = true;
  bool _saveRouteMaps = true;

  bool get lowData => _lowData;
  bool get crashDetection => _crashDetection;
  bool get smsFallback => _smsFallback;
  bool get fatigueReminder => _fatigueReminder;
  bool get soloCheckIn => _soloCheckIn;
  bool get oemGuideSeen => _oemGuideSeen;
  bool get isLoaded => _loaded;

  /// Speak emergency alerts (on by default).
  bool get voiceCritical => _voiceCritical;

  /// Speak warnings and directions (on by default; also needs the group's voice switch).
  bool get voiceWarnings => _voiceWarnings;

  /// Accident warnings on my route (on by default).
  bool get hazardAlerts => _hazardAlerts;

  /// Show the ride on the lock screen (on by default).
  bool get rideOnLockScreen => _rideOnLockScreen;

  /// Large ride notification (on by default; off = the plain one-line notification).
  bool get richNotification => _richNotification;

  /// The nearby riders consent sheet was answered with Continue.
  bool get netConsentSeen => _netConsentSeen;

  /// How many times the consent sheet was put off with Later.
  int get netConsentPrompts => _netConsentPrompts;

  /// Language of the safety screens and spoken alerts (system by default).
  AppLanguage get language => _language;

  /// Tank range in km for the fuel reminder; 0 = off.
  int get fuelRangeKm => _fuelRangeKm;

  /// After sunset, important group alerts are spoken too (on by default).
  bool get speakMoreAfterDark => _speakMoreAfterDark;

  /// Blood group, allergies and emergency contact on the lock screen during my own SOS (off by default).
  bool get medicalIdOnLockScreen => _medicalIdOnLockScreen;

  /// "Helmet on, licence and documents with you?" line in the pre-ride checklist (on by default).
  bool get documentsReminder => _documentsReminder;

  /// Save map tiles along the planned route on Wi-Fi before the ride (on by default).
  bool get saveRouteMaps => _saveRouteMaps;

  Future<SharedPreferences> _p() async => _prefs ??= await SharedPreferences.getInstance();

  /// Reads the saved settings. Safe to call more than once.
  Future<void> load() async {
    try {
      final prefs = await _p();
      _lowData = prefs.getBool(AppConstants.keyLowData) ?? false;
      _crashDetection = prefs.getBool(SafetyConstants.keyCrashDetection) ?? true;
      _smsFallback = prefs.getBool(SafetyConstants.keySmsFallback) ?? false;
      _fatigueReminder = prefs.getBool(SafetyConstants.keyFatigueReminder) ?? true;
      _soloCheckIn = prefs.getBool(SafetyConstants.keySoloCheckIn) ?? true;
      _oemGuideSeen = prefs.getBool(SafetyConstants.keyOemGuideSeen) ?? false;
      _voiceCritical = prefs.getBool(NetworkConstants.keyVoiceCritical) ?? true;
      _voiceWarnings = prefs.getBool(NetworkConstants.keyVoiceWarnings) ?? true;
      _hazardAlerts = prefs.getBool(NetworkConstants.keyHazardAlerts) ?? true;
      _rideOnLockScreen = prefs.getBool(NetworkConstants.keyRideOnLockScreen) ?? true;
      _richNotification = prefs.getBool(NetworkConstants.keyRichNotification) ?? true;
      _netConsentSeen = prefs.getBool(NetworkConstants.keyNetConsentSeen) ?? false;
      _netConsentPrompts = prefs.getInt(NetworkConstants.keyNetConsentPrompts) ?? 0;
      _language = AppLanguage.fromCode(prefs.getString(NetworkConstants.keyLanguage));
      _shareFuelEstimate = prefs.getBool('share_fuel_estimate_v1') ?? false;
      _fuelRangeKm = _clampRange(prefs.getInt(NetworkConstants.keyFuelRangeKm) ?? 0);
      try {
        final raw = prefs.getString('fuel_profile_v1');
        final j = raw == null ? null : jsonDecode(raw);
        final p = j is Map ? FuelProfile.fromJson(j) : null;
        _fuelProfile = p?.valid == true ? p : null;
      } catch (_) { _fuelProfile = null; }
      _speakMoreAfterDark = prefs.getBool(NetworkConstants.keySpeakAfterDark) ?? true;
      _medicalIdOnLockScreen = prefs.getBool(NetworkConstants.keyMedicalIdLock) ?? false;
      _documentsReminder = prefs.getBool(NetworkConstants.keyDocsReminder) ?? true;
      _saveRouteMaps = prefs.getBool(NetworkConstants.keySaveRouteMaps) ?? true;
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

  Future<void> setCrashDetection(bool value) async {
    if (value == _crashDetection) return;
    _crashDetection = value;
    notifyListeners();
    await _save(SafetyConstants.keyCrashDetection, value);
  }

  /// Emergency texts. The caller asks for the SMS permission before switching on.
  Future<void> setSmsFallback(bool value) async {
    if (value == _smsFallback) return;
    _smsFallback = value;
    notifyListeners();
    await _save(SafetyConstants.keySmsFallback, value);
  }

  Future<void> setFatigueReminder(bool value) async {
    if (value == _fatigueReminder) return;
    _fatigueReminder = value;
    notifyListeners();
    await _save(SafetyConstants.keyFatigueReminder, value);
  }

  Future<void> setSoloCheckIn(bool value) async {
    if (value == _soloCheckIn) return;
    _soloCheckIn = value;
    notifyListeners();
    await _save(SafetyConstants.keySoloCheckIn, value);
  }

  Future<void> setVoiceCritical(bool value) async {
    if (value == _voiceCritical) return;
    _voiceCritical = value;
    notifyListeners();
    await _save(NetworkConstants.keyVoiceCritical, value);
  }

  Future<void> setVoiceWarnings(bool value) async {
    if (value == _voiceWarnings) return;
    _voiceWarnings = value;
    notifyListeners();
    await _save(NetworkConstants.keyVoiceWarnings, value);
  }

  Future<void> setHazardAlerts(bool value) async {
    if (value == _hazardAlerts) return;
    _hazardAlerts = value;
    notifyListeners();
    await _save(NetworkConstants.keyHazardAlerts, value);
  }

  Future<void> setRideOnLockScreen(bool value) async {
    if (value == _rideOnLockScreen) return;
    _rideOnLockScreen = value;
    notifyListeners();
    await _save(NetworkConstants.keyRideOnLockScreen, value);
  }

  Future<void> setRichNotification(bool value) async {
    if (value == _richNotification) return;
    _richNotification = value;
    notifyListeners();
    await _save(NetworkConstants.keyRichNotification, value);
  }

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
    final v = _clampRange(km);
    if (v == _fuelRangeKm) return;
    _fuelRangeKm = v;
    notifyListeners();
    try {
      final prefs = await _p();
      await prefs.setInt(NetworkConstants.keyFuelRangeKm, v);
    } catch (e) {
      debugPrint('settings save note: $e');
    }
  }

  Future<void> setSpeakMoreAfterDark(bool value) async {
    if (value == _speakMoreAfterDark) return;
    _speakMoreAfterDark = value;
    notifyListeners();
    await _save(NetworkConstants.keySpeakAfterDark, value);
  }

  Future<void> setMedicalIdOnLockScreen(bool value) async {
    if (value == _medicalIdOnLockScreen) return;
    _medicalIdOnLockScreen = value;
    notifyListeners();
    await _save(NetworkConstants.keyMedicalIdLock, value);
  }

  Future<void> setDocumentsReminder(bool value) async {
    if (value == _documentsReminder) return;
    _documentsReminder = value;
    notifyListeners();
    await _save(NetworkConstants.keyDocsReminder, value);
  }

  Future<void> setSaveRouteMaps(bool value) async {
    if (value == _saveRouteMaps) return;
    _saveRouteMaps = value;
    notifyListeners();
    await _save(NetworkConstants.keySaveRouteMaps, value);
  }

  Future<void> markOemGuideSeen() async {
    if (_oemGuideSeen) return;
    _oemGuideSeen = true;
    notifyListeners();
    await _save(SafetyConstants.keyOemGuideSeen, true);
  }
}
