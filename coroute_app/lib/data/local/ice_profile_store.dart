import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ice_profile.dart';

/// Offline local store for rider ICE (In Case of Emergency) medical profile.
class IceProfileStore {
  IceProfileStore._();

  static const String _iceKey = 'coroute_offline_ice_profile_v1';

  /// Saves the ICE medical profile to local offline storage.
  static Future<bool> save(IceProfile profile) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = jsonEncode(profile.toJson());
      return await prefs.setString(_iceKey, jsonStr);
    } catch (e) {
      debugPrint('IceProfileStore save failed: $e');
      return false;
    }
  }

  /// Loads the ICE medical profile from local offline storage.
  static Future<IceProfile> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_iceKey);
      if (raw == null || raw.isEmpty) {
        return _fallbackDefaultProfile(prefs);
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final profile = IceProfile.fromJson(decoded);
        if (!profile.isEmpty) return profile;
      }
      return _fallbackDefaultProfile(prefs);
    } catch (e) {
      debugPrint('IceProfileStore load failed: $e');
      return IceProfile.empty;
    }
  }

  /// Extracts any partial emergency information from settings/profile preferences as fallback.
  static IceProfile _fallbackDefaultProfile(SharedPreferences prefs) {
    final contactName = prefs.getString('emergency_contact_name') ?? '';
    final contactPhone = prefs.getString('emergency_contact') ?? prefs.getString('emergency_phone') ?? '';
    final blood = prefs.getString('ice_blood_group') ?? '';

    if (contactPhone.isNotEmpty || blood.isNotEmpty) {
      return IceProfile(
        bloodGroup: blood,
        emergencyContactName: contactName,
        emergencyContactPhone: contactPhone,
      );
    }
    return IceProfile.empty;
  }
}
