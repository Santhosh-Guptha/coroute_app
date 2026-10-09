import '../../core/constants/network_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../data/models/network_models.dart';
import '../../data/models/network_wire.dart';
import '../../data/models/safety_wire.dart';
import '../../data/models/sos_alert_model.dart';
import '../../data/models/timeline_event_model.dart';
import '../timeline/timeline_text.dart';
import '../tracking/bearing.dart';
import '../tracking/geo_math.dart';
import 'alert_priority.dart';
import 'relation.dart';

/// Which notification channel an alert uses. [hazard]: accident warnings on my route
/// (amber); [social]: other riding groups nearby (silent).
enum AlertChannel { sos, alerts, updates, activity, hazard, social }

/// One notification the phone should be showing.
class AlertSpec {
  /// Stable key: the same situation always maps to the same notification,
  /// so a repeat updates it instead of stacking a new one.
  final String key;
  final AlertChannel channel;
  final String title;
  final String body;

  /// True when the alert is about the viewer themself (for example "Your group was
  /// asked to check on you"): same key family, gentler tier than the group's copy.
  final bool aboutMe;

  /// Spoken once per [key] when the alert first appears (null: not spoken).
  final String? speech;
  const AlertSpec(this.key, this.channel, this.title, this.body, {this.aboutMe = false, this.speech});

  /// Android notification id derived from [key] (positive 31-bit, stable across runs).
  int get id {
    var h = 0x811c9dc5;
    for (final c in key.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return 2000 + (h % 1000000000); // ids below 2000 are reserved (1001 = trip status)
  }

  @override
  bool operator ==(Object other) =>
      other is AlertSpec &&
      other.key == key &&
      other.title == title &&
      other.body == body &&
      other.channel == channel &&
      other.aboutMe == aboutMe &&
      other.speech == speech;

  @override
  int get hashCode => Object.hash(key, title, body, channel, aboutMe, speech);
}

/// Who this phone belongs to, for deciding who gets which alert.
class AlertViewer {
  final String userId;
  final bool isLead;
  final bool isSweeper;

  /// My last known position (for "3.4 km from you"); null when unknown.
  final double? lat;
  final double? lng;

  /// My group's route line (for "ahead on your route" / "behind your location"); empty when none.
  final List<(double, double)> route;
  const AlertViewer({required this.userId, this.isLead = false, this.isSweeper = false, this.lat, this.lng, this.route = const []});

  bool get hasPosition {
    final la = lat, ln = lng;
    return la != null && ln != null && (la != 0 || ln != 0);
  }
}

/// Turns the group timeline into notifications.
///
/// State versus events: the live trip status lives in the ongoing
/// notification. This policy covers events only, and only the ones that
/// deserve attention, and it answers "what should be showing now?" rather
/// than "what happened?". The caller shows what is new and removes what is
/// no longer true, so an alert disappears by itself when its cause ends
/// (the rider moves again, the SOS is resolved, the group regroups).
class AlertPolicy {
  /// One key for every "Meeting point changed" alert: a newer meeting point
  /// replaces the older alert (same notification, one row in the app).
  static const String meetingKey = 'EV:MEETING';

  /// Key prefixes of the 3.14 safety alerts (the UI and the tiers use them).
  static const String sosPrefix = 'SOS:';
  static const String incidentPrefix = 'INCIDENT:';
  static const String noSignalPrefix = 'NO_SIGNAL:';
  static const String closedPrefix = 'CLOSED:';
  static const String noReplyPrefix = 'NO_REPLY:';

  /// Key prefixes of the 3.15 safety network and discovery alerts.
  static const String assistPrefix = 'ASSIST:';
  static const String assistTakenPrefix = 'ASSIST_TAKEN:';
  static const String hazardPrefix = 'HAZARD:';
  static const String encounterPrefix = 'MEET:';

  /// Keys of the rider-only prompts shown by the safety service.
  static const String localFatigueKey = 'LOCAL:FATIGUE';
  static const String localCheckInKey = 'LOCAL:CHECK_IN';

  /// Key prefixes of the 3.16 alerts: a rider's updates stopped, low battery, behind the sweeper.
  static const String stalePrefix = 'STALE:';
  static const String batteryPrefix = 'BATTERY:';
  static const String behindPrefix = 'BEHIND:';

  /// Keys of the 3.16 rider-only prompts (fuel reminder, post-crash follow-up).
  static const String fuelKey = 'LOCAL:FUEL';
  static const String followUpKey = 'LOCAL:FOLLOW_UP';

  /// Source names of a "Rider down" report (the subject did not raise it themself).
  static bool _reportSource(String source) =>
      source == EmergencySource.memberReport.wire || source == EmergencySource.nearbyReport.wire;

  /// A timeline SOS entry that is a report by another rider: the live alert says so, or a
  /// 3.16 gateway put `source` (or `reportedByName` on a RIDER_DOWN) in the entry data.
  static bool isReportEntry(TimelineEventModel e, [SosAlertModel? alert]) {
    if (alert != null) return alert.isReport;
    if (_reportSource(e.dataString('source').toUpperCase())) return true;
    return e.dataString('alertType') == SosTypes.riderDown && e.dataString('reportedByName').isNotEmpty;
  }

  /// "1.8 km north-east of you" from the viewer to a point, or '' when either position is unknown.
  static String directionFromMe(AlertViewer me, double? lat, double? lng) {
    final myLat = me.lat, myLng = me.lng;
    if (lat == null || lng == null || myLat == null || myLng == null) return '';
    if ((myLat == 0 && myLng == 0) || (lat == 0 && lng == 0)) return '';
    return Bearing.fromMe(GeoMath.haversine(myLat, myLng, lat, lng), Bearing.degrees(myLat, myLng, lat, lng));
  }

  /// Alerts that are shown as a notification even while CoRoute is open:
  /// safety alerts (the alerts channel). The meeting point already shows in
  /// the ride alert slot, so it is not posted twice while the app is open.
  static bool showWhileOpen(AlertSpec a) => a.channel == AlertChannel.alerts && a.key != meetingKey;

  /// "Meeting point changed": where, and how far from me as the crow flies.
  static AlertSpec meetingChanged(TimelineEventModel e, AlertViewer me) {
    final name = e.dataString('name').isNotEmpty ? e.dataString('name') : e.placeName;
    final lat = e.lat, lng = e.lng, myLat = me.lat, myLng = me.lng;
    var far = '';
    if (lat != null && lng != null && myLat != null && myLng != null && (myLat != 0 || myLng != 0)) {
      far = '${TimelineText.distance(GeoMath.haversine(myLat, myLng, lat, lng))} from you';
    }
    final body = [
      if (name.isNotEmpty) name,
      if (far.isNotEmpty) far,
    ].join(', ');
    return AlertSpec(meetingKey, AlertChannel.alerts, 'Meeting point changed', body.isEmpty ? '' : '$body.');
  }

  AlertPolicy({
    this.stationaryAlert = const Duration(minutes: 20),
    this.offlineAlert = const Duration(minutes: 5),
    this.checkInFarFor = const Duration(minutes: 15),
  });

  final Duration stationaryAlert;
  final Duration offlineAlert;

  /// How long a rider was far from the group before the "Are you OK?" check (for the NO_REPLY text).
  final Duration checkInFarFor;

  /// Alerts that should be visible right now, from the open timeline entries.
  ///
  /// [alerts] (optional, 3.15) are the convoy's live SOS alerts: when an open SOS entry
  /// has its live alert here (or the entry carries a 3.15 status), it is shown in the
  /// EMERGENCY form with the latest position, "Last location update" and the nearby
  /// assistance state.
  ///
  /// [speechLang] (3.16) is the language of the spoken lines ('en', 'hi', 'te'): what the
  /// phone's voice can say, which may differ from the screen language.
  List<AlertSpec> standing(Iterable<TimelineEventModel> events, AlertViewer me,
      {required int nowMs, Iterable<SosAlertModel> alerts = const [], String speechLang = 'en'}) {
    final out = <AlertSpec>[];
    final live = <String, SosAlertModel>{for (final a in alerts) a.alertId: a};
    for (final e in events) {
      if (!e.open || e.userId == null) continue;
      final mine = e.userId == me.userId;
      final who = e.userName.isNotEmpty ? e.userName : 'A rider';
      final dur = e.durationAt(nowMs);
      final where = e.placeName.isNotEmpty ? ' near ${e.placeName}' : '';
      switch (e.type) {
        case 'SOS':
          final kind = e.dataString('alertType');
          final key = '$sosPrefix${e.dataString('alertId').isEmpty ? e.eventId : e.dataString('alertId')}';
          final a = live[e.dataString('alertId')];
          if (isReportEntry(e, a)) {
            // "Rider down here" by another rider: never "may have met with an accident".
            final spec = report(key, who: who, event: e, alert: a, me: me, nowMs: nowMs, speechLang: speechLang);
            if (spec != null) out.add(spec);
            break;
          }
          if (mine) break; // the sender already knows
          if (a != null || e.data.containsKey('status') || e.data.containsKey('source') || (kind == SosTypes.crash && e.data['auto'] == true) || kind == SosTypes.riderDown) {
            out.add(emergency(key, who: who, event: e, alert: a, me: me, nowMs: nowMs, speechLang: speechLang));
            break;
          }
          final dir = directionFromMe(me, e.lat, e.lng);
          if (kind == 'CRASH' && e.data['auto'] == true) {
            out.add(AlertSpec(key, AlertChannel.sos, 'Crash detected: $who',
                'Automatic alert.${dir.isEmpty ? '' : ' ${_cap(dir)}.'} Open CoRoute to see where.'));
            break;
          }
          out.add(AlertSpec(key, AlertChannel.sos, 'SOS from $who',
              '${kind.isEmpty ? 'Needs help' : TimelineText.reason(kind)}$where.${dir.isEmpty ? '' : ' ${_cap(dir)}.'} Open CoRoute to see where.'));
          break;
        case 'POSSIBLE_INCIDENT':
          if (mine) {
            out.add(AlertSpec('$incidentPrefix${e.userId}', AlertChannel.alerts, 'Your group was asked to check on you',
                "You stopped suddenly. Tap I'm OK if you are fine.", aboutMe: true));
            break;
          }
          final notify = e.data['notify'];
          final told = notify is List && notify.map((x) => x.toString()).contains(me.userId);
          if (!(told || me.isLead || me.isSweeper)) break;
          final from = e.dataNum('fromKmh');
          out.add(AlertSpec('$incidentPrefix${e.userId}', AlertChannel.alerts, 'Possible incident: check on $who',
              'Automatic alert. Stopped suddenly${from == null ? '' : ' from ${from.round()} km/h'}$where.'));
          break;
        case 'NO_REPLY':
          if (mine || !(me.isLead || me.isSweeper)) break;
          out.add(AlertSpec('$noReplyPrefix${e.userId}', AlertChannel.alerts, 'No reply from $who',
              'Far from the group for ${TimelineText.duration(checkInFarFor)} and did not answer Are you OK. Automatic check.'));
          break;
        case 'STOPPED':
          if (mine || dur < stationaryAlert || !(me.isLead || me.isSweeper)) break;
          final r = e.dataString('reason');
          final d = TimelineText.duration(dur);
          out.add(AlertSpec('STOPPED:${e.userId}', AlertChannel.alerts, '$who has been stopped for $d',
              '${r.isEmpty ? 'No reason given' : TimelineText.reason(r)}$where.',
              speech: L10n.t('speech.stopped', {'name': who, 'dur': d}, speechLang)));
          break;
        case 'SEPARATED':
          final km = TimelineText.distance(e.dataNum('maxDistanceM') ?? e.dataNum('distanceM') ?? 0);
          if (mine) {
            out.add(AlertSpec('SEPARATED:${e.userId}', AlertChannel.alerts, 'You are $km from your group', 'Slow down or wait for them to catch up.',
                speech: L10n.t('speech.separated.self', {'km': km}, speechLang)));
          } else if (me.isLead || me.isSweeper) {
            out.add(AlertSpec('SEPARATED:${e.userId}', AlertChannel.alerts, '$who is $km from the group', 'Separated for ${TimelineText.duration(dur)}.',
                speech: L10n.t('speech.separated', {'name': who, 'km': km}, speechLang)));
          }
          break;
        case SafetyEventTypes.staleUpdate:
          // 3.16: riding but no update for far longer than the group's usual gap (lead and sweeper).
          if (mine || !(me.isLead || me.isSweeper)) break;
          final ago = TimelineText.duration(dur);
          final typical = TimelineText.duration(Duration(seconds: (e.dataNum('typicalS') ?? 20).round()));
          out.add(AlertSpec(
            '$stalePrefix${e.userId}',
            AlertChannel.alerts,
            L10n.t('alert.stale.title', {'name': who, 'ago': ago}),
            L10n.t('alert.stale.body', {'typical': typical}),
            speech: L10n.t('speech.stale', {'name': who, 'ago': ago}, speechLang),
          ));
          break;
        case SafetyEventTypes.lowBattery:
          // 3.16: the rider is reminded; the lead and sweeper see it too.
          final level = (e.dataNum('level') ?? 0).round();
          if (mine) {
            out.add(AlertSpec('$batteryPrefix${e.userId}', AlertChannel.alerts, L10n.t('alert.battery.self.title', {'n': level}),
                L10n.t('alert.battery.self.body'),
                aboutMe: true));
            break;
          }
          if (!(me.isLead || me.isSweeper)) break;
          out.add(AlertSpec(
            '$batteryPrefix${e.userId}',
            AlertChannel.alerts,
            L10n.t('alert.battery.title', {'name': who, 'n': level}),
            L10n.t('alert.battery.body'),
            speech: L10n.t('speech.battery', {'name': who}, speechLang),
          ));
          break;
        case SafetyEventTypes.behindSweeper:
          // 3.16: a rider dropped behind the sweeper (sweeper and lead); the rider gets a gentle note.
          if (mine) {
            out.add(AlertSpec('$behindPrefix${e.userId}', AlertChannel.updates, L10n.t('alert.behind.self'), L10n.t('alert.behind.self.body'), aboutMe: true));
            break;
          }
          if (!(me.isLead || me.isSweeper)) break;
          final behindKm = TimelineText.distance(e.dataNum('distanceM') ?? e.dataNum('maxDistanceM') ?? 0);
          out.add(AlertSpec(
            '$behindPrefix${e.userId}',
            AlertChannel.alerts,
            L10n.t('alert.behind.title', {'name': who}),
            L10n.t('alert.behind.body', {'km': behindKm, 'dur': TimelineText.duration(dur)}),
            speech: L10n.t('speech.behind', {'name': who}, speechLang),
          ));
          break;
        case 'OFFLINE':
          if (mine) break;
          final cause = e.dataString('cause');
          if (cause == 'APP_CLOSED') {
            if (!me.isLead) break;
            out.add(AlertSpec('$closedPrefix${e.userId}', AlertChannel.alerts, "CoRoute was closed on $who's phone",
                'Their position stops until they open it again.'));
            break;
          }
          if (e.data['escalated'] == true) {
            // Replaces the plain OFFLINE alert: a fast rider silent for long, away from any stop.
            if (!(me.isLead || me.isSweeper)) break;
            final kmh = e.dataNum('lastKmh');
            out.add(AlertSpec('$noSignalPrefix${e.userId}', AlertChannel.alerts, 'No signal from $who for ${TimelineText.duration(dur)}',
                'Last seen$where${kmh == null ? '' : ' at ${kmh.round()} km/h'}. Automatic alert.'));
            break;
          }
          if (!me.isLead || dur < offlineAlert) break;
          out.add(AlertSpec('OFFLINE:${e.userId}', AlertChannel.alerts, 'No signal from $who for ${TimelineText.duration(dur)}',
              cause == 'KILLED'
                  ? 'Last seen$where. The phone closed CoRoute.'
                  : 'Last seen$where. Their phone will catch up when it has signal again.'));
          break;
        case 'OFF_ROUTE':
          if (mine) {
            out.add(AlertSpec('OFF_ROUTE:${e.userId}', AlertChannel.updates, 'You are off the planned route', 'Check the map to get back on the route.'));
          } else if (me.isLead) {
            out.add(AlertSpec('OFF_ROUTE:${e.userId}', AlertChannel.updates, '$who is off the route', 'For ${TimelineText.duration(dur)}$where.'));
          }
          break;
        default:
          break;
      }
    }
    return out;
  }

  /// A one-time alert for something that just happened (shown once, removed after a while).
  AlertSpec? oneShot(TimelineEventModel e, AlertViewer me) {
    final who = e.userName.isNotEmpty ? e.userName : 'A rider';
    final mine = e.userId == me.userId;
    switch (e.type) {
      case 'DESTINATION_REACHED':
        return AlertSpec('EV:${e.eventId}', AlertChannel.updates, mine ? 'You reached the destination' : '$who reached the destination', e.placeName);
      case 'STOP_REACHED':
        if (mine) return null;
        return AlertSpec('EV:${e.eventId}', AlertChannel.updates, '$who reached ${e.dataString('name').isEmpty ? 'the stop' : e.dataString('name')}', '');
      case 'STOP_ALL_REACHED':
        return AlertSpec('EV:${e.eventId}', AlertChannel.updates, 'Everyone reached ${e.dataString('name').isEmpty ? 'the stop' : e.dataString('name')}', 'The whole group is together.');
      case 'DESTINATION_ALL_REACHED':
        return AlertSpec('EV:${e.eventId}', AlertChannel.updates, 'Everyone reached the destination', e.placeName);
      case 'OVERSPEED':
        // Announced once per episode to everyone; repeats soon after are only logged.
        if (e.data['notify'] == false) return null;
        final limit = e.dataNum('limitKmh')?.round();
        final top = e.dataNum('maxKmh')?.round();
        // 3.16: within 1 km of a stop, the start or the destination the lower town limit applies.
        final town = e.dataString('context').toUpperCase() == 'TOWN';
        final lim = limit == null
            ? (town ? 'the limit ${L10n.t('alert.overspeed.town')}' : 'the group speed limit')
            : (town ? 'the limit of $limit km/h ${L10n.t('alert.overspeed.town')}' : 'the group limit of $limit km/h');
        final body = mine
            ? ['Please slow down.', if (top != null) 'You reached $top km/h.'].join(' ')
            : [if (top != null) 'Reached $top km/h', if (e.placeName.isNotEmpty) 'near ${e.placeName}'].join(' ');
        return AlertSpec('EV:${e.eventId}', AlertChannel.alerts, mine ? 'You are over $lim' : '$who is over $lim', body);
      case 'STOP_SUGGESTED':
        if (!me.isLead || mine) return null;
        return AlertSpec('EV:${e.eventId}', AlertChannel.updates, '$who suggests a stop', '${e.dataString('name')}. Open the stops list to add it or decline.');
      case 'JOINED':
        if (mine) return null;
        return AlertSpec('EV:${e.eventId}', AlertChannel.activity, '$who joined the convoy', '');
      case 'LEFT':
        if (mine) return null;
        return AlertSpec('EV:${e.eventId}', AlertChannel.activity, '$who left the convoy', '');
      case 'STOP_ADDED':
        if (mine) return null;
        if (e.dataString('category').toUpperCase() == 'MEETING') return meetingChanged(e, me);
        return AlertSpec('EV:${e.eventId}', AlertChannel.activity, TimelineText.title(e, nowMs: e.startedAt), 'The route on your map is updated.');
      case 'ROUTE_CHANGED':
        if (mine) return null;
        return AlertSpec('EV:${e.eventId}', AlertChannel.activity, TimelineText.title(e, nowMs: e.startedAt), 'The route on your map is updated.');
      case 'SOS_RESPONSE':
        // e.userId is the responder; forUserId the rider who raised the SOS.
        if (mine) return null;
        final kind = e.dataString('kind');
        if (kind != 'GOING' && kind != 'WITH_THEM') return null;
        final forMe = e.dataString('forUserId') == me.userId;
        if (!forMe && !me.isLead) return null;
        final forName = e.dataString('forUserName').isEmpty ? 'the rider' : e.dataString('forUserName');
        final title = kind == 'GOING'
            ? (forMe ? '$who is on the way to you' : '$who is going to $forName')
            : (forMe ? '$who is with you' : '$who is with $forName');
        return AlertSpec('EV:${e.eventId}', AlertChannel.updates, title, '');
      default:
        return null;
    }
  }

  static String _cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  // ------------------------------------------------------------------ 3.15

  /// "ETA 3 min" (at least 1 min).
  static String etaText(int seconds) => 'ETA ${seconds <= 60 ? 1 : (seconds / 60).round()} min';

  /// The own-group EMERGENCY alert for someone else's open SOS (crash, RIDER_DOWN, manual).
  /// [alert] is the live alert when known (latest position, network state).
  static AlertSpec emergency(String key,
      {required String who, required TimelineEventModel event, SosAlertModel? alert, required AlertViewer me, required int nowMs, String speechLang = 'en'}) {
    final a = alert;
    final kind = a?.alertType ?? event.dataString('alertType');
    final source = a?.effectiveSource ?? EmergencySource.fromWire(event.dataString('source'));
    final auto = a?.auto ?? (event.data['auto'] == true);
    final accident = a?.isAccident ??
        (kind == SosTypes.crash || kind == SosTypes.riderDown || source == EmergencySource.crashAuto || source == EmergencySource.needHelp);
    final lat = a?.lat ?? event.lat, lng = a?.lng ?? event.lng;
    final atMs = a?.lastKnownAt ?? event.startedAt;
    final String what;
    if (accident) {
      what = L10n.t('alert.accident.body', {'name': who});
    } else if (kind.isEmpty || kind == SosTypes.emergency || kind == SosTypes.crashOrEmergency) {
      what = L10n.t('alert.help.body', {'name': who});
    } else {
      what = L10n.t('alert.help.kind', {'name': who, 'kind': TimelineText.reason(kind)});
    }
    final automatic = source == EmergencySource.crashAuto || (kind == SosTypes.crash && auto);
    var rel = '', spoken = '';
    if (me.hasPosition && lat != null && lng != null) {
      rel = Relation.text(myLat: me.lat!, myLng: me.lng!, lat: lat, lng: lng, route: me.route);
      spoken = Relation.spoken(myLat: me.lat!, myLng: me.lng!, lat: lat, lng: lng, route: me.route);
    }
    final String speech;
    if (accident) {
      speech = spoken.isEmpty ? L10n.t('speech.emergency.nowhere', {'name': who}, speechLang) : L10n.t('speech.emergency', {'name': who, 'where': spoken}, speechLang);
    } else {
      speech = spoken.isEmpty ? L10n.t('speech.help.nowhere', {'name': who}, speechLang) : L10n.t('speech.help', {'name': who, 'where': spoken}, speechLang);
    }
    final hospital = hospitalLine(a);

    final net = a?.network;
    final responder = net?.activeResponder;
    final String body;
    if (responder != null) {
      final rName = responder.name.isEmpty ? 'A nearby rider' : responder.name;
      if (responder.status == ResponderStatus.arrived) {
        body = 'Nearby rider has reached $who. Responder: $rName from a nearby riding group.';
      } else {
        final own = a?.ownNearest;
        body = [
          'Nearby assistance accepted. A nearby rider is responding.',
          if (responder.etaS != null) 'Responder ${etaText(responder.etaS!)}.',
          if (own != null) 'Your nearest group rider ${etaText(own.etaS)}.',
          if (hospital.isNotEmpty) hospital,
        ].join(' ');
      }
    } else {
      body = [
        what,
        if (automatic) L10n.t('alert.automatic'),
        if (rel.isNotEmpty) '${_cap(rel)}.',
        '${Relation.lastUpdate(atMs, nowMs)}.',
        if (net != null && net.onScene) 'A nearby rider reported they are at the scene.',
        if (hospital.isNotEmpty) hospital,
      ].join(' ');
    }
    return AlertSpec(key, AlertChannel.sos, L10n.t('alert.emergency.title'), body, speech: speech);
  }

  /// "Nearest hospital: Apollo, 4.2 km." when the server found one (3.16), else ''.
  static String hospitalLine(SosAlertModel? a) {
    final h = a?.nearestHospital;
    if (h == null) return '';
    return '${L10n.t('alert.hospital', {'name': h.name, 'km': Relation.distanceText(h.distanceM)})}.';
  }

  /// The own-group alert for a "Rider down here" report (3.16 wording fix): the reporter's
  /// name and the place, never "may have met with an accident". Null for the reporter.
  /// The subject of a member report gets "{reporter} reported that you are down".
  static AlertSpec? report(String key,
      {required String who, required TimelineEventModel event, SosAlertModel? alert, required AlertViewer me, required int nowMs, String speechLang = 'en'}) {
    final a = alert;
    final reporterId = a?.reportedBy ?? event.dataString('reportedBy');
    final source = a?.effectiveSource ?? EmergencySource.fromWire(event.dataString('source'));
    // A nearby report is raised by the reporter themself (the subject is not in the group).
    final nearby = source == EmergencySource.nearbyReport;
    final reportedById = reporterId.isNotEmpty ? reporterId : (nearby ? (event.userId ?? '') : '');
    if (reportedById.isNotEmpty && reportedById == me.userId) return null;
    var reporter = (a?.reportedByName ?? event.dataString('reportedByName')).trim();
    if (reporter.isEmpty) reporter = nearby ? who : 'A rider';
    final title = L10n.t('alert.report.title');
    final hospital = hospitalLine(a);
    if (!nearby && event.userId == me.userId) {
      return AlertSpec(key, AlertChannel.sos, title, L10n.t('alert.report.self', {'reporter': reporter}), aboutMe: true);
    }
    final lat = a?.lat ?? event.lat, lng = a?.lng ?? event.lng;
    var rel = '', spoken = '';
    if (me.hasPosition && lat != null && lng != null) {
      rel = Relation.text(myLat: me.lat!, myLng: me.lng!, lat: lat, lng: lng, route: me.route);
      spoken = Relation.spoken(myLat: me.lat!, myLng: me.lng!, lat: lat, lng: lng, route: me.route);
    }
    final String line;
    if (event.placeName.isNotEmpty) {
      line = L10n.t('alert.report.body', {'reporter': reporter, 'place': event.placeName});
    } else if (rel.isNotEmpty) {
      line = L10n.t('alert.report.body.at', {'reporter': reporter, 'where': rel});
    } else {
      line = L10n.t('alert.report.body.noplace', {'reporter': reporter});
    }
    final speech = spoken.isEmpty
        ? L10n.t('speech.report.nowhere', {'reporter': reporter}, speechLang)
        : L10n.t('speech.report', {'reporter': reporter, 'where': spoken}, speechLang);
    return AlertSpec(key, AlertChannel.sos, title, [line, if (hospital.isNotEmpty) hospital].join(' '), speech: speech);
  }

  /// Where a point is for assistance and hazard texts: live from my position when known,
  /// else the server's distance ("1.6 km ahead on your route").
  static (String text, String spoken) _where(AlertViewer me, double lat, double lng, {required double fallbackM, required bool onRoute}) {
    if (me.hasPosition) {
      final t = Relation.text(myLat: me.lat!, myLng: me.lng!, lat: lat, lng: lng, route: me.route);
      final s = Relation.spoken(myLat: me.lat!, myLng: me.lng!, lat: lat, lng: lng, route: me.route);
      if (t.isNotEmpty) return (t, s);
    }
    return (
      '${Relation.distanceText(fallbackM)} ${onRoute ? 'ahead on your route' : 'away'}',
      '${Relation.spokenDistance(fallbackM)} ${onRoute ? 'ahead' : 'away'}',
    );
  }

  /// Safety network and discovery alerts (3.15): assistance requests to me, "another
  /// rider is responding" notices, accident warnings on my route and nearby groups.
  /// Social items are left out while any emergency, request or hazard is active.
  List<AlertSpec> network({
    required List<AssistRequest> assists,
    List<AssistNotice> notices = const [],
    List<HazardWarning> hazards = const [],
    List<Encounter> encounters = const [],
    required AlertViewer me,
    required int nowMs,
    bool anyEmergency = false,
    String speechLang = 'en',
  }) {
    final out = <AlertSpec>[];
    var anyAssist = false;
    for (final r in assists) {
      final st = r.myStatus;
      if (st == ResponderStatus.declined || st == ResponderStatus.cancelled || st == ResponderStatus.unableToReach) continue;
      anyAssist = true;
      final key = '$assistPrefix${r.incidentId}';
      final (where, spoken) = _where(me, r.lat, r.lng, fallbackM: r.distanceM, onRoute: r.aheadOnRoute);
      if (st == ResponderStatus.arrived) {
        out.add(AlertSpec(key, AlertChannel.sos, 'You reached the rider', 'Call emergency services 112 if they need more help.'));
      } else if (r.accepted) {
        out.add(AlertSpec(key, AlertChannel.sos, 'You are responding', [
          'Rider emergency $where.',
          if (r.etaS != null) '${etaText(r.etaS!)}.',
          if (r.arrivalCheck) 'Have you reached the rider?',
        ].join(' ')));
      } else {
        final what = r.isAccident ? 'A rider from another group may have met with an accident.' : 'A rider from another group needs help.';
        final String body;
        if (r.farByRoad) {
          // 3.16: asked after escalation although the road is long (straight-line close).
          final roadM = r.routeDistanceM ?? r.distanceM;
          final min = r.etaS == null ? null : (r.etaS! <= 60 ? 1 : (r.etaS! / 60).round());
          body = L10n.t('alert.far.body', {'km': Relation.distanceText(roadM), 'min': min ?? '?'});
        } else {
          body = [
            what,
            '${_cap(where)}.',
            if (r.fasterThanGroup) 'Your group may be able to reach them before their own group.',
          ].join(' ');
        }
        out.add(AlertSpec(
          key,
          AlertChannel.sos,
          'Rider emergency nearby',
          body,
          speech: L10n.t(r.isAccident ? 'speech.assist' : 'speech.assist.help', {'where': spoken}, speechLang),
        ));
      }
    }
    for (final n in notices) {
      if (n.reason != AssistClosedReason.taken || nowMs - n.at > NetworkConstants.assistTakenShowFor.inMilliseconds) continue;
      out.add(AlertSpec('$assistTakenPrefix${n.incidentId}', AlertChannel.updates, 'Another nearby rider is responding', 'No assistance is currently required.'));
    }
    final assistIds = {
      for (final r in assists)
        if (r.myStatus != ResponderStatus.declined && r.myStatus != ResponderStatus.cancelled && r.myStatus != ResponderStatus.unableToReach) r.incidentId,
    };
    for (final h in hazards) {
      // Asked to help with this very accident (hazardId = incidentId): one alert, one voice line.
      if (assistIds.contains(h.hazardId)) continue;
      double? ahead;
      if (me.hasPosition) {
        final d = Relation.alongDelta(myLat: me.lat!, myLng: me.lng!, lat: h.lat, lng: h.lng, route: me.route);
        if (d != null && d >= 0) ahead = d;
      }
      final onRoute = ahead != null || h.onRoute;
      final dist = ahead ?? h.aheadM ?? (me.hasPosition ? GeoMath.haversine(me.lat!, me.lng!, h.lat, h.lng) : null);
      final where = dist == null ? 'nearby' : '${Relation.distanceText(dist)} ahead${onRoute ? ' on your route' : ''}';
      final level = switch (h.level) {
        HazardLevel.active => '',
        HazardLevel.responderArriving => ' Help is on the way to the rider.',
        HazardLevel.onScene => ' Help is at the scene.',
      };
      out.add(AlertSpec(
        '$hazardPrefix${h.hazardId}',
        AlertChannel.hazard,
        'Caution',
        'Rider accident reported $where.$level Reduce speed and stay alert.',
        speech: dist == null
            ? L10n.t('speech.hazard.nearby', const {}, speechLang)
            : L10n.t('speech.hazard', {'where': '${Relation.spokenDistance(dist)} ahead'}, speechLang),
      ));
    }
    if (AlertArbiter.socialAllowed(anyEmergency: anyEmergency, anyAssist: anyAssist, anyHazard: hazards.isNotEmpty)) {
      for (final e in encounters) {
        out.add(encounter(e));
        final waved = e.theyWavedAt;
        if (waved != null && nowMs - waved <= NetworkConstants.waveNotifyFor.inMilliseconds) {
          out.add(AlertSpec('$encounterPrefix${e.encounterId}:WAVE', AlertChannel.social, '${_groupName(e)} waved', ''));
        }
      }
    }
    return out;
  }

  static String _groupName(Encounter e) => e.groupName.trim().isEmpty ? 'A riding group' : e.groupName.trim();

  /// "Weekend Riders nearby" / "6 riders, about 4.7 km. Travelling on the same route."
  static AlertSpec encounter(Encounter e) {
    final key = '$encounterPrefix${e.encounterId}';
    final title = '${_groupName(e)} nearby';
    final dist = Relation.distanceText(e.distanceM);
    if (e.type == EncounterType.oppositeDirection) {
      return AlertSpec(key, AlertChannel.social, title, 'Another riding group is approaching from the opposite direction. $dist away.');
    }
    final riders = e.riders <= 0 ? '' : '${e.riders} rider${e.riders == 1 ? '' : 's'}, ';
    final meet = e.meetingS == null ? '' : ' Meeting in about ${(e.meetingS! / 60).round() < 1 ? 1 : (e.meetingS! / 60).round()} min.';
    final how = switch (e.type) {
      EncounterType.sameDirection => e.sameRoute ? 'Travelling on the same route.' : 'Travelling in the same direction.',
      EncounterType.converging => 'Joining your route ahead.',
      EncounterType.crossing => 'Crossing your route ahead.',
      EncounterType.oppositeDirection => '',
    };
    return AlertSpec(key, AlertChannel.social, title, '${riders.isEmpty ? 'About' : '${riders}about'} $dist. $how$meet');
  }
}
