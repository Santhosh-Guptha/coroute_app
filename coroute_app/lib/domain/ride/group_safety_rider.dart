/// One rider of the group as the 3.55 group safety checks see it (pure, no Flutter).
///
/// Built from the rider records the phone already has (positions the gateway relays); only
/// [fatigueLevel] is new, and it is a level 0..3, never sensor data.
class GroupSafetyRider {
  final String userId;
  final String name;
  final double lat;
  final double lng;
  final double speedKmh;

  /// Last update from this rider (epoch ms).
  final int lastSeenMs;

  /// A stop reason the rider gave ('' when none): FUELING, PHOTO_STOP...
  final String statusReason;

  /// 0 fresh .. 3 very tired (0 from older apps).
  final int fatigueLevel;

  const GroupSafetyRider({
    required this.userId,
    this.name = '',
    required this.lat,
    required this.lng,
    this.speedKmh = 0,
    required this.lastSeenMs,
    this.statusReason = '',
    this.fatigueLevel = 0,
  });

  /// Positions older than this are not "fresh" (same 2 min the gateway uses).
  static const int freshMs = 120000;

  bool get hasPosition => lat.isFinite && lng.isFinite && !(lat == 0 && lng == 0);

  bool isFresh(int nowMs) => hasPosition && lastSeenMs > 0 && nowMs - lastSeenMs <= freshMs;

  String get firstName {
    final f = name.trim().split(RegExp(r'\s+')).first;
    return f.isEmpty ? 'your buddy' : f;
  }
}
