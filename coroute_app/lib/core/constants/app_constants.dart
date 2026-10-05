class AppConstants {
  static const String appName = 'CoRoute';
  static const String appTagline = 'Ride Together. Stay Safe.';

  // DevMonks.space branding
  static const String brandName = 'devmonks.space';
  static const String brandUrl = 'https://devmonks.space';
  static const String brandTagline = 'Engineered by devmonks.space';

  // Roles are assigned by the server (stored in the database) — never decided in the app.
  static const String adminRole = 'MASTER_ADMIN';
  static const String riderRole = 'RIDER';

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

  // Tile source URLs (OpenStreetMap — free, no API keys)
  static const String osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  // Where a map opens when there is nothing to show yet: the centre of India.
  static const double defaultMapLat = 20.5937;
  static const double defaultMapLng = 78.9629;

  static const String osmUserAgent = 'CoRouteFlutter/3.0 (devmonks.space; space.devmonks.coroute_app)';
}
