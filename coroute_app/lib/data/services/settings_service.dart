import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/safety_constants.dart';

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

  bool get lowData => _lowData;
  bool get crashDetection => _crashDetection;
  bool get smsFallback => _smsFallback;
  bool get fatigueReminder => _fatigueReminder;
  bool get soloCheckIn => _soloCheckIn;
  bool get oemGuideSeen => _oemGuideSeen;
  bool get isLoaded => _loaded;

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
    } catch (e) {
      debugPrint('settings load note: $e');
    }
    _loaded = true;
    notifyListeners();
  }

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

  Future<void> markOemGuideSeen() async {
    if (_oemGuideSeen) return;
    _oemGuideSeen = true;
    notifyListeners();
    await _save(SafetyConstants.keyOemGuideSeen, true);
  }
}
