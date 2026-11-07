// 3.55 group safety on the phone (docs/features_355/group_safety.md). Every decision is made
// here, from what the phone already has (the riders' relayed positions, its own fixes, the cached
// map places); the gateway only relays (CHECK_IN, BUDDY_PING), stores (buddies, the stretch
// setting, anonymous hard-brake cells) and fans out:
//  * missing-rider check (switch 'missingRiderCheck'): "Are you OK? The group is moving on";
//  * group stretch alert (switch 'stretchAlert'): the lead hears "Group spread 4 km, slow down";
//  * smart regroup point (switch 'regroupSuggest'): a fuel / food / rest stop ahead in that card;
//  * group break planner (switch 'groupBreak'): fatigue LEVEL 0..3 only, the lead sees a count;
//  * buddy pairs (switch 'buddyPairs'): "Check on Kiran", one-tap "buddy ok?" ping;
//  * risky-stretch heads-up (switch 'riskyStretch'): anonymous hard-brake cells, k >= 10.
// Never speaks while an SOS / crash alarm is open; cards rank below SOS / crash / incidents in the
// cockpit (group safety priority) and ask for taps only when the rider is slow.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/places/place_poi.dart';
import '../../domain/places/poi_category.dart';
import '../../domain/ride/buddy_watch.dart';
import '../../domain/ride/group_break_planner.dart';
import '../../domain/ride/group_safety_rider.dart';
import '../../domain/ride/group_stretch.dart';
import '../../domain/ride/missing_rider_check.dart';
import '../../domain/ride/regroup_point.dart';
import '../../domain/route/route_plan.dart';
import '../../domain/safety/risky_stretch.dart';
import '../../domain/tracking/geo_math.dart';
import '../../domain/tracking/track_point.dart';
import '../models/convoy_model.dart';
import '../models/rider_model.dart';
import '../models/safety_wire.dart';
import 'api_client.dart';
import 'convoy_service.dart';
import 'geo_service.dart';
import 'realtime_service.dart';
import 'timeline_service.dart';

/// Which card a [GroupSafetyNotice] is.
enum GroupSafetyKind { missingRider, buddyAsked, buddyCheck, buddyOk, stretch, groupBreak, riskyStretch }

/// One card for the cockpit alert slot.
class GroupSafetyNotice {
  final String key;
  final GroupSafetyKind kind;
  final String title;
  final String message;

  /// Amber (important) or plain (normal).
  final bool important;
  final RegroupSuggestion? suggestion;
  final String? userId;
  final String? phone;

  const GroupSafetyNotice({
    required this.key,
    required this.kind,
    required this.title,
    this.message = '',
    this.important = false,
    this.suggestion,
    this.userId,
    this.phone,
  });
}

class GroupSafetyService extends ChangeNotifier {
  GroupSafetyService(this._convoys, this._rt, this._api, {this.timeline, this.places, int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _convoys.addListener(_onConvoys);
    _events = _rt.events.listen(_onEvent);
    _fixSub = _convoys.myFixes.listen((p) => _lastFix = p);
    // Only the level 0..3 goes into the rider telemetry (and only while the switch is on).
    _convoys.fatigueLevel = () => _on('groupBreak') && fatigueScore != null ? myFatigueLevel : null;
    _onConvoys();
  }

  final ConvoyService _convoys;
  final RealtimeService _rt;
  final ApiClient _api;
  final TimelineService? timeline;

  /// The cached map places (the corridor along the route); `all` is read for regroup points.
  final Iterable<PlacePoi> Function()? places;
  final int Function() _clock;

  /// This phone's fatigue score 0-100 (SafetyService); null = not available.
  int? Function()? fatigueScore;

  /// Hard brakes counted so far this ride (SafetyService.hardStops).
  int Function()? hardStops;

  /// A crash alarm (or anything like it) is open on this phone.
  bool Function()? alarmOpen;

  /// Speaks a line (important tier).
  void Function(String line, String key)? speaker;

  /// Admin switches; null = on.
  bool Function(String id)? featureOn;

  static const Duration tickEvery = Duration(seconds: 5);
  static const Duration riskRefreshEvery = Duration(minutes: 30);

  StreamSubscription<Map<String, dynamic>>? _events;
  StreamSubscription<TrackPoint>? _fixSub;
  Timer? _timer;
  String? _rideId;
  TrackPoint? _lastFix;
  bool _busyTick = false;

  final Map<String, int> _fatigue = {};
  Map<String, String> _buddies = const {};

  final MissingRiderCheck _missing = MissingRiderCheck();
  final StretchMonitor _stretch = StretchMonitor();
  final GroupBreakPlanner _break = GroupBreakPlanner();
  final BuddyWatch _buddyWatch = BuddyWatch();
  final BrakeReportQueue _brakes = BrakeReportQueue();
  final RiskyStretchAnnouncer _risk = RiskyStretchAnnouncer();
  int _brakesSeen = 0;
  int _riskFetchedAt = 0;
  bool _riskFetching = false;

  GroupSafetyNotice? _missingNotice;
  GroupSafetyNotice? _askedNotice;
  GroupSafetyNotice? _buddyNotice;
  GroupSafetyNotice? _buddyOkNotice;
  GroupSafetyNotice? _stretchNotice;
  GroupSafetyNotice? _breakNotice;
  GroupSafetyNotice? _riskNotice;
  int _askedUntil = 0, _buddyOkUntil = 0, _riskUntil = 0;

  bool _on(String id) => featureOn?.call(id) ?? true;
  int get _now => _clock();

  /// This phone's level 0..3.
  int get myFatigueLevel => FatigueBuckets.bucketOf(fatigueScore?.call());

  /// The buddy this phone watches (userId), if any.
  String? get myBuddyId {
    final me = _convoys.myUserId;
    return me == null ? null : _buddies[me];
  }

  /// "Kiran" for the ride sheet, or null.
  String? get myBuddyName {
    final id = myBuddyId;
    final r = id == null ? null : _convoys.activeConvoy?.riders[id];
    return r == null ? null : _riderOf(r).firstName;
  }

  Map<String, String> get buddies => _buddies;

  /// My speed (km/h) from my own rider record; the cards offer taps only below [tapBelowKmh].
  double get mySpeedKmh {
    final me = _convoys.myUserId == null ? null : _convoys.activeConvoy?.riders[_convoys.myUserId];
    return me?.speedKmh ?? 0;
  }

  static const double tapBelowKmh = 15;
  bool get canTap => mySpeedKmh < tapBelowKmh;

  /// Cards for the cockpit, most urgent first.
  List<GroupSafetyNotice> get notices {
    final now = _now;
    return [
      ?_missingNotice,
      if (_askedNotice != null && now < _askedUntil) _askedNotice!,
      ?_buddyNotice,
      if (_buddyOkNotice != null && now < _buddyOkUntil) _buddyOkNotice!,
      ?_stretchNotice,
      ?_breakNotice,
      if (_riskNotice != null && now < _riskUntil) _riskNotice!,
    ];
  }

  bool get _emergencyOpen {
    final c = _convoys.activeConvoy;
    return (alarmOpen?.call() ?? false) || _convoys.pendingSos != null || (c?.activeAlerts.any((a) => !a.resolved) ?? false);
  }

  void _say(String line, String key) {
    if (_emergencyOpen) return; // never over an SOS / crash alarm
    speaker?.call(line, key);
  }

  // ---------------------------------------------------------------- ride lifecycle
  void _onConvoys() {
    final c = _convoys.activeConvoy;
    final live = c != null && c.tripStatus != 'ENDED';
    final id = live ? c.groupId : null;
    if (id == _rideId) return;
    final had = _rideId != null;
    _rideId = id;
    if (had) _flushBrakes();
    _resetRide();
    if (id != null) {
      _timer ??= Timer.periodic(tickEvery, (_) => tick());
    } else {
      _timer?.cancel();
      _timer = null;
    }
    notifyListeners();
  }

  void _resetRide() {
    _fatigue.clear();
    _buddies = const {};
    _missing.reset();
    _stretch.reset();
    _break.reset();
    _buddyWatch.reset();
    _risk.reset();
    _brakesSeen = hardStops?.call() ?? 0;
    _riskFetchedAt = 0;
    _missingNotice = _askedNotice = _buddyNotice = _buddyOkNotice = _stretchNotice = _breakNotice = _riskNotice = null;
  }

  // ---------------------------------------------------------------- socket
  void _onEvent(Map<String, dynamic> e) {
    final type = e['type'];
    switch (type) {
      case 'SNAPSHOT':
        final c = e['convoy'];
        if (c is Map) {
          _readBuddies(c['buddies']);
          final riders = c['riders'];
          if (riders is Map) {
            for (final r in riders.values) {
              if (r is Map) _readFatigue(r);
            }
          }
        }
        break;
      case 'RIDER_UPDATE':
        if (e['rider'] is Map) _readFatigue(e['rider'] as Map);
        break;
      case 'RIDER_LEFT':
        _fatigue.remove(e['userId']?.toString());
        break;
      case 'BUDDIES':
        _readBuddies(e['buddies']);
        notifyListeners();
        break;
      case 'BUDDY_PING':
        _onBuddyPing(e);
        break;
    }
  }

  void _readFatigue(Map r) {
    final id = r['userId']?.toString();
    final f = r['fatigueLevel'];
    if (id == null) return;
    if (f is num && f.isFinite) {
      _fatigue[id] = f.round().clamp(0, 3);
    } else {
      _fatigue.remove(id);
    }
  }

  void _readBuddies(Object? b) {
    if (b is! Map) return;
    final out = <String, String>{};
    for (final e in b.entries) {
      final k = e.key?.toString(), v = e.value?.toString();
      if (k != null && v != null && k.isNotEmpty && v.isNotEmpty) out[k] = v;
    }
    if (mapEquals(out, _buddies)) return;
    _buddies = Map.unmodifiable(out);
    _buddyWatch.reset();
    _buddyNotice = null;
  }

  void _onBuddyPing(Map<String, dynamic> e) {
    if (!_on('buddyPairs')) return;
    final from = e['fromUserId']?.toString() ?? '';
    final name = (e['fromName']?.toString() ?? '').trim().split(RegExp(r'\s+')).first;
    final who = name.isEmpty ? 'Your buddy' : name;
    final now = _now;
    if (e['kind'] == 'OK') {
      if (from == myBuddyId) _buddyWatch.snooze(now);
      _buddyNotice = null;
      _buddyOkNotice = GroupSafetyNotice(key: 'BUDDY_OK:$from:$now', kind: GroupSafetyKind.buddyOk, title: '$who is OK', userId: from);
      _buddyOkUntil = now + 30000;
    } else {
      _askedNotice = GroupSafetyNotice(
        key: 'BUDDY_ASKED:$from:$now',
        kind: GroupSafetyKind.buddyAsked,
        title: 'Your buddy is checking on you',
        message: "$who wants to know you are fine. Tap I'm OK.",
        important: true,
        userId: from,
      );
      _askedUntil = now + 120000;
      _say("Your buddy is checking on you. Tap I'm OK.", 'BUDDY_ASKED:$from');
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- actions
  /// Missing-rider card: "I'm OK" (the lead sees why on my rider card).
  void answerOk() => _answer('CUSTOM', "I'm OK");

  /// "Waiting for a reason": FUELING, PHOTO_STOP, REST_BREAK...
  void answerWaiting(String reason) => _answer(reason, '');

  /// "Need help": the group is asked to wait and my card says so (SOS stays one tap away).
  void answerNeedHelp() {
    final me = _myRider;
    if (me != null) _convoys.requestWait(me.name);
    _answer('CUSTOM', 'Needs help');
  }

  void _answer(String reason, String message) {
    final uid = _convoys.myUserId;
    final noReplySent = _missing.phase == MissingRiderPhase.noReplySent;
    _missing.answered(_now);
    _missingNotice = null;
    if (uid != null) _convoys.updateStatusReason(userId: uid, reason: reason, message: message);
    // Closes the "No reply" entry the lead got (existing check-in path).
    if (noReplySent) _convoys.sendCheckIn(CheckInResult.ok);
    notifyListeners();
  }

  /// Someone asked "buddy ok?": answer I'm OK to them only.
  void answerBuddyOk() {
    final to = _askedNotice?.userId;
    _askedNotice = null;
    if (to != null) _rt.send({'type': 'BUDDY_PING', 'userId': to, 'kind': 'OK'});
    notifyListeners();
  }

  /// One-tap "buddy ok?" to my buddy.
  bool checkBuddy() {
    final id = myBuddyId;
    if (id == null || !_on('buddyPairs')) return false;
    return _rt.send({'type': 'BUDDY_PING', 'userId': id, 'kind': 'CHECK'});
  }

  /// "They're fine".
  void buddyFine() {
    _buddyWatch.snooze(_now);
    _buddyNotice = null;
    notifyListeners();
  }

  /// "Ask group to wait".
  void askGroupToWait() {
    final me = _myRider;
    if (me != null) _convoys.requestWait(me.name);
    _buddyNotice = null;
    _buddyWatch.snooze(_now);
    notifyListeners();
  }

  /// Lead: "Assign buddies" (the gateway pairs everyone deterministically).
  bool assignBuddies() => _rt.send({'type': 'BUDDY_ASSIGN'});

  /// Lead: "Set regroup point" from the stretch card (the existing meeting-point flow).
  bool setRegroupPoint(RegroupSuggestion s) {
    final c = _convoys.activeConvoy;
    if (c == null || !_convoys.canEditRoute) return false;
    final placement = RoutePlan.meetingPlacement(c, lat: s.lat, lng: s.lng);
    final ok = _convoys.addMeetingPoint(
      PickedPlace(lat: s.lat, lng: s.lng, name: s.name, category: RoutePlan.meetingCategory),
      replaceStopId: placement.replaces?.stopId,
    );
    if (ok) {
      _stretchNotice = null;
      notifyListeners();
    }
    return ok;
  }

  /// Lead: "Plan stop" from the break card: the place is added as a planned stop.
  bool planBreakStop(RegroupSuggestion s) {
    if (!_convoys.canEditRoute) return false;
    final cat = switch (s.category) { PoiCategory.fuel => 'FUEL', PoiCategory.food => 'FOOD', _ => 'REST' };
    final ok = _convoys.addStop(PickedPlace(lat: s.lat, lng: s.lng, name: s.name, category: cat, plannedDwellMin: 15));
    dismissBreak();
    return ok;
  }

  void dismissStretch() {
    _stretchNotice = null;
    notifyListeners();
  }

  void dismissBreak() {
    _break.done(_now);
    _breakNotice = null;
    notifyListeners();
  }

  void dismiss(GroupSafetyNotice n) {
    switch (n.kind) {
      case GroupSafetyKind.missingRider:
        answerOk();
      case GroupSafetyKind.buddyAsked:
        _askedNotice = null;
      case GroupSafetyKind.buddyCheck:
        buddyFine();
      case GroupSafetyKind.buddyOk:
        _buddyOkNotice = null;
      case GroupSafetyKind.stretch:
        _stretchNotice = null;
      case GroupSafetyKind.groupBreak:
        dismissBreak();
      case GroupSafetyKind.riskyStretch:
        _riskNotice = null;
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- the checks
  RiderModel? get _myRider {
    final uid = _convoys.myUserId;
    return uid == null ? null : _convoys.activeConvoy?.riders[uid];
  }

  GroupSafetyRider _riderOf(RiderModel r, {int? lastSeenMs, int? fatigue}) => GroupSafetyRider(
        userId: r.userId,
        name: r.name,
        lat: r.lat,
        lng: r.lng,
        speedKmh: r.speedKmh,
        lastSeenMs: lastSeenMs ?? r.lastSeenEpochMs,
        statusReason: r.statusReason,
        fatigueLevel: fatigue ?? _fatigue[r.userId] ?? 0,
      );

  /// Runs the checks once (every [tickEvery] during a ride; public for tests).
  @visibleForTesting
  Future<void> tick() async {
    if (_busyTick) return;
    _busyTick = true;
    try {
      final c = _convoys.activeConvoy;
      final uid = _convoys.myUserId;
      final meModel = uid == null ? null : c?.riders[uid];
      if (c == null || meModel == null || c.tripStatus == 'ENDED') return;
      final now = _now;
      final emergency = _emergencyOpen;
      final fix = _lastFix;
      final me = _riderOf(meModel, lastSeenMs: fix?.ts ?? meModel.lastSeenEpochMs, fatigue: myFatigueLevel);
      final others = [for (final r in c.riders.values) if (r.userId != uid) _riderOf(r)];
      final everyone = [me, ...others];
      final route = c.routeLine;
      var changed = false;

      changed |= _checkMissing(c, now, me, others, emergency);
      final lead = c.ridingLeadId == uid || c.createdByUserId == uid;
      GroupSpread? spread;
      if (lead && c.hasGroupFeatures && (_on('stretchAlert') || _on('groupBreak'))) {
        spread = GroupSpread.compute(everyone, route, now);
      }
      changed |= _checkStretch(c, now, lead, spread, route);
      changed |= _checkBreak(c, now, lead, everyone, spread, me, route);
      changed |= _checkBuddy(c, now, me, route, emergency);
      changed |= _checkBrakesAndRisk(c, now, meModel, route);
      // Timed cards that ran out.
      if (_askedNotice != null && now >= _askedUntil) { _askedNotice = null; changed = true; }
      if (_buddyOkNotice != null && now >= _buddyOkUntil) { _buddyOkNotice = null; changed = true; }
      if (_riskNotice != null && now >= _riskUntil) { _riskNotice = null; changed = true; }
      if (changed) notifyListeners();
    } finally {
      _busyTick = false;
    }
  }

  bool _checkMissing(ConvoyModel c, int now, GroupSafetyRider me, List<GroupSafetyRider> others, bool emergency) {
    if (!_on('missingRiderCheck') || !c.hasGroupFeatures || others.isEmpty) {
      if (_missingNotice == null) return false;
      _missingNotice = null;
      _missing.reset();
      return true;
    }
    final action = _missing.evaluate(nowMs: now, me: me, others: others, emergencyOpen: emergency, lastServerAlertMs: _lastServerAlertAboutMe(now));
    switch (action) {
      case MissingRiderAction.none:
        return false;
      case MissingRiderAction.ask:
        _missingNotice = const GroupSafetyNotice(
          key: 'MISSING_RIDER',
          kind: GroupSafetyKind.missingRider,
          title: 'Are you OK? The group is moving on',
          message: "Tap I'm OK, or say why you stopped. Your lead is told if you don't answer.",
          important: true,
        );
        _say('Are you OK? The group is moving on.', 'MISSING_RIDER:$now');
        return true;
      case MissingRiderAction.sendNoReply:
        final away = _missing.nearestMovingM;
        _convoys.sendCheckIn(CheckInResult.noReply, awayM: away, context: CheckInContext.missingRider);
        _missingNotice = _noReplyNotice;
        return true;
      case MissingRiderAction.noReplySuppressed:
        _missingNotice = _noReplyNotice;
        return true;
      case MissingRiderAction.clear:
        _missingNotice = null;
        return true;
    }
  }

  static const GroupSafetyNotice _noReplyNotice = GroupSafetyNotice(
    key: 'MISSING_RIDER:TOLD',
    kind: GroupSafetyKind.missingRider,
    title: 'Are you OK? The group is moving on',
    message: "Your lead was told. Tap I'm OK if you are fine.",
    important: true,
  );

  /// When the server's own rules last told the lead about me (STOPPED after 20 min, SEPARATED,
  /// POSSIBLE_INCIDENT, NO_REPLY, BEHIND_SWEEPER), or null.
  int? _lastServerAlertAboutMe(int now) {
    final uid = _convoys.myUserId;
    final events = timeline?.events;
    if (uid == null || events == null) return null;
    int? last;
    for (final e in events) {
      if (e.userId != uid) continue;
      int? at;
      switch (e.type) {
        case 'STOPPED':
          if (e.open && now - e.startedAt >= const Duration(minutes: 20).inMilliseconds) at = now;
        case 'SEPARATED' || 'POSSIBLE_INCIDENT' || 'NO_REPLY' || 'BEHIND_SWEEPER':
          at = e.open ? now : (e.endedAt ?? e.startedAt);
      }
      if (at != null && (last == null || at > last)) last = at;
    }
    return last;
  }

  bool _checkStretch(ConvoyModel c, int now, bool lead, GroupSpread? spread, List<(double, double)> route) {
    if (!lead || !_on('stretchAlert') || !c.hasGroupFeatures) {
      if (_stretchNotice == null) return false;
      _stretchNotice = null;
      _stretch.reset();
      return true;
    }
    final threshold = c.featurePolicy.stretchAlertKm * 1000.0;
    final ev = _stretch.update(nowMs: now, spreadM: spread?.spreadM, thresholdM: threshold);
    switch (ev) {
      case StretchEvent.none:
        return false;
      case StretchEvent.clear:
        final had = _stretchNotice != null;
        _stretchNotice = null;
        return had;
      case StretchEvent.alert || StretchEvent.repeat:
        final s = spread!;
        final me = _convoys.myUserId;
        final leadAlong = s.alongM[me] ?? s.frontAlongM;
        final pick = _on('regroupSuggest') ? _pick(route, s.lastAlongM, leadAlong) : null;
        _stretchNotice = GroupSafetyNotice(
          key: 'STRETCH:$now',
          kind: GroupSafetyKind.stretch,
          title: StretchMonitor.title(s.spreadM),
          message: pick?.text ?? 'The last rider is ${_km(s.spreadM)} behind the front.',
          important: true,
          suggestion: pick,
        );
        _say(StretchMonitor.spoken(s.spreadM), 'STRETCH:$now');
        return true;
    }
  }

  bool _checkBreak(ConvoyModel c, int now, bool lead, List<GroupSafetyRider> everyone, GroupSpread? spread, GroupSafetyRider me,
      List<(double, double)> route) {
    if (!lead || !_on('groupBreak') || !c.hasGroupFeatures) {
      if (_breakNotice == null) return false;
      _breakNotice = null;
      return true;
    }
    final levels = [for (final r in everyone) if (r.userId == me.userId || r.isFresh(now)) r.fatigueLevel];
    final show = _break.update(nowMs: now, levels: levels);
    if (!_break.showing && _breakNotice != null) {
      _breakNotice = null;
      return true;
    }
    if (!show) return false;
    RegroupSuggestion? pick;
    if (_on('regroupSuggest')) {
      if (spread != null) {
        pick = _pick(route, spread.lastAlongM, spread.alongM[me.userId] ?? spread.frontAlongM);
      } else if (route.length >= 2 && me.hasPosition) {
        final a = GeoMath.alongRoute(me.lat, me.lng, route);
        if (a != null && a.offRoute <= GroupSpread.onRouteM) pick = _pick(route, a.along, a.along);
      }
    }
    _breakNotice = GroupSafetyNotice(
      key: 'GROUP_BREAK:$now',
      kind: GroupSafetyKind.groupBreak,
      title: GroupBreakPlanner.title,
      message: [GroupBreakPlanner.message(_break.tiredCount), if (pick != null) 'Stop at ${pick.name}, ${_km(pick.aheadOfLeadM)} ahead.'].join(' '),
      suggestion: pick,
    );
    _say('Several riders need a break.', 'GROUP_BREAK:$now');
    return true;
  }

  RegroupSuggestion? _pick(List<(double, double)> route, double lastAlong, double leadAlong) {
    final list = places?.call();
    if (list == null) return null;
    return RegroupPointPicker.pick(route: route, places: list, lastAlongM: lastAlong, leadAlongM: leadAlong);
  }

  bool _checkBuddy(ConvoyModel c, int now, GroupSafetyRider me, List<(double, double)> route, bool emergency) {
    final id = _buddies[me.userId];
    final buddyModel = id == null ? null : c.riders[id];
    if (!_on('buddyPairs') || buddyModel == null) {
      _buddyWatch.reset();
      if (_buddyNotice == null) return false;
      _buddyNotice = null;
      return true;
    }
    final buddy = _riderOf(buddyModel);
    final show = _buddyWatch.update(nowMs: now, me: me, buddy: buddy, route: route, emergencyOpen: emergency);
    if (!_buddyWatch.showing && _buddyNotice != null) {
      _buddyNotice = null;
      return true;
    }
    if (!show) return false;
    final name = buddy.firstName;
    _buddyNotice = GroupSafetyNotice(
      key: 'BUDDY_CHECK:${buddy.userId}:$now',
      kind: GroupSafetyKind.buddyCheck,
      title: BuddyWatch.title(name),
      message: BuddyWatch.message(_buddyWatch.trouble, name),
      important: true,
      userId: buddy.userId,
      phone: buddyModel.phone.isEmpty ? null : buddyModel.phone,
    );
    _say('Check on your buddy $name.', 'BUDDY_CHECK:${buddy.userId}');
    return true;
  }

  bool _checkBrakesAndRisk(ConvoyModel c, int now, RiderModel me, List<(double, double)> route) {
    if (!_on('riskyStretch')) return false;
    // Hard brakes since the last tick: queued at the rounded cell (the exact spot is never kept).
    final count = hardStops?.call();
    if (count != null) {
      if (count < _brakesSeen) _brakesSeen = count; // a new ride on the counter
      for (var i = _brakesSeen; i < count; i++) {
        _brakes.add(lat: me.lat, lng: me.lng, heading: me.heading, nowMs: now);
      }
      _brakesSeen = count;
    }
    if (_brakes.due(now)) _flushBrakes();
    if (!_riskFetching && (now - _riskFetchedAt >= riskRefreshEvery.inMilliseconds)) _fetchRisk(c.groupId, now);
    final cell = _risk.update(lat: me.lat, lng: me.lng, headingDeg: me.heading, speedKmh: me.speedKmh, route: route);
    if (cell == null) return false;
    _riskNotice = GroupSafetyNotice(
      key: 'RISKY:${cell.id}',
      kind: GroupSafetyKind.riskyStretch,
      title: RiskyStretchAnnouncer.title,
      message: 'Reported by many riders. Ride carefully.',
    );
    _riskUntil = now + 30000;
    _say(RiskyStretchAnnouncer.spoken, 'RISKY:${cell.id}');
    return true;
  }

  Future<void> _fetchRisk(String groupId, int now) async {
    _riskFetching = true;
    _riskFetchedAt = now;
    try {
      final res = await _api.get('/road-risk/near?groupId=${Uri.encodeQueryComponent(groupId)}');
      if (groupId != _rideId) return;
      final list = res is Map ? res['cells'] : null;
      if (list is List) _risk.setCells([for (final j in list) ?RiskCell.fromJson(j)]);
    } catch (_) {
      // Offline or switched off: try again at the next refresh.
    } finally {
      _riskFetching = false;
    }
  }

  void _flushBrakes() {
    if (_brakes.isEmpty || !_on('riskyStretch')) return;
    final body = _brakes.take();
    _api.post('/road-risk/brakes', body).catchError((Object e) {
      final code = e is ApiException ? e.statusCode : 0;
      if (code == 0 || code >= 500 || code == 429) _brakes.restore(body, _now); // kept for the next try
      return null;
    }).ignore();
  }

  static String _km(double m) {
    if (m < 1000) return '${(m / 50).round() * 50} m';
    final s = (m / 1000).toStringAsFixed(1);
    return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s} km';
  }

  @override
  void dispose() {
    _flushBrakes();
    _timer?.cancel();
    _events?.cancel();
    _fixSub?.cancel();
    _convoys.removeListener(_onConvoys);
    if (_convoys.fatigueLevel != null) _convoys.fatigueLevel = null;
    super.dispose();
  }
}
