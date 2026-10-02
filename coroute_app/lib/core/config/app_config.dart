/// Runtime configuration.
///
/// Nothing secret lives here. The only value is the public address of the
/// CoRoute gateway, which can be overridden at build time:
///
///   flutter build apk --release --dart-define=COROUTE_API=https://api.your-domain.com
///
/// All database credentials, admin accounts and signing keys stay on the
/// server / in the database and never ship inside the app.
class AppConfig {
  AppConfig._();

  static const String apiBaseUrl = String.fromEnvironment(
    'COROUTE_API',
    defaultValue: 'https://api.coroute.devmonks.space',
  );

  /// REST prefix, e.g. https://host/api
  static String get apiUrl => '${_trim(apiBaseUrl)}/api';

  /// WebSocket endpoint, e.g. wss://host/ws
  static String get wsUrl {
    final base = _trim(apiBaseUrl);
    if (base.startsWith('https://')) return 'wss://${base.substring(8)}/ws';
    if (base.startsWith('http://')) return 'ws://${base.substring(7)}/ws';
    return 'wss://$base/ws';
  }

  /// Google OAuth *web* client ID (public identifier, not a secret). Required on
  /// Android for Google Sign-In to return an ID token that the gateway verifies.
  static const String googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
    defaultValue: '87798956679-ivggpbpote5cf2cvi8mtg8gja3r1sfve.apps.googleusercontent.com',
  );

  static String _trim(String s) => s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  // --- Battery-aware telemetry tuning (client side) ---
  /// Minimum interval between two telemetry pushes while moving.
  static const Duration telemetryMinInterval = Duration(milliseconds: 2500);
  /// While stationary we still send a heartbeat so mates see "last seen".
  static const Duration telemetryIdleInterval = Duration(seconds: 30);
  /// GPS distance filter in metres while moving / while stopped.
  static const int gpsDistanceFilterMoving = 8;
  static const int gpsDistanceFilterIdle = 25;

  // --- Intercom audio ---
  static const int audioSampleRate = 16000;
  /// 20 ms of PCM16 mono at 16 kHz = 640 bytes per frame.
  static const int audioFrameBytes = 640;
}
