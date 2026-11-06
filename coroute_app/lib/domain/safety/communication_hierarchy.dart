
/// Location Freshness Status indicator: Live vs Stale.
/// Strict invariant: Stale telemetry must NEVER be represented as Live.
enum LocationFreshnessStatus {
  live('LIVE', 'Live'),
  stale('STALE', 'Stale');

  final String wire;
  final String label;

  const LocationFreshnessStatus(this.wire, this.label);

  bool get isLive => this == LocationFreshnessStatus.live;
  bool get isStale => this == LocationFreshnessStatus.stale;

  static LocationFreshnessStatus fromWire(String? wire) {
    if (wire?.toUpperCase() == 'LIVE') return LocationFreshnessStatus.live;
    return LocationFreshnessStatus.stale;
  }
}

