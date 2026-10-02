class AppConstants {
  static const String appName = 'CoRoute';
  static const String appTagline = 'Ride Together. Stay Safe.';
  static const String appVersion = '2.0.0 (Build 50)';
  
  // DevMonks.space branding
  static const String brandName = 'devmonks.space';
  static const String brandUrl = 'https://devmonks.space';
  static const String brandTagline = 'Engineered by devmonks.space';
  
  // Master Admin (Any login with santhoshbukka5@gmail.com gets MASTER_ADMIN role)
  static const String masterAdminEmail = 'santhoshbukka5@gmail.com';
  static const String adminRole = 'MASTER_ADMIN';
  static const String riderRole = 'RIDER';
  
  // Storage keys
  static const String keyUserRole = 'coroute_user_role';
  static const String keyUserEmail = 'coroute_user_email';
  static const String keyUserName = 'coroute_user_name';
  static const String keyVehicleType = 'coroute_vehicle_type';
  static const String keyActiveGroupId = 'coroute_active_group_id';
  static const String keyTripHistory = 'coroute_trip_history_v2';
  
  // Tile source URLs (100% Free OpenStreetMap Mapnik with zero watermarks & zero API keys)
  static const String osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String osmUserAgent = 'CoRouteFlutter/2.0 (devmonks.space; space.devmonks.coroute_app)';
}
