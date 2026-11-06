import 'package:flutter/foundation.dart';

/// Runtime configuration.
///
/// Nothing secret lives here. The only value is the public address of the
/// CoRoute gateway, which can be overridden at build time:
///
///   flutter build apk --release --dart-define=COROUTE_API=https://api.your-domain.com
///
/// All database credentials, admin accounts and signing keys stay on the
/// server / in the database and never ship inside the app.
///
/// Release builds talk to the gateway over HTTPS / WSS only: a `COROUTE_API` that is not an
/// `https://` URL with a host is ignored there and the production address is used instead
/// (debug and profile builds may use a plain-HTTP LAN gateway).
class AppConfig {
  AppConfig._();

  /// The production gateway (HTTPS).
  static const String defaultApiBaseUrl = 'https://coroute.duckdns.org';

  static const String _configuredApi = String.fromEnvironment(
    'COROUTE_API',
    defaultValue: defaultApiBaseUrl,
  );

  /// The gateway address in use (resolved once; see [resolveApiBase]).
  static final String apiBaseUrl = resolveApiBase(_configuredApi, release: kReleaseMode);

  /// [raw] without a trailing slash, or [defaultApiBaseUrl] when it is empty, or (with
  /// [release]) when it is not an `https://` URL with a host. Nothing of the refused value is
  /// logged (it may carry credentials or an internal address).
  @visibleForTesting
  static String resolveApiBase(String raw, {required bool release}) {
    final v = _trim(raw.trim());
    if (v.isEmpty) return defaultApiBaseUrl;
    if (!release) return v;
    final uri = Uri.tryParse(v);
    final ok = uri != null && uri.scheme == 'https' && uri.host.isNotEmpty && uri.userInfo.isEmpty;
    if (!ok) {
      debugPrint('COROUTE_API ignored: release builds require an https:// gateway. Using the default.');
      return defaultApiBaseUrl;
    }
    return v;
  }

  /// REST prefix, e.g. https://host/api
  static String get apiUrl => '${_trim(apiBaseUrl)}/api';

  /// WebSocket endpoint, e.g. wss://host/ws (always wss:// in release builds).
  static String get wsUrl => wsUrlFor(apiBaseUrl);

  /// The WebSocket endpoint for the gateway [base].
  @visibleForTesting
  static String wsUrlFor(String base) {
    final b = _trim(base);
    if (b.startsWith('https://')) return 'wss://${b.substring(8)}/ws';
    if (b.startsWith('http://')) return 'ws://${b.substring(7)}/ws';
    return 'wss://$b/ws';
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
  /// The same in data saver mode (fewer radio wake-ups and less data; GPS settings unchanged).
  static const Duration telemetryMinIntervalLowData = Duration(seconds: 5);

  /// Telemetry interval for the rider's data setting.
  static Duration telemetryInterval(bool lowData) => lowData ? telemetryMinIntervalLowData : telemetryMinInterval;
  /// While stationary we still send a heartbeat so mates see "last seen".
  static const Duration telemetryIdleInterval = Duration(seconds: 30);
  /// GPS distance filter in metres while moving / while stopped.
  static const int gpsDistanceFilterMoving = 8;
  static const int gpsDistanceFilterIdle = 25;

  // --- Intercom audio ---
  static const int audioSampleRate = 16000;
  /// Data saver: 8 kHz PCM16 is half the data of 16 kHz and still clear for speech.
  static const int audioSampleRateLowData = 8000;

  /// Transmit sample rate for the rider's data setting.
  static int sampleRateFor(bool lowData) => lowData ? audioSampleRateLowData : audioSampleRate;

  /// Bytes of one 20 ms PCM16 mono frame at [sampleRate] (640 at 16 kHz, 320 at 8 kHz).
  static int frameBytesFor(int sampleRate) => sampleRate * 2 * 20 ~/ 1000;
  /// 20 ms of PCM16 mono at 16 kHz = 640 bytes per frame.
  static const int audioFrameBytes = 640;
}
