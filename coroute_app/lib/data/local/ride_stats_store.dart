import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/safety_constants.dart';
import '../../domain/safety/ride_safety_summary.dart';

/// Rider-only numbers for one trip (3.16: hard stops; ride analytics: rest
/// breaks, safety alerts, SOS and crash alerts). Kept on the phone only, never
/// uploaded and never part of the trip history.
class RideStats {
  final String groupId;
  final int hardStops;
  final int endedAt;

  /// Rest breaks of 10 min or more after riding (fatigue tracker), and "Taking a break" answers.
  final int breaks;

  /// Safety prompts shown during the ride (check-in, fatigue, fuel, speed, follow-up).
  final int alerts;

  /// An SOS was open during the ride / a crash alert counted down.
  final bool sos;
  final bool crashAlert;

  /// 3.55 ride safety report (key 'sf'): night km, over-limit minutes, fatigue peak, "Bike down?"
  /// checks, road hazards felt. Null for rides saved before 3.55. On the phone only.
  final RideSafetySummary? safety;

  const RideStats({
    required this.groupId,
    required this.hardStops,
    required this.endedAt,
    this.breaks = 0,
    this.alerts = 0,
    this.sos = false,
    this.crashAlert = false,
    this.safety,
  });

  bool get hadEmergency => sos || crashAlert;

  Map<String, Object?> toJson() => {
        'h': hardStops,
        'e': endedAt,
        if (breaks > 0) 'b': breaks,
        if (alerts > 0) 'a': alerts,
        if (sos) 's': 1,
        if (crashAlert) 'c': 1,
        if (safety != null && !safety!.isEmpty) 'sf': safety!.toJson(),
      };

  static RideStats? fromJson(String groupId, Object? j) {
    if (j is! Map) return null;
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return RideStats(
      groupId: groupId,
      hardStops: n('h'),
      endedAt: n('e'),
      breaks: n('b'),
      alerts: n('a'),
      sos: n('s') > 0,
      crashAlert: n('c') > 0,
      safety: RideSafetySummary.fromJson(j['sf']),
    );
  }
}

/// SharedPreferences map groupId -> stats, at most [SafetyConstants.rideStatsMax]
/// entries (the oldest go first). Every call is safe and never throws.
class RideStatsStore {
  RideStatsStore._();

  static Future<RideStats?> load(String groupId) async {
    final all = await _all();
    return RideStats.fromJson(groupId, all[groupId]);
  }

  /// Every ride this phone keeps numbers for (the last 90 days, at most [SafetyConstants.rideStatsMax]).
  static Future<List<RideStats>> loadAll() async {
    final all = await _all();
    return [
      for (final e in all.entries) ?RideStats.fromJson(e.key, e.value),
    ];
  }

  static Future<void> save(RideStats s) async {
    final all = await _all();
    all[s.groupId] = s.toJson();
    _trim(all);
    await _write(all);
  }

  /// Drops entries older than [keepDays] (by [RideStats.endedAt]).
  static Future<void> prune({int keepDays = 90, int? nowMs}) async {
    final all = await _all();
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final before = all.length;
    all.removeWhere((_, v) {
      final e = v is Map ? (v['e'] as num?)?.toInt() ?? 0 : 0;
      return e > 0 && now - e > keepDays * 86400000;
    });
    if (all.length != before) await _write(all);
  }

  static void _trim(Map<String, Object?> all) {
    while (all.length > SafetyConstants.rideStatsMax) {
      String? oldest;
      var oldestAt = 1 << 60;
      all.forEach((k, v) {
        final e = v is Map ? (v['e'] as num?)?.toInt() ?? 0 : 0;
        if (e < oldestAt) {
          oldestAt = e;
          oldest = k;
        }
      });
      if (oldest == null) break;
      all.remove(oldest);
    }
  }

  static Future<Map<String, Object?>> _all() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(SafetyConstants.keyRideStats);
      if (raw == null || raw.isEmpty) return {};
      final j = jsonDecode(raw);
      if (j is! Map) return {};
      return j.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return {};
    }
  }

  static Future<void> _write(Map<String, Object?> all) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SafetyConstants.keyRideStats, jsonEncode(all));
    } catch (e) {
      debugPrint('ride stats note: ${e.runtimeType}');
    }
  }
}
