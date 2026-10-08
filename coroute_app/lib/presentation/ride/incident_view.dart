import '../../data/models/convoy_model.dart';
import '../../data/models/medical_info.dart';
import '../../data/models/network_models.dart';
import '../../data/models/network_wire.dart';
import '../../data/models/rider_model.dart';
import '../../data/models/safety_wire.dart';
import '../../data/models/timeline_event_model.dart';
import '../../data/services/timeline_service.dart';
import '../../domain/notify/alert_policy.dart';
import '../../domain/timeline/timeline_text.dart';

/// What kind of emergency an [IncidentView] is, most urgent first.
enum IncidentKind {
  /// An SOS raised by a rider (the SOS button or the notification action).
  sos,

  /// An SOS of type CRASH, usually raised automatically by the phone.
  crash,

  /// The server saw a hard stop from speed and no movement after it.
  possibleIncident,

  /// No signal from a rider for a while after riding fast (escalated OFFLINE).
  noSignal,

  /// A rider far from the group did not answer "Are you OK?".
  noReply,
}

/// One open emergency in the ride, the same for the banner, the incident
/// sheet and the Alerts tab. Built by [incidentsFor]; pure data.
class IncidentView {
  final IncidentKind kind;
  final String subjectUserId;
  final String subjectName;

  /// The SOS alert id (sos and crash only).
  final String? alertId;

  /// Where it happened, or the rider's newer position. 0,0 when unknown.
  final double lat;
  final double lng;

  /// When it happened (impact time for a crash), epoch ms.
  final int startedAt;

  /// Raised by the phone or the server without the rider pressing anything.
  final bool auto;

  /// Riders who answered "I'm going" or "I'm with them" (sos and crash only).
  final List<SosResponder> responders;

  /// Only present while the SOS or crash alert is open.
  final MedicalInfo? medical;

  /// The incident is about me (my own SOS, or the group was asked to check on me).
  final bool isMe;

  /// Speed before the hard stop or the impact, when known (km/h).
  final double? fromKmh;

  /// Place name from the timeline ("near Hosur"), may be empty.
  final String placeName;

  /// The SOS reason code (alertType) for sos and crash, empty otherwise.
  final String alertType;

  /// Emergency lifecycle (3.15), null for an older gateway or a non-alert incident.
  final EmergencyStatus? status;

  /// How the emergency was raised (3.15), null when unknown.
  final EmergencySource? source;

  /// Nearby assistance from other groups (3.15), null when the gateway has no safety network.
  final EmergencyNetwork? network;

  /// The nearest member of my group (computed by the server), or null.
  final OwnNearest? ownNearest;

  /// When the position shown was last updated (epoch ms), 0 when unknown.
  final int positionAt;

  /// Who reported it (a member report "Rider down"), empty otherwise.
  final String reportedByName;

  const IncidentView({
    required this.kind,
    required this.subjectUserId,
    required this.subjectName,
    this.alertId,
    required this.lat,
    required this.lng,
    required this.startedAt,
    this.auto = false,
    this.responders = const [],
    this.medical,
    this.isMe = false,
    this.fromKmh,
    this.placeName = '',
    this.alertType = '',
    this.status,
    this.source,
    this.network,
    this.ownNearest,
    this.positionAt = 0,
    this.reportedByName = '',
  });

  /// True for an SOS or a crash alert (the group can answer it).
  bool get isAlert => kind == IncidentKind.sos || kind == IncidentKind.crash;

  bool get hasPosition => lat != 0 || lng != 0;

  /// A crash, a rider reported down, or an automatic or "Need Help" alert after a possible accident.
  bool get isAccident =>
      kind == IncidentKind.crash ||
      alertType == SosTypes.crash ||
      alertType == riderDownType ||
      source == EmergencySource.crashAuto ||
      source == EmergencySource.needHelp ||
      source == EmergencySource.memberReport ||
      source == EmergencySource.nearbyReport;

  /// Alert type of a member report ("Rider down").
  static const String riderDownType = 'RIDER_DOWN';

  /// First word of the name, or "the rider".
  String get firstName {
    final n = subjectName.trim();
    if (n.isEmpty) return 'the rider';
    final i = n.indexOf(' ');
    return i > 0 ? n.substring(0, i) : n;
  }

  /// "Rahul may have met with an accident" / "Rahul needs help" (own group emergency, 3.15 wording).
  String get summary => isAccident ? '$who may have met with an accident' : '$who needs help';

  /// The same key as the notification and the Alerts tab row, so nothing shows twice.
  String get key {
    switch (kind) {
      case IncidentKind.sos:
      case IncidentKind.crash:
        return '${AlertPolicy.sosPrefix}${alertId ?? subjectUserId}';
      case IncidentKind.possibleIncident:
        return '${AlertPolicy.incidentPrefix}$subjectUserId';
      case IncidentKind.noSignal:
        return '${AlertPolicy.noSignalPrefix}$subjectUserId';
      case IncidentKind.noReply:
        return '${AlertPolicy.noReplyPrefix}$subjectUserId';
    }
  }

  /// First name or "A rider".
  String get who {
    final n = subjectName.trim();
    return n.isEmpty ? 'A rider' : n;
  }

  /// The main line: who and what ("Crash detected: Kiran").
  String get title {
    if (isMe) {
      switch (kind) {
        case IncidentKind.sos:
        case IncidentKind.crash:
          return 'Your SOS is on';
        case IncidentKind.possibleIncident:
          return 'Your group was asked to check on you';
        case IncidentKind.noSignal:
          return 'Your phone had no signal';
        case IncidentKind.noReply:
          return 'Your lead was told you did not answer';
      }
    }
    switch (kind) {
      case IncidentKind.crash:
        return 'Crash detected: $who';
      case IncidentKind.sos:
        return 'SOS: $who needs help';
      case IncidentKind.possibleIncident:
        return 'Possible incident: check on $who';
      case IncidentKind.noSignal:
        return 'No signal from $who';
      case IncidentKind.noReply:
        return 'No reply from $who';
    }
  }

  /// What happened, in two or three words ("Automatic crash alert", "SOS", "Possible incident").
  String get what {
    switch (kind) {
      case IncidentKind.crash:
        return auto ? 'Automatic crash alert' : 'Crash alert';
      case IncidentKind.sos:
        return auto ? 'Automatic SOS' : 'SOS';
      case IncidentKind.possibleIncident:
        final k = fromKmh;
        return k == null || k <= 0 ? 'Possible incident, automatic alert' : 'Possible incident: stopped suddenly from ${k.round()} km/h';
      case IncidentKind.noSignal:
        final k = fromKmh;
        return k == null || k <= 0 ? 'No signal, automatic alert' : 'No signal after riding at ${k.round()} km/h';
      case IncidentKind.noReply:
        return 'Did not answer Are you OK';
    }
  }
}

/// Open emergencies of [c] as [myUid] should see them, most urgent first:
/// open SOS and crash alerts (everyone), possible incidents (the riders the
/// server asked, the lead and the sweeper, and the rider themself), escalated
/// no-signal entries (lead and sweeper) and no-reply entries (lead, sweeper,
/// and the rider themself). Pure.
List<IncidentView> incidentsFor(ConvoyModel c, TimelineService? t, String myUid, int nowMs) {
  final events = (t == null || t.groupId != c.groupId) ? const <TimelineEventModel>[] : t.events;
  return incidentsFromEvents(c, events, myUid, nowMs);
}

/// [incidentsFor] with the timeline entries given directly (for tests and the Alerts tab).
List<IncidentView> incidentsFromEvents(ConvoyModel c, Iterable<TimelineEventModel> events, String myUid, int nowMs) {
  final me = c.riders[myUid];
  final role = me?.role ?? 'PACK';
  final isLead = myUid.isNotEmpty && (c.createdByUserId == myUid || role == 'LEAD');
  final isSweeper = role == 'SWEEPER';
  final out = <IncidentView>[];
  final withSos = <String>{};

  (double, double, int) whereAt(String uid, double lat, double lng, int at) {
    final r = c.riders[uid];
    // The rider's own newer position beats the place of the alert (they may have been moved).
    if (r != null && (r.lat != 0 || r.lng != 0) && r.lastSeenEpochMs > at) return (r.lat, r.lng, r.lastSeenEpochMs);
    if (lat != 0 || lng != 0) return (lat, lng, at);
    return (r?.lat ?? 0.0, r?.lng ?? 0.0, r?.lastSeenEpochMs ?? 0);
  }

  String nameOf(String uid, String fallback) {
    final r = c.riders[uid];
    final n = (r?.name ?? '').trim();
    return n.isNotEmpty ? n : fallback;
  }

  for (final a in c.activeAlerts) {
    if (a.resolved) continue;
    withSos.add(a.userId);
    final at = a.occurredAt > 0 ? a.occurredAt : a.timestamp;
    final updated = a.lastUpdateAt ?? a.timestamp;
    final (lat, lng, posAt) = whereAt(a.userId, a.lat, a.lng, updated);
    final medical = a.medical;
    out.add(IncidentView(
      kind: a.isCrash ? IncidentKind.crash : IncidentKind.sos,
      subjectUserId: a.userId,
      subjectName: nameOf(a.userId, a.userName),
      alertId: a.alertId,
      lat: lat,
      lng: lng,
      startedAt: at,
      auto: a.auto,
      responders: a.responders,
      medical: (medical == null || medical.isEmpty) ? null : medical,
      isMe: a.userId == myUid,
      fromKmh: a.speedBeforeKmh,
      alertType: a.alertType,
      status: a.status,
      source: a.source,
      network: a.network,
      ownNearest: a.ownNearest,
      positionAt: posAt,
      reportedByName: a.reportedByName,
    ));
  }

  for (final e in events) {
    final uid = e.userId;
    if (!e.open || uid == null) continue;
    final mine = uid == myUid;
    final RiderModel? r = c.riders[uid];
    if (r == null && !mine) continue; // left the ride
    IncidentKind? kind;
    switch (e.type) {
      case SafetyEventTypes.possibleIncident:
        if (withSos.contains(uid)) break; // the SOS says it already
        final notify = e.data['notify'];
        final asked = notify is List && notify.map((x) => x.toString()).contains(myUid);
        if (mine || isLead || isSweeper || asked) kind = IncidentKind.possibleIncident;
        break;
      case 'OFFLINE':
        if (mine || withSos.contains(uid)) break;
        if (e.data['escalated'] != true || e.dataString('cause') == 'APP_CLOSED') break;
        if (isLead || isSweeper) kind = IncidentKind.noSignal;
        break;
      case SafetyEventTypes.noReply:
        if (withSos.contains(uid)) break;
        if (mine || isLead || isSweeper) kind = IncidentKind.noReply;
        break;
      default:
        break;
    }
    final k = kind;
    if (k == null) continue;
    final (lat, lng, posAt) = whereAt(uid, e.lat ?? 0.0, e.lng ?? 0.0, e.startedAt);
    out.add(IncidentView(
      positionAt: posAt,
      kind: k,
      subjectUserId: uid,
      subjectName: nameOf(uid, e.userName),
      lat: lat,
      lng: lng,
      startedAt: e.startedAt,
      auto: true,
      isMe: mine,
      fromKmh: (e.dataNum('fromKmh') ?? e.dataNum('lastKmh'))?.toDouble(),
      placeName: e.placeName,
    ));
  }

  // Most urgent first (by kind), then the newest.
  out.sort((x, y) {
    final k = _rank(x.kind).compareTo(_rank(y.kind));
    return k != 0 ? k : y.startedAt.compareTo(x.startedAt);
  });
  return out;
}

int _rank(IncidentKind k) {
  switch (k) {
    case IncidentKind.crash:
      return 0;
    case IncidentKind.sos:
      return 1;
    case IncidentKind.possibleIncident:
      return 2;
    case IncidentKind.noSignal:
      return 3;
    case IncidentKind.noReply:
      return 4;
  }
}

/// "on the way" / "with them" for a responder row.
String responderWords(SosResponseKind k) {
  switch (k) {
    case SosResponseKind.going:
      return 'on the way';
    case SosResponseKind.withThem:
      return 'with them';
    case SosResponseKind.cancel:
      return 'no longer going';
  }
}

/// "En route", "Arriving", "On scene" for a responder from another group.
String responderStatusWords(ResponderStatus s) {
  switch (s) {
    case ResponderStatus.requested:
      return 'Asked';
    case ResponderStatus.accepted:
      return 'Accepted';
    case ResponderStatus.enRoute:
      return 'En route';
    case ResponderStatus.arriving:
      return 'Arriving';
    case ResponderStatus.arrived:
      return 'On scene';
    case ResponderStatus.unableToReach:
      return 'Unable to reach';
    case ResponderStatus.cancelled:
      return 'Cancelled';
    case ResponderStatus.declined:
      return 'Declined';
    case ResponderStatus.timeout:
      return 'No answer';
  }
}

/// "Asking nearby riders" / "No nearby riders found", or null when there is nothing to say
/// (off, or a responder is shown instead).
String? networkStateWords(NetworkState s) {
  switch (s) {
    case NetworkState.searching:
    case NetworkState.requested:
      return 'Asking nearby riders';
    case NetworkState.noneFound:
      return 'No nearby riders found';
    case NetworkState.assigned:
    case NetworkState.off:
      return null;
  }
}

/// "ETA 3 min", "ETA 1 h 5 min", or null when unknown.
String? etaWords(int? etaS) {
  final s = etaS;
  if (s == null || s < 0) return null;
  final minutes = s <= 0 ? 0 : (s / 60).ceil();
  if (minutes < 1) return 'ETA under 1 min';
  return 'ETA ${TimelineText.duration(Duration(minutes: minutes))}';
}
