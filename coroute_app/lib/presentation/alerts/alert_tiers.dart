import '../../core/ui/ride_alert.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/timeline_event_model.dart';
import '../../domain/notify/alert_policy.dart';

/// How urgent an alert from [AlertPolicy] is in the app.
///
/// Built on the same specs as the notifications, so the app and the
/// notification shade never disagree:
/// * `SOS:*` (crash too), `OFFLINE:*`, `NO_SIGNAL:*`, `SEPARATED:*` and a possible incident
///   about another rider (`INCIDENT:*`) are critical;
/// * `STOPPED:*`, `OFF_ROUTE:*`, `CLOSED:*`, `NO_REPLY:*`, my own possible incident, the meeting
///   point and the `alerts` channel (over the speed limit) are important;
/// * the `updates` and `activity` channels are normal (SOS responses).
AlertTier tierFor(AlertSpec spec) {
  final k = spec.key;
  if (k.startsWith(AlertPolicy.incidentPrefix)) return spec.aboutMe ? AlertTier.important : AlertTier.critical;
  if (k.startsWith(AlertPolicy.sosPrefix) || k.startsWith('OFFLINE:') || k.startsWith(AlertPolicy.noSignalPrefix) || k.startsWith('SEPARATED:')) {
    return AlertTier.critical;
  }
  if (k.startsWith(AlertPolicy.closedPrefix) || k.startsWith(AlertPolicy.noReplyPrefix)) return AlertTier.important;
  if (k.startsWith('STOPPED:') || k.startsWith('OFF_ROUTE:') || k == AlertPolicy.meetingKey) return AlertTier.important;
  return switch (spec.channel) {
    AlertChannel.sos => AlertTier.critical,
    AlertChannel.alerts => AlertTier.important,
    AlertChannel.updates => AlertTier.normal,
    AlertChannel.activity => AlertTier.normal,
  };
}

/// Who is looking at the alerts, with the same rule as the notification service:
/// the creator or a LEAD is the lead, a SWEEPER is the sweeper.
AlertViewer? alertViewerFor(ConvoyModel? convoy, String? userId) {
  if (convoy == null || userId == null || userId.isEmpty) return null;
  final me = convoy.riders[userId];
  final role = me?.role ?? 'PACK';
  return AlertViewer(
    userId: userId,
    isLead: convoy.createdByUserId == userId || role == 'LEAD',
    isSweeper: role == 'SWEEPER',
    lat: me?.lat,
    lng: me?.lng,
  );
}

/// One alert as the app shows it: the notification spec, its tier and the
/// timeline entry it came from (for "Show on map" and "Call").
class InAppAlert {
  final AlertSpec spec;
  final AlertTier tier;
  final TimelineEventModel? event;

  /// True while the cause lasts (an open SOS, a long stop); false for a one-time event.
  final bool standing;

  const InAppAlert({required this.spec, required this.tier, this.event, this.standing = true});

  String get key => spec.key;
  String? get userId => event?.userId;
  int get at => event?.startedAt ?? 0;
}

/// Alerts for the Alerts tab and the ride alert slot: what should be visible
/// now (standing) plus one-time events from the last [recent], newest first.
///
/// Each situation appears once (keyed like the notification), so nothing is
/// shown twice. Sorted critical first, then important, then normal; within a
/// tier the newest first. Pure: no timers, safe to call from build.
List<InAppAlert> inAppAlerts(
  Iterable<TimelineEventModel> events,
  AlertViewer viewer, {
  required int nowMs,
  AlertPolicy? policy,
  Duration recent = const Duration(minutes: 15),
  int maxRecent = 10,
}) {
  final p = policy ?? AlertPolicy();
  final byKey = <String, InAppAlert>{};
  final oneShots = <InAppAlert>[];
  for (final e in events) {
    if (e.open) {
      for (final spec in p.standing([e], viewer, nowMs: nowMs)) {
        byKey[spec.key] = InAppAlert(spec: spec, tier: tierFor(spec), event: e);
      }
    }
    final age = nowMs - e.startedAt;
    if (age < 0 || age > recent.inMilliseconds) continue;
    final spec = p.oneShot(e, viewer);
    if (spec == null) continue;
    oneShots.add(InAppAlert(spec: spec, tier: tierFor(spec), event: e, standing: false));
  }
  oneShots.sort((a, b) => b.at.compareTo(a.at));
  // One row per key: a newer one-time alert with the same key (a new meeting point) replaces the older.
  final seen = <String>{...byKey.keys};
  final out = <InAppAlert>[
    ...byKey.values,
    ...oneShots.where((a) => seen.add(a.key)).take(maxRecent),
  ];
  out.sort((a, b) {
    final t = a.tier.index.compareTo(b.tier.index);
    return t != 0 ? t : b.at.compareTo(a.at);
  });
  return out;
}

/// The number on the Alerts tab: critical and important alerts only.
int alertBadgeCount(List<InAppAlert> alerts, {int local = 0}) =>
    local + alerts.where((a) => a.tier != AlertTier.normal).length;
