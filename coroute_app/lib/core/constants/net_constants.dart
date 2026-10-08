/// Link, outbox and presence settings for the realtime connection (3.14).
///
/// Kept here (not in the code that uses them) so they can be tuned in one place.
class NetConstants {
  NetConstants._();

  /// Most items the persistent outbox keeps; beyond this the oldest chat goes first.
  static const int outboxMaxItems = 100;

  /// Anything older than this is dropped at send time (the ride has moved on).
  static const Duration outboxMaxAge = Duration(hours: 6);

  /// A WAIT request older than this is no longer useful and is dropped at send time.
  static const Duration outboxWaitMaxAge = Duration(minutes: 3);

  /// At most this many outbox items are sent per second after a reconnect.
  static const int outboxSendPerSecond = 4;

  /// A refused item ("Not sent") stays visible this long, then it is dropped.
  static const Duration outboxFailedShowFor = Duration(minutes: 1);

  /// How often the "still alive during a ride" time is written to disk (with telemetry, no timer).
  static const Duration aliveStampEvery = Duration(seconds: 60);

  /// Consecutive connect failures where the server answered wrongly before the
  /// app says "CoRoute server not reachable" instead of "Offline".
  static const int serverUnreachableAfter = 2;

  /// Roster changes (riders joining, leaving, opting out) are fetched at most this often.
  static const Duration rosterRefreshDebounce = Duration(seconds: 30);

  /// SharedPreferences key of the persistent outbox.
  static const String keyOutbox = 'coroute_outbox_v1';

  /// True while a ride is active and the app has not closed cleanly.
  static const String keyRideAlive = 'coroute_ride_alive';

  /// Last time (epoch ms) the app was seen alive during a ride.
  static const String keyLastAliveAt = 'coroute_last_alive_at';

  /// Secure storage key of the emergency SMS roster (encrypted; never in SharedPreferences).
  static const String keyRoster = 'coroute_sms_roster_v1';
}
