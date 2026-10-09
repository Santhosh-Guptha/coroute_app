import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/safety_constants.dart';

/// Rider-only numbers for one trip (3.16: hard stops). Kept on the phone
/// only, never uploaded and never part of the trip history.
class RideStats {
  final String groupId;
  final int hardStops;
  final int endedAt;

  const RideStats({required this.groupId, required this.hardStops, required this.endedAt});

  Map<String, Object?> toJson() => {'h': hardStops, 'e': endedAt};

  static RideStats? fromJson(String groupId, Object? j) {
    if (j is! Map) return null;
    return RideStats(groupId: groupId, hardStops: (j['h'] as num?)?.toInt() ?? 0, endedAt: (j['e'] as num?)?.toInt() ?? 0);
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
