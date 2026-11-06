import 'status_text.dart';

/// The words and buttons of the ongoing ride notification (pure; see
/// `test/ride_notification_content_test.dart`).
///
///  * Title: `Riding with <group>` or `Solo ride`.
///  * Body: speed • distance • next stop / ETA, e.g.
///    "42 km/h • 12 km • Kolar fuel stop, ETA 4:35 PM".
///  * Buttons: SOS (big, red, always), Talk (group rides whose plan allows the
///    intercom), End ride (solo) / Leave (group).
///
/// Numbers are rounded (speed to the km/h, distance like the rest of the app)
/// so the text does not change with every GPS fix; the notification service
/// pushes it at most once per [RideNotificationThrottle] window anyway.
class RideNotificationContent {
  final String title;
  final String body;
  final bool showTalk;

  /// "End ride" (solo) or "Leave" (group).
  final String endLabel;

  const RideNotificationContent({required this.title, required this.body, required this.showTalk, required this.endLabel});

  static const String soloTitle = 'Solo ride';
  static const String endSolo = 'End ride';
  static const String endGroup = 'Leave';
  static const String talkLabel = 'Talk';
  static const String sosLabel = 'SOS';

  /// Below this the speed reads "Stopped" (GPS jitter while parked).
  static const double stoppedBelowKmh = 3.0;

  /// [speedKmh] null = no position yet. [distanceM] = what is left to [targetName]
  /// (next planned stop, else the destination); null = unknown. [etaClock] is the
  /// arrival time already formatted ("4:35 PM"). [talkAllowed] null = no plan
  /// information: Talk is shown for group rides (the plan gate decides when known).
  static RideNotificationContent build({
    required String groupName,
    required bool solo,
    double? speedKmh,
    double? distanceM,
    String? targetName,
    String? etaClock,
    bool? talkAllowed,
  }) {
    final name = groupName.trim();
    final title = solo || name.isEmpty ? soloTitle : 'Riding with ${_short(name, 32)}';
    final parts = <String>[
      speedText(speedKmh),
      if (distanceM != null && distanceM.isFinite && distanceM >= 0) StatusText.roundedDistance(distanceM),
      ?_target(targetName, etaClock),
    ].where((p) => p.isNotEmpty).toList();
    return RideNotificationContent(
      title: title,
      body: parts.join(' • '),
      showTalk: !solo && (talkAllowed ?? true),
      endLabel: solo ? endSolo : endGroup,
    );
  }

  /// "42 km/h", "Stopped", or '' without a position.
  static String speedText(double? speedKmh) {
    if (speedKmh == null || !speedKmh.isFinite) return '';
    if (speedKmh < stoppedBelowKmh) return 'Stopped';
    return '${speedKmh.round()} km/h';
  }

  static String? _target(String? name, String? eta) {
    final n = name == null ? '' : _short(name.split(',').first.trim(), 24);
    final e = eta == null || eta.trim().isEmpty ? '' : 'ETA ${eta.trim()}';
    if (n.isEmpty && e.isEmpty) return null;
    if (n.isEmpty) return e;
    if (e.isEmpty) return n;
    return '$n, $e';
  }

  static String _short(String s, int max) => s.length > max ? '${s.substring(0, max - 1)}.' : s;
}

/// At most one ride notification update per window (not per GPS fix).
///
/// Normal: 10 s; battery saver: 20 s; an emergency change (SOS, crash, assist,
/// hazard) is pushed at once. Identical content is never pushed again.
class RideNotificationThrottle {
  RideNotificationThrottle({this.normal = const Duration(seconds: 10), this.saver = const Duration(seconds: 20), this.minimum = const Duration(seconds: 5)});

  final Duration normal;
  final Duration saver;

  /// Even urgent pushes are this far apart unless the emergency state itself changed.
  final Duration minimum;

  int _lastPushMs = -1 << 40;
  String? _lastKey;

  int get lastPushMs => _lastPushMs;

  /// When the next routine push may happen.
  int nextAllowedMs({required bool saverOn}) => _lastPushMs + (saverOn ? saver : normal).inMilliseconds;

  /// True when [key] should be pushed now. [emergencyChanged]: the mode or emergency
  /// state changed since the last push (always pushed). [critical]: an emergency is
  /// open (refresh at the [minimum] window instead of the normal one).
  bool shouldPush({
    required int nowMs,
    required String key,
    bool emergencyChanged = false,
    bool critical = false,
    bool saverOn = false,
  }) {
    if (key == _lastKey && !emergencyChanged) return false;
    if (emergencyChanged) return true;
    final window = critical ? minimum : (saverOn ? saver : normal);
    return nowMs - _lastPushMs >= window.inMilliseconds;
  }

  void pushed({required int nowMs, required String key}) {
    _lastPushMs = nowMs;
    _lastKey = key;
  }

  void reset() {
    _lastPushMs = -1 << 40;
    _lastKey = null;
  }
}
