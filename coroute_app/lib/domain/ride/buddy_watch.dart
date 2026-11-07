import '../notify/relation.dart';
import '../tracking/geo_math.dart';
import 'group_safety_rider.dart';

/// Why my buddy needs a look.
enum BuddyTrouble { none, offline, behind, stopped }

/// 3.55 buddy pairs (pure): my phone watches my one buddy. "Check on Kiran" when, for [holdFor]:
///  * no update from them for [offlineAfter] (offline), or
///  * they are more than [behindM] behind me along the route (or as the crow flies without a
///    route, while I am moving), or
///  * they are stopped (slower than [stoppedKmh]) more than [apartM] from me while I keep moving,
///    and gave no stop reason.
/// "They're fine" snoozes for [snoozeFor]; the card clears when the trouble ends.
class BuddyWatch {
  BuddyWatch({
    this.holdFor = const Duration(minutes: 2),
    this.offlineAfter = const Duration(minutes: 2),
    this.behindM = 1000,
    this.apartM = 300,
    this.stoppedKmh = 5,
    this.movingKmh = 15,
    this.snoozeFor = const Duration(minutes: 10),
  });

  final Duration holdFor;
  final Duration offlineAfter;
  final double behindM;
  final double apartM;
  final double stoppedKmh;
  final double movingKmh;
  final Duration snoozeFor;

  String? _buddyId;
  int? _since;
  int? _snoozedUntil;
  bool _showing = false;
  BuddyTrouble _trouble = BuddyTrouble.none;

  bool get showing => _showing;
  BuddyTrouble get trouble => _trouble;

  /// What is wrong right now (no hold time).
  BuddyTrouble troubleOf({required int nowMs, required GroupSafetyRider me, required GroupSafetyRider buddy, List<(double, double)> route = const []}) {
    if (buddy.lastSeenMs <= 0 || nowMs - buddy.lastSeenMs >= offlineAfter.inMilliseconds) return BuddyTrouble.offline;
    if (!me.hasPosition || !buddy.hasPosition) return BuddyTrouble.none;
    final delta = Relation.alongDelta(myLat: me.lat, myLng: me.lng, lat: buddy.lat, lng: buddy.lng, route: route);
    final iMove = me.speedKmh >= movingKmh;
    if (delta != null) {
      if (delta < -behindM) return BuddyTrouble.behind;
    } else if (iMove && GeoMath.haversine(me.lat, me.lng, buddy.lat, buddy.lng) > behindM) {
      return BuddyTrouble.behind;
    }
    if (iMove && buddy.speedKmh < stoppedKmh && buddy.statusReason.isEmpty &&
        GeoMath.haversine(me.lat, me.lng, buddy.lat, buddy.lng) > apartM) {
      return BuddyTrouble.stopped;
    }
    return BuddyTrouble.none;
  }

  /// True when the "Check on (name)" card should appear now (once per trouble spell).
  bool update({
    required int nowMs,
    required GroupSafetyRider me,
    required GroupSafetyRider? buddy,
    List<(double, double)> route = const [],
    bool emergencyOpen = false,
  }) {
    if (buddy == null) {
      reset();
      return false;
    }
    if (buddy.userId != _buddyId) {
      reset();
      _buddyId = buddy.userId;
    }
    _trouble = troubleOf(nowMs: nowMs, me: me, buddy: buddy, route: route);
    if (_trouble == BuddyTrouble.none) {
      _since = null;
      _showing = false;
      return false;
    }
    _since ??= nowMs;
    if (_showing || emergencyOpen) return false;
    if (_snoozedUntil != null && nowMs < _snoozedUntil!) return false;
    if (nowMs - _since! < holdFor.inMilliseconds) return false;
    _showing = true;
    return true;
  }

  /// "They're fine" (or the buddy answered "I'm OK"): hidden for [snoozeFor].
  void snooze(int nowMs) {
    _showing = false;
    _snoozedUntil = nowMs + snoozeFor.inMilliseconds;
  }

  void reset() {
    _buddyId = null;
    _since = null;
    _snoozedUntil = null;
    _showing = false;
    _trouble = BuddyTrouble.none;
  }

  static String title(String firstName) => 'Check on $firstName';

  static String message(BuddyTrouble t, String firstName) => switch (t) {
        BuddyTrouble.offline => 'No update from $firstName for 2 minutes.',
        BuddyTrouble.behind => '$firstName is more than 1 km behind.',
        BuddyTrouble.stopped => '$firstName has stopped and the group is moving.',
        BuddyTrouble.none => '',
      };
}
