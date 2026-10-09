/// The big ride notification (home and lock screen) and spoken alerts (3.15).
///
/// The ride notification replaces the foreground service notification of
/// flutter_foreground_task in place: same notification id, same channel.
/// Both values are set by this app when it starts the service
/// (BackgroundService: `serviceId` and `AndroidNotificationOptions.channelId`);
/// the plugin posts its notification with exactly these.
class NotifConstants {
  NotifConstants._();

  /// The ride notification is redrawn at most this often (an emergency change redraws at once).
  static const Duration minInterval = Duration(seconds: 10);

  /// Notification id of the foreground service (`FlutterForegroundTask.startService(serviceId:)`).
  static const int serviceNotificationId = 1001;

  /// Channel of the foreground service notification (`AndroidNotificationOptions.channelId`).
  static const String channelId = 'coroute_convoy';

  /// Riders listed ahead and behind (each side, nearest first).
  static const int ladderPerSide = 2;

  /// The rich notification is given up for the rest of the ride after this many failures in a row.
  static const int maxFailures = 3;

  /// After the service (re)starts, the rich notification is checked once more after this delay
  /// (the plugin may post its own notification a moment after `startService` returns).
  static const Duration restartRecheck = Duration(seconds: 3);

  /// A rider with no update for this long is flagged "No signal".
  static const Duration noSignalAfter = Duration(minutes: 2);

  /// A rider stopped for at least this long is flagged "Stopped N min".
  static const Duration stoppedFlagAfter = Duration(minutes: 1);

  /// Two riders closer than this along the route count as level (side unknown).
  static const double sameSpotM = 30;

  /// Without a route, my heading decides ahead or behind only at this speed or more.
  static const double headingMinKmh = 10;

  // ------------------------------------------------------------------ voice
  /// The same spoken alert (same key) is not repeated within this time.
  static const Duration voiceDedupe = Duration(minutes: 10);

  /// Never more than this many spoken alerts waiting (warnings beyond it are dropped).
  static const int voiceMaxQueued = 2;

  /// Longest text sent to the speech engine.
  static const int voiceMaxChars = 300;

  // --------------------------------------------------------- platform channels
  static const String ttsChannel = 'coroute/tts';
  static const String notifChannel = 'coroute/ride_notification';

  // ---------------------------------------------------- notification actions
  static const String actionSos = 'SOS';
  static const String actionWait = 'WAIT';
  static const String actionMap = 'MAP';
  static const String actionNavEmergency = 'NAV_EMERGENCY';
  static const String actionAssistAccept = 'ASSIST_ACCEPT';

  // ------------------------------------------------------------------ texts
  /// Lock screen (public version) when ride details are hidden.
  static const String publicTitle = 'CoRoute ride active';

  /// Lock screen (public version) during an emergency: no names, no places.
  static const String publicEmergencyText = 'Rider emergency nearby, open CoRoute';

  /// Lock screen title when the rider chose to show their medical ID during their own SOS (3.16).
  static const String appTitle = 'CoRoute';
}
