/// Automatic offline maps (owner decision, Nov 11; docs/SETTINGS_MINIMAL_v3.55.md).
///
/// The route corridor is saved on the phone at ride start (as before: Wi-Fi / data saver rules in
/// SafetyService, the cockpit's background preparation). After the trip ends the saved map is kept
/// for [OfflineMapRetention.keepAfterTrip] and then deleted. A map saved for a trip that never
/// started goes after [OfflineMapRetention.keepUnridden]. On top, all saved trip maps together stay
/// under [OfflineMapRetention.maxBytes]: the least recently used go first. The map of the trip that
/// is being ridden is never deleted. Pure: no clock, no storage, no Flutter.
library;

/// One saved trip map, as the retention rules see it.
class RetainedMap {
  /// Unique id (the pack id; `trip_<groupId>` for automatic trip maps).
  final String id;

  /// When the map was saved (epoch ms).
  final int createdAtMs;

  /// When its trip ended (epoch ms), or null while the trip has not ended (or never started).
  final int? completedAtMs;

  /// Last time it was saved again or used (epoch ms); [createdAtMs] when unknown.
  final int lastUsedAtMs;

  /// Approximate size on disk.
  final int bytes;

  const RetainedMap({
    required this.id,
    required this.createdAtMs,
    this.completedAtMs,
    int? lastUsedAtMs,
    this.bytes = 0,
  }) : lastUsedAtMs = lastUsedAtMs ?? createdAtMs;
}

/// Why a map is deleted (for logs and tests).
enum RetentionReason { tripEnded, neverRidden, overBudget }

class OfflineMapRetention {
  OfflineMapRetention._();

  /// How long a trip's map stays after the trip ends.
  static const Duration keepAfterTrip = Duration(days: 7);

  /// How long a map saved for a trip that never ended stays (a planned trip that was dropped).
  static const Duration keepUnridden = Duration(days: 30);

  /// All saved trip maps together stay under this (least recently used deleted first).
  static const int maxBytes = 300 * 1024 * 1024;

  /// True when [m] is past its time at [nowMs] (ignores the size cap).
  static bool expired(
    RetainedMap m, {
    required int nowMs,
    Duration keepAfterTrip = OfflineMapRetention.keepAfterTrip,
    Duration keepUnridden = OfflineMapRetention.keepUnridden,
  }) {
    final done = m.completedAtMs;
    if (done != null) return nowMs - done > keepAfterTrip.inMilliseconds;
    return nowMs - m.createdAtMs > keepUnridden.inMilliseconds;
  }

  /// The maps to delete now, with the reason. Maps in [activeIds] (the trip being ridden) are
  /// never deleted, even when that leaves the total over [maxBytes].
  static Map<String, RetentionReason> decide(
    List<RetainedMap> maps, {
    required int nowMs,
    Set<String> activeIds = const {},
    Duration keepAfterTrip = OfflineMapRetention.keepAfterTrip,
    Duration keepUnridden = OfflineMapRetention.keepUnridden,
    int maxBytes = OfflineMapRetention.maxBytes,
  }) {
    final out = <String, RetentionReason>{};
    final kept = <RetainedMap>[];
    for (final m in maps) {
      if (activeIds.contains(m.id)) {
        kept.add(m);
      } else if (expired(m, nowMs: nowMs, keepAfterTrip: keepAfterTrip, keepUnridden: keepUnridden)) {
        out[m.id] = m.completedAtMs != null ? RetentionReason.tripEnded : RetentionReason.neverRidden;
      } else {
        kept.add(m);
      }
    }
    var total = kept.fold<int>(0, (sum, m) => sum + m.bytes);
    if (total <= maxBytes) return out;
    // Least recently used first; among equals, ended trips before trips still to ride.
    final candidates = kept.where((m) => !activeIds.contains(m.id)).toList()
      ..sort((a, b) {
        final c = a.lastUsedAtMs.compareTo(b.lastUsedAtMs);
        if (c != 0) return c;
        return (a.completedAtMs == null ? 1 : 0).compareTo(b.completedAtMs == null ? 1 : 0);
      });
    for (final m in candidates) {
      if (total <= maxBytes) break;
      out[m.id] = RetentionReason.overBudget;
      total -= m.bytes;
    }
    return out;
  }
}
