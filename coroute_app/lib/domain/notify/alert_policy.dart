import '../../core/constants/network_constants.dart';
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
  List<AlertSpec> standing(Iterable<TimelineEventModel> events, AlertViewer me, {required int nowMs, Iterable<SosAlertModel> alerts = const []}) {
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
          if (mine) break; // the sender already knows
          final kind = e.dataString('alertType');
          final key = '$sosPrefix${e.dataString('alertId').isEmpty ? e.eventId : e.dataString('alertId')}';
          final a = live[e.dataString('alertId')];
          if (a != null || e.data.containsKey('status') || e.data.containsKey('source') || (kind == SosTypes.crash && e.data['auto'] == true) || kind == SosTypes.riderDown) {
            out.add(emergency(key, who: who, event: e, alert: a, me: me, nowMs: nowMs));
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
          out.add(AlertSpec('STOPPED:${e.userId}', AlertChannel.alerts, '$who has been stopped for ${TimelineText.duration(dur)}',
              '${r.isEmpty ? 'No reason given' : TimelineText.reason(r)}$where.'));
          break;
        case 'SEPARATED':
          final km = TimelineText.distance(e.dataNum('maxDistanceM') ?? e.dataNum('distanceM') ?? 0);
          if (mine) {
            out.add(AlertSpec('SEPARATED:${e.userId}', AlertChannel.alerts, 'You are $km from your group', 'Slow down or wait for them to catch up.'));
          } else if (me.isLead || me.isSweeper) {
            out.add(AlertSpec('SEPARATED:${e.userId}', AlertChannel.alerts, '$who is $km from the group', 'Separated for ${TimelineText.duration(dur)}.'));
          }
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
        final lim = limit == null ? 'the group speed limit' : 'the group limit of $limit km/h';
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
  static AlertSpec emergency(String key, {required String who, required TimelineEventModel event, SosAlertModel? alert, required AlertViewer me, required int nowMs}) {
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
      what = '$who may have met with an accident';
    } else if (kind.isEmpty || kind == SosTypes.emergency || kind == SosTypes.crashOrEmergency) {
      what = '$who needs help';
    } else {
      what = '$who needs help (${TimelineText.reason(kind)})';
    }
    final automatic = source == EmergencySource.crashAuto || (kind == SosTypes.crash && auto);
    var rel = '', spoken = '';
    if (me.hasPosition && lat != null && lng != null) {
      rel = Relation.text(myLat: me.lat!, myLng: me.lng!, lat: lat, lng: lng, route: me.route);
      spoken = Relation.spoken(myLat: me.lat!, myLng: me.lng!, lat: lat, lng: lng, route: me.route);
    }
    final speech = accident
        ? 'Emergency. $what${spoken.isEmpty ? '' : ' $spoken'}.'
        : 'Emergency. $what${spoken.isEmpty ? '' : ', $spoken'}.';

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
        ].join(' ');
      }
    } else {
      body = [
        '$what.',
        if (automatic) 'Automatic alert.',
        if (rel.isNotEmpty) '${_cap(rel)}.',
        '${Relation.lastUpdate(atMs, nowMs)}.',
        if (net != null && net.onScene) 'A nearby rider reported they are at the scene.',
      ].join(' ');
    }
    return AlertSpec(key, AlertChannel.sos, 'EMERGENCY', body, speech: speech);
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
        out.add(AlertSpec(
          key,
          AlertChannel.sos,
          'Rider emergency nearby',
          [
            what,
            '${_cap(where)}.',
            if (r.fasterThanGroup) 'Your group may be able to reach them before their own group.',
          ].join(' '),
          speech: r.isAccident
              ? 'Emergency alert. A rider may have had an accident $spoken. Your group may be the closest riders.'
              : 'Emergency alert. A rider needs help $spoken. Your group may be the closest riders.',
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
        speech: dist == null ? 'Caution. Rider accident reported nearby.' : 'Caution. Rider accident reported ${Relation.spokenDistance(dist)} ahead.',
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
