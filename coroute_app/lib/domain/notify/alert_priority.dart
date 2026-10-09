import 'alert_policy.dart';

/// What wins the rider's attention, highest first (product rule 3.15):
/// 1 SOS / confirmed accident, 2 nearby assistance request, 3 accident hazard
/// warning, 4 own-group separation and safety alerts, 5 route information,
/// 6 public group discovery. Social is never shown over an active emergency.
/// 3.16: a rider's updates stopped, low battery and behind the sweeper (`STALE:`,
/// `BATTERY:`, `BEHIND:`) and the fuel and follow-up prompts are group safety (4).
enum AlertPriority { sos, assistRequest, hazard, groupSafety, routeInfo, social }

/// Priority of an alert from its key (and channel when the key does not say).
AlertPriority priorityForKey(String key, {AlertChannel? channel}) {
  if (key.startsWith(AlertPolicy.sosPrefix)) return AlertPriority.sos;
  // "Another nearby rider is responding" is information, not a request.
  if (key.startsWith(AlertPolicy.assistTakenPrefix)) return AlertPriority.routeInfo;
  if (key.startsWith(AlertPolicy.assistPrefix)) return AlertPriority.assistRequest;
  if (key.startsWith(AlertPolicy.hazardPrefix)) return AlertPriority.hazard;
  if (key.startsWith(AlertPolicy.encounterPrefix)) return AlertPriority.social;
  if (key.startsWith(AlertPolicy.incidentPrefix) ||
      key.startsWith(AlertPolicy.noSignalPrefix) ||
      key.startsWith(AlertPolicy.closedPrefix) ||
      key.startsWith(AlertPolicy.noReplyPrefix) ||
      key.startsWith('OFFLINE:') ||
      key.startsWith('SEPARATED:') ||
      key.startsWith('STOPPED:') ||
      key.startsWith(AlertPolicy.stalePrefix) ||
      key.startsWith(AlertPolicy.batteryPrefix) ||
      key.startsWith(AlertPolicy.behindPrefix) ||
      key == AlertPolicy.localCheckInKey ||
      key == AlertPolicy.localFatigueKey ||
      key == AlertPolicy.fuelKey ||
      key == AlertPolicy.followUpKey) {
    return AlertPriority.groupSafety;
  }
  if (key.startsWith('OFF_ROUTE:') || key == AlertPolicy.meetingKey) return AlertPriority.routeInfo;
  return switch (channel) {
    AlertChannel.sos => AlertPriority.sos,
    AlertChannel.hazard => AlertPriority.hazard,
    AlertChannel.alerts => AlertPriority.groupSafety,
    AlertChannel.social => AlertPriority.social,
    AlertChannel.updates || AlertChannel.activity || null => AlertPriority.routeInfo,
  };
}

/// Orders alerts by priority and decides whether social items may show.
class AlertArbiter {
  AlertArbiter._();

  /// Stable sort: priority first (SOS first), then newest first when [newest] is given.
  static List<T> arrange<T>(Iterable<T> items, AlertPriority Function(T) of, {int Function(T)? newest}) {
    final list = items.toList();
    final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
    indexed.sort((a, b) {
      final p = of(a.$2).index.compareTo(of(b.$2).index);
      if (p != 0) return p;
      if (newest != null) {
        final n = newest(b.$2).compareTo(newest(a.$2));
        if (n != 0) return n;
      }
      return a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  /// Social (discovery) is shown only when nothing safety related is active.
  static bool socialAllowed({required bool anyEmergency, required bool anyAssist, required bool anyHazard}) =>
      !anyEmergency && !anyAssist && !anyHazard;
}
