import '../../core/constants/ride_notification_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/network_models.dart';
import '../../data/models/network_wire.dart';
import '../../data/models/rider_model.dart';
import '../../data/models/safety_wire.dart';
import '../../data/models/sos_alert_model.dart';
import '../../data/models/timeline_event_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/timeline_service.dart';
import '../ride/ride_facts.dart';
import '../timeline/timeline_text.dart';
import '../tracking/bearing.dart';
import '../tracking/geo_math.dart';
import 'relation.dart';
import 'status_text.dart';

/// What the big ride notification shows, by priority: own group emergency,
/// then an assistance request to me, then an accident warning, then the ride.
enum NotifMode {
  ride,
  groupEmergency,
  assist,
  hazard;

  String get wire => switch (this) {
        NotifMode.ride => 'RIDE',
        NotifMode.groupEmergency => 'GROUP_EMERGENCY',
        NotifMode.assist => 'ASSIST',
        NotifMode.hazard => 'HAZARD',
      };

  /// An emergency (red) mode: the lock screen public version says so, without names.
  bool get isEmergency => this == NotifMode.groupEmergency || this == NotifMode.assist;
}

enum NotifTone {
  normal,
  warning,
  critical,
  positive;

  String get wire => switch (this) {
        NotifTone.normal => 'NORMAL',
        NotifTone.warning => 'WARNING',
        NotifTone.critical => 'CRITICAL',
        NotifTone.positive => 'POSITIVE',
      };
}

/// The fourth button of the notification (hidden for [none]).
enum NotifContextAction {
  none,
  navigateEmergency,
  iCanHelp;

  /// Action string sent back by the native side ('' for none).
  String get wire => switch (this) {
        NotifContextAction.none => '',
        NotifContextAction.navigateEmergency => NotifConstants.actionNavEmergency,
        NotifContextAction.iCanHelp => NotifConstants.actionAssistAccept,
      };
}

/// The rider's own medical ID for the lock screen during their own SOS (3.16,
/// opt-in setting "Show my medical ID on the lock screen during an SOS").
/// Blanks read "not given"; nothing of it appears unless the setting is on.
class MedicalId {
  final String bloodGroup;
  final String allergies;
  final String contactName;
  final String contactPhone;

  const MedicalId({this.bloodGroup = '', this.allergies = '', this.contactName = '', this.contactPhone = ''});

  /// From the signed-in rider's profile.
  factory MedicalId.fromAuth(AuthService a) => MedicalId(
        bloodGroup: a.bloodGroup.trim(),
        allergies: a.allergies.trim(),
        contactName: (a.emergencyContactName ?? '').trim(),
        contactPhone: (a.emergencyContact ?? '').trim(),
      );

  bool get isEmpty => bloodGroup.isEmpty && allergies.isEmpty && contactName.isEmpty && contactPhone.isEmpty;

  /// "Blood group O+. Allergies: penicillin. Emergency contact: Asha 98765 43210."
  String line() {
    final none = L10n.t('notif.medical.none');
    final contact = [if (contactName.isNotEmpty) contactName, if (contactPhone.isNotEmpty) contactPhone].join(' ');
    return L10n.t('notif.medical', {
      'blood': bloodGroup.isEmpty ? none : bloodGroup,
      'allergies': allergies.isEmpty ? none : allergies,
      'contact': contact.isEmpty ? none : contact,
    });
  }
}

/// One rider in the notification ladder ("Arjun  1.2 km ahead", "No signal").
class RiderLine {
  final String name;
  final double distanceM;

  /// True ahead of me, false behind (or side unknown, see [sideKnown]).
  final bool ahead;

  /// "No signal", "Stopped 5 min", or null.
  final String? flag;

  /// False when neither the route nor my heading tell the side ("1.2 km away").
  final bool sideKnown;

  const RiderLine({required this.name, required this.distanceM, required this.ahead, this.flag, this.sideKnown = true});

  /// "1.2 km ahead", "450 m behind", "3.4 km away" (rounded, stable across small moves).
  String get detail {
    final d = StatusText.roundedDistance(distanceM);
    if (!sideKnown) return '$d away';
    return ahead ? '$d ahead' : '$d behind';
  }

  Map<String, Object?> toArgs() => {'name': name, 'detail': detail, 'flag': flag ?? '', 'ahead': ahead};

  String get _key => '$name|$detail|${flag ?? ''}|$ahead';
}

/// Everything the native ride notification draws. Pure data; equal snapshots
/// have the same [dedupeKey], so the service pushes only when it changed.
class NotificationSnapshot {
  final NotifMode mode;
  final NotifTone tone;

  /// Collapsed line 1 and the bold first line of the expanded view.
  final String title;

  /// Collapsed line 2.
  final String subtitle;

  /// Small line under the title in the expanded view (convoy and rider count).
  final String? header;

  /// Group status or emergency progress line of the expanded view.
  final String? statusLine;

  /// [statusLine] is good news (a responder is on the way or with the rider): shown green.
  final bool statusPositive;

  /// At most [NotifConstants.ladderPerSide] each, nearest first.
  final List<RiderLine> ahead;
  final List<RiderLine> behind;

  final NotifContextAction contextAction;
  final String? contextLabel;
  final String? contextRef;

  /// Show the full content on the lock screen (setting "Show ride on lock screen").
  final bool lockScreenPublic;
  final bool showSos;
  final bool showWait;

  /// Lock screen text that replaces the minimal public version (3.16: the rider's own
  /// SOS with their medical ID, opt-in). Null = the usual minimal version.
  final String? customPublicText;

  const NotificationSnapshot({
    required this.mode,
    required this.tone,
    required this.title,
    required this.subtitle,
    this.header,
    this.statusLine,
    this.statusPositive = false,
    this.ahead = const [],
    this.behind = const [],
    this.contextAction = NotifContextAction.none,
    this.contextLabel,
    this.contextRef,
    this.lockScreenPublic = true,
    this.showSos = true,
    this.showWait = true,
    this.customPublicText,
  });

  /// Lock screen text when the content is hidden: never names, places or numbers,
  /// unless the rider chose to show their own medical ID during their own SOS.
  String get publicTitle => customPublicText != null ? NotifConstants.appTitle : NotifConstants.publicTitle;
  String get publicText => customPublicText ?? (mode.isEmergency ? NotifConstants.publicEmergencyText : '');

  static const String sosLabel = 'SOS';
  static const String waitLabel = 'Wait for me';
  static const String mapLabel = 'Open map';

  Map<String, Object?> toChannelArgs() => {
        'notificationId': NotifConstants.serviceNotificationId,
        'channelId': NotifConstants.channelId,
        'mode': mode.wire,
        'tone': tone.wire,
        'title': title,
        'subtitle': subtitle,
        'header': header ?? '',
        'status': statusLine ?? '',
        'statusPositive': statusPositive,
        'rows': [for (final r in ahead) r.toArgs(), for (final r in behind) r.toArgs()],
        'context': contextAction.wire,
        'contextLabel': contextLabel ?? '',
        'contextRef': contextRef ?? '',
        'lockScreenPublic': lockScreenPublic,
        'showSos': showSos,
        'showWait': showWait,
        'publicTitle': publicTitle,
        'publicText': publicText,
        'sosLabel': sosLabel,
        'waitLabel': waitLabel,
        'mapLabel': mapLabel,
      };

  String get dedupeKey => [
        mode.wire,
        tone.wire,
        title,
        subtitle,
        header ?? '',
        statusLine ?? '',
        statusPositive,
        for (final r in ahead) r._key,
        '/',
        for (final r in behind) r._key,
        contextAction.wire,
        contextLabel ?? '',
        contextRef ?? '',
        lockScreenPublic,
        showSos,
        showWait,
        customPublicText ?? '',
      ].join('\u0001');
}

/// Cheap summary used to decide whether a change must be pushed at once
/// (mode, tone or emergency state changed) or may wait for the 10 s window.
class NotifQuickState {
  final NotifMode mode;
  final NotifTone tone;

  /// Changes whenever the emergency content changes (status, responder, my answer, hazard level).
  final String key;
  const NotifQuickState(this.mode, this.tone, this.key);
}

/// Builds the ride notification from data already in memory (no GPS, no network).
class NotificationSnapshotBuilder {
  NotificationSnapshotBuilder._();

  /// [timelineEvents] is used when [timeline] is null (tests); the app passes the service.
  static NotificationSnapshot build({
    required ConvoyModel convoy,
    required String myUserId,
    TimelineService? timeline,
    List<TimelineEventModel> timelineEvents = const [],
    List<AssistRequest> assists = const [],
    List<HazardWarning> hazards = const [],
    required int nowMs,
    required bool lockScreenPublic,
    String? Function(int ms)? clockText,
    MedicalId? medicalId,
  }) {
    final clock = clockText ?? defaultClock;
    final events = timeline?.events ?? timelineEvents;
    final me = convoy.riders[myUserId];
    final ladder = _ladder(convoy, myUserId, me, events, nowMs);
    final header = _header(convoy);
    final rideStatus = _rideStatus(convoy, myUserId, me, events, nowMs);
    final ladderLine = _ladderSummary(ladder.ahead, ladder.behind);

    // 1. Own group emergency (mine or another member's).
    final sos = openEmergency(convoy);
    if (sos != null) {
      return _groupEmergency(convoy, myUserId, me, sos, ladder, header, rideStatus, clock, lockScreenPublic, medicalId);
    }

    // 2. Assistance request to me (accepted first, then the newest pending one).
    final assist = relevantAssist(assists);
    if (assist != null) {
      return _assist(assist, me, ladder, header, rideStatus, lockScreenPublic);
    }

    // 3. Accident reported ahead.
    final hazard = nearestHazard(hazards, me);
    if (hazard != null) {
      final d = _distanceTo(me, hazard.lat, hazard.lng) ?? hazard.aheadM;
      final where = d == null ? 'ahead' : '${StatusText.roundedDistance(d)} ${hazard.onRoute || me == null ? 'ahead' : 'away'}';
      return NotificationSnapshot(
        mode: NotifMode.hazard,
        tone: NotifTone.warning,
        title: 'Caution: accident reported $where',
        subtitle: _hazardWords(hazard.level),
        header: header,
        statusLine: rideStatus,
        ahead: ladder.ahead,
        behind: ladder.behind,
        lockScreenPublic: lockScreenPublic,
        showWait: ladder.othersCount > 0,
      );
    }

    // 4. The ride.
    return NotificationSnapshot(
      mode: NotifMode.ride,
      tone: NotifTone.normal,
      title: _destinationLine(convoy, me, nowMs, clock),
      subtitle: ladderLine.isNotEmpty ? ladderLine : rideStatus,
      header: header,
      statusLine: rideStatus,
      ahead: ladder.ahead,
      behind: ladder.behind,
      lockScreenPublic: lockScreenPublic,
      showWait: ladder.othersCount > 0,
    );
  }

  /// Mode, tone and an emergency key, without the ladder (cheap; called on every change).
  static NotifQuickState quickState({
    required ConvoyModel convoy,
    required String myUserId,
    List<AssistRequest> assists = const [],
    List<HazardWarning> hazards = const [],
  }) {
    final sos = openEmergency(convoy);
    if (sos != null) {
      final r = sos.network?.activeResponder;
      final own = sos.responders.map((x) => '${x.userId}:${x.kind.wire}').join(',');
      // Stays red while open; good news (a responder) shows as a green status line.
      return NotifQuickState(
        NotifMode.groupEmergency,
        NotifTone.critical,
        'E:${sos.alertId}:${sos.effectiveStatus.wire}:${r?.rid ?? ''}:${r?.status.wire ?? ''}:$own:${sos.network?.state.wire ?? ''}',
      );
    }
    final a = relevantAssist(assists);
    if (a != null) {
      return NotifQuickState(NotifMode.assist, NotifTone.critical, 'A:${a.incidentId}:${a.myStatus.wire}:${a.arrivalCheck}:${a.incidentStatus?.wire ?? ''}');
    }
    final me = convoy.riders[myUserId];
    final h = nearestHazard(hazards, me);
    if (h != null) return NotifQuickState(NotifMode.hazard, NotifTone.warning, 'H:${h.hazardId}:${h.level.wire}');
    return const NotifQuickState(NotifMode.ride, NotifTone.normal, 'R');
  }

  /// "4:35 PM" in the phone's local time.
  static String defaultClock(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  // ------------------------------------------------------------ selection

  /// The open emergency of my group the notification is about: accidents first, then the newest.
  static SosAlertModel? openEmergency(ConvoyModel convoy) {
    SosAlertModel? best;
    for (final a in convoy.activeAlerts) {
      if (a.resolved || !a.effectiveStatus.isOpen) continue;
      if (best == null) {
        best = a;
        continue;
      }
      if (a.isAccident != best.isAccident) {
        if (a.isAccident) best = a;
        continue;
      }
      if (a.timestamp > best.timestamp) best = a;
    }
    return best;
  }

  /// The assistance request to show: the one I accepted (or reached), else the newest still asking me.
  static AssistRequest? relevantAssist(List<AssistRequest> assists) {
    AssistRequest? mine;
    AssistRequest? pending;
    for (final a in assists) {
      switch (a.myStatus) {
        case ResponderStatus.accepted:
        case ResponderStatus.enRoute:
        case ResponderStatus.arriving:
        case ResponderStatus.arrived:
          mine ??= a;
          break;
        case ResponderStatus.requested:
        case ResponderStatus.timeout:
          if (pending == null || a.receivedAt > pending.receivedAt) pending = a;
          break;
        case ResponderStatus.unableToReach:
        case ResponderStatus.cancelled:
        case ResponderStatus.declined:
          break;
      }
    }
    return mine ?? pending;
  }

  /// The closest hazard to me (or the first one when my position is unknown).
  static HazardWarning? nearestHazard(List<HazardWarning> hazards, RiderModel? me) {
    HazardWarning? best;
    double? bestD;
    for (final h in hazards) {
      final d = _distanceTo(me, h.lat, h.lng) ?? h.aheadM;
      if (best == null || (d != null && (bestD == null || d < bestD))) {
        best = h;
        bestD = d;
      }
    }
    return best;
  }

  // ------------------------------------------------------------ modes

  static NotificationSnapshot _groupEmergency(
    ConvoyModel convoy,
    String myUserId,
    RiderModel? me,
    SosAlertModel sos,
    _Ladder ladder,
    String header,
    String rideStatus,
    String? Function(int ms) clock,
    bool lockScreenPublic,
    MedicalId? medicalId,
  ) {
    final updated = clock(sos.lastKnownAt) ?? '';
    final progress = _emergencyProgress(sos);
    // A nearby "Rider down here" I reported is raised in my name but is not my SOS: no medical
    // ID on the lock screen for it, and the group wording below (never "Your SOS is active").
    final selfReport = sos.isReport && sos.reportedBy == myUserId && sos.userId == myUserId;
    if (sos.userId == myUserId && !selfReport) {
      final mine = L10n.t('notif.sos.mine');
      // Opt-in (3.16): the medical ID is visible on the lock screen while my SOS is open.
      final medical = medicalId != null && !medicalId.isEmpty ? medicalId.line() : null;
      return NotificationSnapshot(
        mode: NotifMode.groupEmergency,
        tone: NotifTone.critical,
        title: mine,
        subtitle: medical ?? progress.text ?? L10n.t('notif.sos.mine.body'),
        header: header,
        statusLine: progress.text ?? rideStatus,
        statusPositive: progress.positive,
        ahead: ladder.ahead,
        behind: ladder.behind,
        // The medical line travels in the public version, so the "Show ride on lock screen"
        // choice still decides whether the rest of the ride (names, distances) is visible there.
        lockScreenPublic: lockScreenPublic,
        showSos: false,
        showWait: false,
        customPublicText: medical == null ? null : '$mine. $medical',
      );
    }
    final name = _first(sos.userName);
    final where = _whereFromMe(convoy, me, sos.lat, sos.lng);
    final when = updated.isEmpty ? '' : 'updated $updated';
    final sub = [if (where.isNotEmpty) where, if (when.isNotEmpty) when].join(', ');
    // "Rider down here" by another rider (3.16): the reporter saw someone, nothing was detected,
    // so never "may have met with an accident". A nearby report is raised by the reporter themself.
    final String what;
    if (sos.isReport) {
      final reporter = _first(sos.reportedByName.trim().isEmpty ? sos.userName : sos.reportedByName);
      final subject = sos.reportedBy.isNotEmpty && sos.reportedBy != sos.userId;
      what = subject
          ? L10n.t('incident.report.summary.named', {'reporter': reporter, 'name': name})
          : L10n.t('incident.report.summary', {'reporter': reporter});
    } else {
      what = sos.isAccident ? '$name may have met with an accident' : '$name needs help';
    }
    return NotificationSnapshot(
      mode: NotifMode.groupEmergency,
      tone: NotifTone.critical,
      title: 'EMERGENCY: $what',
      subtitle: sub.isEmpty ? 'Open CoRoute to see where.' : _cap(sub),
      header: header,
      statusLine: progress.text ?? rideStatus,
      statusPositive: progress.positive,
      ahead: ladder.ahead,
      behind: ladder.behind,
      contextAction: selfReport ? NotifContextAction.none : NotifContextAction.navigateEmergency,
      contextLabel: selfReport ? null : 'Navigate to $name',
      contextRef: sos.alertId,
      lockScreenPublic: lockScreenPublic,
      showWait: ladder.othersCount > 0,
    );
  }

  static NotificationSnapshot _assist(
    AssistRequest a,
    RiderModel? me,
    _Ladder ladder,
    String header,
    String rideStatus,
    bool lockScreenPublic,
  ) {
    final d = _distanceTo(me, a.lat, a.lng) ?? (a.distanceM > 0 ? a.distanceM : null);
    final where = d == null ? '' : '${StatusText.roundedDistance(d)} ${a.aheadOnRoute ? 'ahead' : 'away'}';
    final eta = a.etaS == null ? '' : 'ETA ${_minutes(a.etaS!)} min';
    // No names, no group, nothing about the rider before I accept (and none here after, either).
    if (a.myStatus == ResponderStatus.arrived) {
      return NotificationSnapshot(
        mode: NotifMode.assist,
        tone: NotifTone.critical,
        title: 'You are with the rider',
        subtitle: 'Call 112 if they need an ambulance.',
        header: header,
        statusLine: rideStatus,
        ahead: ladder.ahead,
        behind: ladder.behind,
        lockScreenPublic: lockScreenPublic,
        showWait: false,
      );
    }
    if (a.accepted) {
      return NotificationSnapshot(
        mode: NotifMode.assist,
        tone: NotifTone.critical,
        title: where.isEmpty ? 'You are responding to a rider emergency' : 'You are responding: rider emergency $where',
        subtitle: a.arrivalCheck ? 'Have you reached the rider? Open CoRoute to answer.' : (eta.isEmpty ? 'Ride with care.' : '$eta. Ride with care.'),
        header: header,
        statusLine: rideStatus,
        ahead: ladder.ahead,
        behind: ladder.behind,
        contextAction: NotifContextAction.navigateEmergency,
        contextLabel: 'Navigate',
        contextRef: a.incidentId,
        lockScreenPublic: lockScreenPublic,
        showWait: false,
      );
    }
    return NotificationSnapshot(
      mode: NotifMode.assist,
      tone: NotifTone.critical,
      title: where.isEmpty ? 'Rider emergency nearby' : 'Rider emergency $where',
      subtitle: a.isAccident ? 'A rider from another group may have met with an accident.' : 'A rider from another group needs help.',
      header: header,
      statusLine: a.fasterThanGroup ? 'Your group may be able to reach them before their own group.' : rideStatus,
      ahead: ladder.ahead,
      behind: ladder.behind,
      contextAction: NotifContextAction.iCanHelp,
      contextLabel: 'I Can Help',
      contextRef: a.incidentId,
      lockScreenPublic: lockScreenPublic,
      showWait: ladder.othersCount > 0,
    );
  }

  /// The help line: nearby responder, own responders, nearest member, search state.
  static ({String? text, bool positive}) _emergencyProgress(SosAlertModel sos) {
    final who = _first(sos.userName);
    final r = sos.network?.activeResponder;
    if (r != null) {
      final rn = r.name.isEmpty ? 'A nearby rider' : 'Nearby rider ${_first(r.name)}';
      if (r.status == ResponderStatus.arrived) return (text: '$rn has reached $who', positive: true);
      final eta = r.etaS == null ? '' : ', ETA ${_minutes(r.etaS!)} min';
      return (text: '$rn is responding$eta', positive: true);
    }
    for (final x in sos.responders) {
      if (x.kind == SosResponseKind.withThem) return (text: '${_first(x.name)} is with $who', positive: true);
    }
    for (final x in sos.responders) {
      if (x.kind == SosResponseKind.going) return (text: '${_first(x.name)} is on the way', positive: true);
    }
    final n = sos.ownNearest;
    if (n != null && n.name.isNotEmpty) return (text: 'Nearest member: ${_first(n.name)}, ETA ${_minutes(n.etaS)} min', positive: false);
    final net = sos.network;
    if (net != null) {
      if (net.onScene) return (text: 'A nearby rider reported they are at the scene', positive: true);
      switch (net.state) {
        case NetworkState.searching:
        case NetworkState.requested:
          return (text: 'Asking nearby riders to help', positive: false);
        case NetworkState.noneFound:
          return (text: 'No nearby riders found yet', positive: false);
        case NetworkState.assigned:
          return (text: 'A nearby rider is responding', positive: true);
        case NetworkState.off:
          break;
      }
    }
    return (text: null, positive: false);
  }

  static String _hazardWords(HazardLevel level) => switch (level) {
        HazardLevel.active => 'Reduce speed and stay alert.',
        HazardLevel.responderArriving => 'Help is on the way. Reduce speed and stay alert.',
        HazardLevel.onScene => 'Help is at the scene. Reduce speed and stay alert.',
      };

  // ------------------------------------------------------------ ride parts

  static String _header(ConvoyModel convoy) {
    final n = convoy.riders.length;
    return '${convoy.name}, $n rider${n == 1 ? '' : 's'}';
  }

  /// "Goa, 42 km, ETA 4:35 PM" (remaining along the route, ETA as clock time so no timer is needed).
  static String _destinationLine(ConvoyModel convoy, RiderModel? me, int nowMs, String? Function(int ms) clock) {
    if (!RideFacts.hasDestination(convoy)) return convoy.name;
    final raw = convoy.destinationName.split(',').first.trim();
    final dest = raw.isEmpty ? 'Destination' : (raw.length > 24 ? '${raw.substring(0, 23)}.' : raw);
    if (me == null || !RideFacts.hasPosition(me)) return dest;
    final remaining = RideFacts.remainingM(
      lat: me.lat,
      lng: me.lng,
      line: convoy.routeLine,
      destLat: convoy.destinationLat,
      destLng: convoy.destinationLng,
    );
    if (remaining == null) return dest;
    final parts = <String>[dest, StatusText.roundedDistance(remaining)];
    final eta = RideFacts.etaFor(remaining, convoy.route);
    if (eta != null) {
      // Rounded to the minute so the text does not change with every fix.
      final at = ((nowMs + eta.inMilliseconds) ~/ 60000) * 60000;
      final t = clock(at);
      if (t != null && t.isNotEmpty) parts.add('ETA $t');
    }
    return parts.join(', ');
  }

  static _Ladder _ladder(ConvoyModel convoy, String myUserId, RiderModel? me, List<TimelineEventModel> events, int nowMs) {
    final ahead = <RiderLine>[];
    final behind = <RiderLine>[];
    var others = 0;
    for (final r in convoy.riders.values) {
      if (r.userId != myUserId) others++;
    }
    if (me == null || !RideFacts.hasPosition(me)) return _Ladder(const [], const [], others);
    final route = convoy.routeLine;
    final myAlong = route.length >= 2 ? GeoMath.alongRoute(me.lat, me.lng, route) : null;
    final useHeading = myAlong == null && me.speedKmh >= NotifConstants.headingMinKmh;
    for (final r in convoy.riders.values) {
      if (r.userId == myUserId || !RideFacts.hasPosition(r)) continue;
      var dist = GeoMath.haversine(me.lat, me.lng, r.lat, r.lng);
      bool? side;
      if (myAlong != null) {
        final along = GeoMath.alongRoute(r.lat, r.lng, route);
        if (along != null) {
          final diff = along.along - myAlong.along;
          if (diff.abs() > NotifConstants.sameSpotM) {
            side = diff > 0;
            dist = diff.abs();
          }
        }
      } else if (useHeading) {
        final off = _angleDiff(Bearing.degrees(me.lat, me.lng, r.lat, r.lng), me.heading);
        if (off <= 80) side = true;
        if (off >= 100) side = false;
      }
      final stopped = _stoppedFor(convoy, r, events, nowMs);
      final flag = StatusText.flagFor(StatusMember(
        name: r.name,
        distanceM: dist,
        ahead: side,
        speedKmh: r.speedKmh,
        sinceUpdate: Duration(milliseconds: (nowMs - r.lastSeenEpochMs).clamp(0, 1 << 40).toInt()),
        stoppedFor: stopped,
      ));
      final line = RiderLine(
        name: StatusText.shortName(r.name.isEmpty ? 'Rider' : r.name),
        distanceM: dist,
        ahead: side == true,
        flag: flag.isEmpty ? null : flag,
        sideKnown: side != null,
      );
      (side == true ? ahead : behind).add(line);
    }
    int byDistance(RiderLine a, RiderLine b) {
      final c = a.distanceM.compareTo(b.distanceM);
      return c != 0 ? c : a.name.compareTo(b.name);
    }

    ahead.sort(byDistance);
    behind.sort(byDistance);
    return _Ladder(
      ahead.take(NotifConstants.ladderPerSide).toList(),
      behind.take(NotifConstants.ladderPerSide).toList(),
      others,
    );
  }

  static Duration? _stoppedFor(ConvoyModel convoy, RiderModel r, List<TimelineEventModel> events, int nowMs) {
    for (final e in events) {
      if (e.open && e.type == 'STOPPED' && e.userId == r.userId) return e.durationAt(nowMs);
    }
    if (r.stoppedSince > 0 && r.speedKmh < 3 && nowMs - r.stoppedSince >= convoy.stopThresholdSeconds * 1000) {
      return Duration(milliseconds: nowMs - r.stoppedSince);
    }
    return null;
  }

  /// "Arjun 1.2 km ahead, Kiran 3.4 km behind" (nearest on each side).
  static String _ladderSummary(List<RiderLine> ahead, List<RiderLine> behind) {
    final parts = <String>[
      if (ahead.isNotEmpty) '${ahead.first.name} ${ahead.first.detail}',
      if (behind.isNotEmpty) '${behind.first.name} ${behind.first.detail}',
    ];
    return parts.join(', ');
  }

  /// The worst open group warning, else "All 6 riders together".
  static String _rideStatus(ConvoyModel convoy, String myUserId, RiderModel? me, List<TimelineEventModel> events, int nowMs) {
    var rank = 0;
    var text = '';
    var at = 0;
    void consider(int r, String t, int when) {
      if (r > rank || (r == rank && when < at)) {
        rank = r;
        text = t;
        at = when;
      }
    }

    for (final e in events) {
      if (!e.open || e.userId == null || e.userId == myUserId) continue;
      final who = _first(e.userName.isEmpty ? (convoy.riders[e.userId]?.name ?? '') : e.userName);
      final dur = e.durationAt(nowMs);
      switch (e.type) {
        case 'OFFLINE':
          if (e.data['escalated'] == true) {
            consider(5, 'No signal from $who for ${TimelineText.duration(dur)}', e.startedAt);
          } else if (dur >= NotifConstants.noSignalAfter) {
            consider(1, 'No signal from $who for ${TimelineText.duration(dur)}', e.startedAt);
          }
          break;
        case 'SEPARATED':
          final m = e.dataNum('distanceM') ?? e.dataNum('maxDistanceM');
          consider(4, m == null ? '$who is away from the group' : '$who is ${TimelineText.distance(m)} from the group', e.startedAt);
          break;
        case 'POSSIBLE_INCIDENT':
          consider(4, '$who stopped suddenly', e.startedAt);
          break;
        case 'STOPPED':
          consider(2, '$who stopped ${TimelineText.duration(dur)}', e.startedAt);
          break;
        default:
          break;
      }
    }
    // "Wait for me" requests of the last 2 minutes (same window as the ride screen).
    var waitAt = 0;
    String? waitName;
    convoy.waitRequests.forEach((name, t) {
      if (nowMs - t < 120000 && t > waitAt) {
        waitAt = t;
        waitName = name;
      }
    });
    final wn = waitName;
    if (wn != null) {
      // My own request (from the notification's Wait for me) confirms the press.
      final mine = me != null && wn == me.name;
      consider(3, mine ? 'You asked the group to wait' : '${_first(wn)} asked the group to wait', waitAt);
    }
    if (rank > 0) return text;
    final n = convoy.riders.length;
    if (n <= 1) return 'Waiting for your group to join';
    return 'All $n riders together';
  }

  // ------------------------------------------------------------ helpers

  static double? _distanceTo(RiderModel? me, double lat, double lng) {
    if (me == null || !RideFacts.hasPosition(me) || (lat == 0 && lng == 0)) return null;
    return GeoMath.haversine(me.lat, me.lng, lat, lng);
  }

  /// "4.8 km behind you", "1.6 km ahead", "1.8 km north-east of you", '' when unknown.
  static String _whereFromMe(ConvoyModel convoy, RiderModel? me, double lat, double lng) {
    if (me == null || !RideFacts.hasPosition(me) || (lat == 0 && lng == 0)) return '';
    final d = Relation.alongDelta(myLat: me.lat, myLng: me.lng, lat: lat, lng: lng, route: convoy.routeLine);
    if (d != null) {
      if (d >= -NotifConstants.sameSpotM) return '${StatusText.roundedDistance(d < 0 ? 0.0 : d)} ahead';
      return '${StatusText.roundedDistance(-d)} behind you';
    }
    final m = GeoMath.haversine(me.lat, me.lng, lat, lng);
    return '${StatusText.roundedDistance(m)} ${Bearing.compassWord(Bearing.degrees(me.lat, me.lng, lat, lng))} of you';
  }

  static double _angleDiff(double a, double b) {
    final d = ((a - b) % 360 + 360) % 360;
    return d > 180 ? 360 - d : d;
  }

  static int _minutes(int seconds) {
    final m = (seconds / 60).round();
    return m < 1 ? 1 : m;
  }

  static String _first(String name) {
    final t = name.trim();
    if (t.isEmpty) return 'A rider';
    return StatusText.shortName(t);
  }

  static String _cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

class _Ladder {
  final List<RiderLine> ahead;
  final List<RiderLine> behind;
  final int othersCount;
  const _Ladder(this.ahead, this.behind, this.othersCount);
}
