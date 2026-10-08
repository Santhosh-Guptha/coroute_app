/// Rider Safety Network and Rider Discovery Network (3.15): app side settings.
///
/// Kept here (not in the code that uses them) so they can be tuned in one place.
class NetworkConstants {
  NetworkConstants._();

  /// Capabilities this app announces in every JOIN (only to a gateway that supports `net1`).
  static const List<String> clientCaps = ['net1'];

  /// "Another nearby rider is responding" stays visible this long.
  static const Duration assistTakenShowFor = Duration(minutes: 2);

  /// "Royal Riders waved" stays on the ride screen this long (the UI reads it).
  static const Duration waveShowFor = Duration(seconds: 5);

  /// "Royal Riders waved" stays in the notification shade this long.
  static const Duration waveNotifyFor = Duration(minutes: 1);

  /// An encounter with no update for this long is dropped (the END was missed).
  static const Duration encounterStaleAfter = Duration(minutes: 15);

  /// A hazard with no update for this long is dropped (the CLEAR was missed).
  static const Duration hazardStaleAfter = Duration(hours: 3);

  /// A WAVE still waiting for signal after this long is no longer sent.
  static const Duration waveMaxAge = Duration(minutes: 2);

  /// Back online: a request or warning I had stays (navigation to an emergency goes on) until
  /// the server sends it again; one not sent again within this time was closed meanwhile.
  static const Duration resendGrace = Duration(seconds: 30);

  // ------------------------------------------------------------ settings keys
  static const String keyVoiceCritical = 'coroute_voice_critical';
  static const String keyVoiceWarnings = 'coroute_voice_warnings';
  static const String keyHazardAlerts = 'coroute_hazard_alerts';
  static const String keyRideOnLockScreen = 'coroute_ride_lock_screen';
  static const String keyRichNotification = 'coroute_rich_notification';
  static const String keyNetConsentSeen = 'coroute_net_consent_seen';
  static const String keyNetConsentPrompts = 'coroute_net_consent_prompts';

  /// The nearby riders consent sheet is offered at most this many times ("Later").
  static const int netConsentMaxPrompts = 3;

  // ------------------------------------------------------- notification channels
  /// Accident warnings on my route (high importance, amber in the app).
  static const String channelHazard = 'coroute_hazard';

  /// Other riding groups nearby (low importance, silent).
  static const String channelSocial = 'coroute_social';
}
