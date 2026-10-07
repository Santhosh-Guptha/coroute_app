import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';

/// Rider settings kept on the phone. Today: data saver ("low data") mode.
///
/// Data saver halves the intercom data (8 kHz instead of 16 kHz), sends the
/// position every 5 seconds instead of every 2.5, loads fewer map tiles and
/// downloads a past trip's route only when asked. GPS settings do not change.
class SettingsService extends ChangeNotifier {
  SettingsService([this._prefs]);

  SharedPreferences? _prefs;
  bool _lowData = false;
  bool _loaded = false;

  bool get lowData => _lowData;
  bool get isLoaded => _loaded;

  Future<SharedPreferences> _p() async => _prefs ??= await SharedPreferences.getInstance();

  /// Reads the saved settings. Safe to call more than once.
  Future<void> load() async {
    try {
      final prefs = await _p();
      _lowData = prefs.getBool(AppConstants.keyLowData) ?? false;
    } catch (e) {
      debugPrint('settings load note: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setLowData(bool value) async {
    if (value == _lowData) return;
    _lowData = value;
    notifyListeners();
    try {
      final prefs = await _p();
      await prefs.setBool(AppConstants.keyLowData, value);
    } catch (e) {
      debugPrint('settings save note: $e');
    }
  }
}
