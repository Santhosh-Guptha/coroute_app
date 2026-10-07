class AppConstants {
  static const String appName = 'CoRoute';
  static const String appTagline = 'Ride Together. Stay Safe.';

  // DevMonks.space branding
  static const String brandName = 'devmonks.space';
  static const String brandUrl = 'https://devmonks.space';
  static const String brandTagline = 'Engineered by devmonks.space';

  // Roles are assigned by the server (stored in the database), never decided in the app.
  static const String adminRole = 'MASTER_ADMIN';
  static const String riderRole = 'RIDER';

  // Input limits for profile fields (the gateway enforces the same rules).
  static const int maxCallsignLength = 40;
  static const int maxEmailLength = 120;
  static const int maxPhoneInputLength = 20; // 7 to 16 digits, plus +, spaces or dashes
  static const int maxVehicleNoLength = 16;
  static const int maxContactNameLength = 40;

  // Local cache keys (non-sensitive profile mirror; the JWT lives in secure storage)
  static const String keyUserId = 'coroute_user_id';
  static const String keyUserRole = 'coroute_user_role';
  static const String keyUserEmail = 'coroute_user_email';
  static const String keyUserName = 'coroute_user_name';
  static const String keyVehicleType = 'coroute_vehicle_type';
  static const String keyPhone = 'coroute_phone';
  static const String keyVehicleNo = 'coroute_vehicle_no';
  static const String keyEmergencyContact = 'coroute_emergency_contact';
  static const String keyEmergencyName = 'coroute_emergency_name';
  static const String keyActiveGroupId = 'coroute_active_group_id';
  static const String keyTripHistory = 'coroute_trip_history_v3';
  /// An SOS the convoy has not confirmed yet (sent again after reconnecting).
  static const String keyPendingSos = 'coroute_pending_sos';
  /// Data saver mode (intercom at 8 kHz, positions every 5 s, fewer map tiles).
  static const String keyLowData = 'coroute_low_data';
  /// Pre-ride checklist: "do not show again until" (epoch ms).
  static const String keyChecklistSkipUntil = 'coroute_checklist_skip_until';
  static const Duration checklistSkipFor = Duration(hours: 24);
  /// Below this battery level the pre-ride checklist suggests charging first.
  static const int lowBatteryPercent = 30;

  // Tile source URLs (OpenStreetMap: free, no API keys)
  static const String osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  /// Choices for the group speed limit in km/h (0 = no limit).
  static const List<int> speedLimitChoices = [0, 40, 60, 80, 100, 120];

  // Where a map opens when there is nothing to show yet: the centre of India.
  static const double defaultMapLat = 20.5937;
  static const double defaultMapLng = 78.9629;

  static const String osmUserAgent = 'CoRouteFlutter/3.0 (devmonks.space; space.devmonks.coroute_app)';
}
