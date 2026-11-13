// Round 9 (docs/quality/ROUND9_SETTINGS_NOTES.md): how the rider's own overspeed warning is spoken (pure Dart).
//
// Root cause it fixes: the spoken line used the dedupe key 'overspeed_<wall-clock minute>' with the
// voice's 10-minute dedupe window and never said the limit. After a warning, a limit changed in the
// same minute (Settings, or the lead's group limit) produced a warning the voice dropped as a
// duplicate, and the 25 s reminder of the same minute was dropped too, so the change sounded ignored.
//
// Now the key names the limit and the warning's own second ([key]), the window is short
// ([dedupeWindow]: only a double submit of the same warning is dropped; OverspeedGate already spaces
// the reminders 25 s apart) and the line says the limit ([text]).
class OverspeedVoice {
  OverspeedVoice._();

  /// Only a repeat of the same warning within this time is dropped.
  static const Duration dedupeWindow = Duration(seconds: 5);

  /// Far over the limit by this fraction or more, the line is critical (alarm stream, music paused).
  static const double farOverFraction = 0.40;

  static bool farOver({required int currentSpeedKmh, required int limitKmh}) =>
      limitKmh > 0 && currentSpeedKmh >= limitKmh * (1 + farOverFraction);

  /// "overspeed_l60_1731500123" (or "overspeed_far_l60_..."): a new limit is always a new key. The
  /// trailing second keeps CallAlertQueue.kindOf grouping every overspeed line of one limit as one kind.
  static String key({required int limitKmh, required int nowMs, bool far = false}) =>
      '${far ? 'overspeed_far' : 'overspeed'}_l${limitKmh}_${nowMs ~/ 1000}';

  /// The spoken line; always names the limit so a changed limit is heard.
  static String text({required int currentSpeedKmh, required int limitKmh}) {
    if (farOver(currentSpeedKmh: currentSpeedKmh, limitKmh: limitKmh)) return 'Slow down. $currentSpeedKmh km/h, limit $limitKmh.';
    return limitKmh > 0 ? 'Over limit. $currentSpeedKmh km/h, limit $limitKmh.' : 'Over limit. $currentSpeedKmh km/h.';
  }
}
