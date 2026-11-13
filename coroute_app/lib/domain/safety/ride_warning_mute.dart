// Round 9 (docs/quality/ROUND9_SETTINGS_NOTES.md): "Mute this ride" for the low-priority road warnings
// whose Settings switches were removed (pure Dart).
//
// Rough road, twisty road and long ride / night nudges are always on now. A rider who used to switch one
// off can quiet it for the current ride from its card in the ride screen; the next ride starts with
// every warning on again. Hazard, bend, speed limit, SOS, crash and the 2 h break reminder can never be
// muted here.
enum MutableWarning { roughRoad, twisty, nudges }

class RideWarningMute {
  final Set<MutableWarning> _muted = <MutableWarning>{};

  static const String actionLabel = 'Mute this ride';

  /// The kind of a road care card or voice key ('INTEL:ROUGH:abc', 'intel_TWISTY:120', 'INTEL:NUDGE:group:1'),
  /// or null when it can never be muted.
  static MutableWarning? kindOf(String key) {
    var k = key.trim().toUpperCase();
    if (k.startsWith('INTEL:')) {
      k = k.substring(6);
    } else if (k.startsWith('INTEL_')) {
      k = k.substring(6);
    } else {
      return null; // only the round 4 road warnings are mutable
    }
    if (k.startsWith('ROUGH:')) return MutableWarning.roughRoad;
    if (k.startsWith('TWISTY:')) return MutableWarning.twisty;
    if (k.startsWith('NUDGE:')) return MutableWarning.nudges;
    return null;
  }

  /// True when the card or voice line [key] is muted for this ride.
  bool blocks(String key) {
    final kind = kindOf(key);
    return kind != null && _muted.contains(kind);
  }

  /// Mutes the kind of [key] for this ride. False when that kind can never be muted.
  bool muteKindOf(String key) {
    final kind = kindOf(key);
    if (kind == null) return false;
    _muted.add(kind);
    return true;
  }

  bool isMuted(MutableWarning kind) => _muted.contains(kind);

  /// A new ride (or the end of one): everything is on again.
  void reset() => _muted.clear();
}
