import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/public_ride_models.dart';
import 'realtime_service.dart';

/// Public ride, safe contact and road warnings (gateway feature `pubride1`). Memory only, except
/// my own choices (Show public rides near me, radius, road warnings), which stay on the phone and
/// go to the gateway with every JOIN. Everything else is cleared when I leave the ride.
///
/// Every plan has it (Community too): it is a safety feature, not group chat.
class PublicRideService extends ChangeNotifier {
  PublicRideService(this._rt, {int Function()? clock, SharedPreferences? prefs})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _store = prefs {
    _sub = _rt.events.listen(_onEvent);
    _loadPrefs();
  }

  static const String prefsKey = 'coroute_public_ride_prefs';

  final RealtimeService _rt;
  final int Function() _clock;
  SharedPreferences? _store;
  StreamSubscription<Map<String, dynamic>>? _sub;

  /// Speaks a line once per key (set by main.dart: the voice service, important tier).
  void Function(String line, String key)? speaker;

  /// True while my own group has an emergency open (set by main.dart): warnings stay silent then.
  bool Function()? emergencyActive;

  String? _groupId;
  PublicRideSettings _settings = PublicRideSettings.off;
  PublicRidePrefs _prefs = const PublicRidePrefs();
  List<PublicRideMarker> _rides = const [];
  int _ridesAt = 0;
  final Map<String, ContactRequest> _incoming = {};
  final Map<String, List<ContactLine>> _incomingLines = {};
  final Map<String, OutgoingRequest> _outgoing = {};
  final Map<String, ContactChannel> _channels = {};
  final Map<String, RoadWarning> _warnings = {};
  final Set<String> _spoken = {};
  final Set<String> _voted = {};
  int? _suspendedUntil;
  String? _notice;
  int _noticeSeq = 0;

  /// The connected gateway has public ride, and the admin has not switched it off (3.55).
  bool get available => _rt.supports(PublicRideWire.feature) && (featureOn?.call('publicRide') ?? true);

  /// 3.55 admin feature switches (set in main.dart to FeatureFlagsService.on). Null = on.
  bool Function(String id)? featureOn;

  /// A switch changed: the cards, the HUD and the map markers re-read [available].
  void featureSwitchesChanged() => notifyListeners();

  PublicRideSettings get settings => _settings;
  PublicRidePrefs get prefs => _prefs;

  /// The radius I see with: my public ride's, else "Show public rides near me", else 0 (I see none).
  int get viewRadiusKm => _settings.on ? _settings.radiusKm : (_prefs.showNearby ? _prefs.radiusKm : 0);

  /// Public rides near me (both radii checked by the server; mine applied again here).
  List<PublicRideMarker> get rides {
    final r = viewRadiusKm;
    if (!available || r == 0) return const [];
    // A list that stopped coming (no signal) is not shown for ever.
    if (_clock() - _ridesAt > 3 * 60000) return const [];
    return PublicRideFilter.withinRadius(_rides, r);
  }

  /// Requests to my ride waiting for my answer, newest first.
  List<ContactRequest> get incoming {
    final now = _clock();
    final l = _incoming.values.where((q) => q.expiresAt > now).toList()..sort((a, b) => b.at.compareTo(a.at));
    return List.unmodifiable(l);
  }

  List<ContactLine> linesOf(String requestId) => List.unmodifiable(_incomingLines[requestId] ?? const []);

  List<OutgoingRequest> get outgoing {
    final l = _outgoing.values.toList()..sort((a, b) => b.at.compareTo(a.at));
    return List.unmodifiable(l);
  }

  List<ContactChannel> get channels {
    final now = _clock();
    return List.unmodifiable(_channels.values.where((c) => c.isOpen(now)));
  }

  ContactChannel? channel(String id) => _channels[id];

  /// Road warnings ahead of me, nearest first. Empty while neither Public ride nor road warnings is on.
  List<RoadWarning> get warnings {
    if (!roadWarningsOn) return const [];
    return RoadWarningPolicy.visible(_warnings.values, _clock());
  }

  /// I can send and receive road warnings in this ride.
  bool get roadWarningsOn => available && (_settings.on || _prefs.roadWarnings);

  bool hasVoted(String warnId) => _voted.contains(warnId);

  int? get suspendedUntil => _suspendedUntil;

  /// The latest refusal or confirmation worth a snackbar, with a sequence number that changes each time.
  String? get notice => _notice;
  int get noticeSeq => _noticeSeq;

  // ---------------------------------------------------------------- prefs
  Future<void> _loadPrefs() async {
    try {
      _store ??= await SharedPreferences.getInstance();
      final raw = _store!.getString(prefsKey);
      if (raw != null) {
        _prefs = PublicRidePrefs.fromJson(jsonDecode(raw));
        notifyListeners();
      }
    } catch (_) {/* defaults */}
  }

  Future<void> setPrefs(PublicRidePrefs p) async {
    _prefs = p;
    notifyListeners();
    _sendPrefs();
    try {
      _store ??= await SharedPreferences.getInstance();
      await _store!.setString(prefsKey, jsonEncode(p.toJson()));
    } catch (_) {/* stays for this session */}
  }

  bool _sendPrefs() {
    if (!available || _groupId == null) return false;
    return _rt.send({'type': 'PR_PREFS', ..._prefs.toJson()});
  }

  // ---------------------------------------------------------------- host settings
  /// Host only (the server refuses anyone else). False when it could not be sent now.
  bool setRideSettings(PublicRideSettings next) {
    if (!available || _groupId == null) return false;
    return _rt.send({'type': 'CONFIG', 'publicRide': next.toJson()});
  }

  // ---------------------------------------------------------------- contact
  /// First contact from a public-ride marker (a quick line plus at most 80 characters).
  bool contact(PublicRideMarker ride, ContactKind kind, String quick, {String text = ''}) {
    if (!available || ContactText.problem(text) != null) return false;
    final ok = _rt.send({'type': 'PR_CONTACT', 'rideId': ride.rideId, 'kind': kind.wire, 'quick': quick, if (text.trim().isNotEmpty) 'text': text.trim()});
    if (ok) {
      _pendingRideLabel = ride.label;
      _pendingKind = kind;
      _pendingQuick = quick;
    }
    return ok;
  }

  String? _pendingRideLabel;
  ContactKind? _pendingKind;
  String? _pendingQuick;

  bool reply(String requestId, String action, {String? quick, String text = '', String? reason, bool block = false}) {
    if (!available) return false;
    final ok = _rt.send({
      'type': 'PR_REPLY',
      'requestId': requestId,
      'action': action,
      'quick': ?quick,
      if (text.trim().isNotEmpty) 'text': text.trim(),
      'reason': ?reason,
      if (block) 'block': true,
    });
    if (ok && action == 'QUICK' && quick != null) {
      (_incomingLines[requestId] ??= []).add(ContactLine(mine: true, quickText: QuickLines.reply[quick] ?? '', text: text.trim(), at: _clock()));
    }
    if (ok && action != 'QUICK') {
      _incoming.remove(requestId);
      _incomingLines.remove(requestId);
    }
    if (ok) notifyListeners();
    return ok;
  }

  bool say(String channelId, {String? quick, String text = ''}) {
    final c = _channels[channelId];
    if (!available || c == null || !c.isOpen(_clock()) || ContactText.problem(text) != null) return false;
    final ok = _rt.send({'type': 'PR_SAY', 'channelId': channelId, 'quick': ?quick, if (text.trim().isNotEmpty) 'text': text.trim()});
    if (ok) {
      _channels[channelId] = c.copyWith(lines: [...c.lines, ContactLine(mine: true, quickText: quick == null ? '' : QuickLines.textOf(quick), text: text.trim(), at: _clock())]);
      notifyListeners();
    }
    return ok;
  }

  bool shareLocation(String channelId, bool on) {
    final c = _channels[channelId];
    if (!available || c == null) return false;
    final ok = _rt.send({'type': 'PR_SHARE_LOC', 'channelId': channelId, 'on': on});
    if (ok) {
      _channels[channelId] = c.copyWith(sharingMine: on);
      notifyListeners();
    }
    return ok;
  }

  bool shareContact(String channelId) => available && _channels.containsKey(channelId) && _rt.send({'type': 'PR_SHARE_CONTACT', 'channelId': channelId});

  bool closeChannel(String channelId) {
    final c = _channels[channelId];
    if (c == null) return false;
    final ok = _rt.send({'type': 'PR_CLOSE', 'channelId': channelId});
    _channels[channelId] = c.copyWith(closed: true);
    notifyListeners();
    return ok;
  }

  /// Report a request or chat (stored with the conversation for review); optionally block too.
  bool report(String ref, String reason, {String note = '', bool block = false}) =>
      available && _rt.send({'type': 'PR_REPORT', 'ref': ref, 'reason': reason, if (note.trim().isNotEmpty) 'text': note.trim(), if (block) 'block': true});

  bool block(String ref) {
    if (!available) return false;
    final ok = _rt.send({'type': 'PR_BLOCK', 'ref': ref});
    if (ok) {
      _incoming.remove(ref);
      final c = _channels[ref];
      if (c != null) _channels[ref] = c.copyWith(closed: true);
      notifyListeners();
    }
    return ok;
  }

  // ---------------------------------------------------------------- road warnings
  bool sendRoadWarning(RoadWarningKind kind) => roadWarningsOn && _rt.send({'type': 'ROAD_WARN', 'kind': kind.wire});

  bool vote(String warnId, {required bool stillThere}) {
    if (!available || _voted.contains(warnId)) return false;
    final ok = _rt.send({'type': 'ROAD_WARN_VOTE', 'warnId': warnId, 'still': stillThere});
    if (ok) {
      _voted.add(warnId);
      if (!stillThere) _warnings.remove(warnId);
      notifyListeners();
    }
    return ok;
  }

  // ---------------------------------------------------------------- incoming
  static const Set<String> _reasons = {
    'GUEST', 'SUSPENDED', 'TEXT_NOT_ALLOWED', 'RIDE_GONE', 'OWN_RIDE', 'BUSY', 'SOS_OPEN', 'RATE', 'ALREADY_ASKED', 'REQUEST_CLOSED',
    'CHANNEL_CLOSED', 'ROAD_WARNINGS_OFF', 'NO_POSITION', 'WARN_PAUSED', 'WARN_GONE', 'NO_PHONE', 'BAD_KIND', 'BAD_QUICK', 'REF_GONE',
  };

  void _say(String text) {
    _notice = text;
    _noticeSeq++;
  }

  @visibleForTesting
  void onEvent(Map<String, dynamic> e) => _onEvent(e);

  void _onEvent(Map<String, dynamic> e) {
    final type = e['type'];
    final now = _clock();
    switch (type) {
      case 'SNAPSHOT':
        final c = e['convoy'];
        final gid = c is Map ? c['groupId']?.toString() : null;
        if (gid != _groupId) _clearRide();
        _groupId = gid;
        _settings = PublicRideSettings.fromJson(c is Map ? c['publicRide'] : null);
        _sendPrefs(); // every JOIN: the gateway may have restarted
        break;
      case 'CONFIG':
        if (e.containsKey('publicRide')) _settings = PublicRideSettings.fromJson(e['publicRide']);
        break;
      case 'LEFT':
      case 'DISSOLVED':
        _clearRide();
        _groupId = null;
        _settings = PublicRideSettings.off;
        break;
      case 'PR_PREFS_OK':
        final s = e['suspendedUntil'];
        _suspendedUntil = s is num ? s.toInt() : null;
        break;
      case 'PUBLIC_RIDES':
        final list = e['rides'];
        _rides = [for (final r in (list is List ? list : const [])) ?PublicRideMarker.fromJson(r)];
        _ridesAt = now;
        break;
      case 'PR_SENT':
        final id = e['requestId']?.toString();
        if (id != null) {
          _outgoing[id] = OutgoingRequest(
            requestId: id,
            rideLabel: _pendingRideLabel ?? 'Public ride',
            kind: _pendingKind ?? ContactKind.hi,
            quickText: _pendingQuick == null ? '' : QuickLines.forKind(_pendingKind ?? ContactKind.hi)[_pendingQuick!] ?? '',
            at: now,
          );
          _say('Sent. They see "${_outgoingLabelHint()}" only.');
        }
        break;
      case 'PR_REQUEST':
        final q = ContactRequest.fromJson(e, now: now);
        if (q == null) return;
        _incoming[q.requestId] = q;
        _incomingLines[q.requestId] = [ContactLine(mine: false, quickText: q.quickText, text: q.text, at: now)];
        break;
      case 'PR_MESSAGE':
        final ref = e['ref']?.toString() ?? '';
        final line = ContactLine(mine: false, quickText: e['quickText']?.toString() ?? '', text: e['text']?.toString() ?? '', at: now);
        final c = _channels[ref];
        if (c != null) {
          _channels[ref] = c.copyWith(lines: [...c.lines, line]);
        } else if (_outgoing[ref] != null) {
          final o = _outgoing[ref]!;
          _outgoing[ref] = o.copyWith(replies: [...o.replies, line]);
        } else {
          return;
        }
        break;
      case 'PR_UPDATE':
        final id = e['requestId']?.toString() ?? '';
        final o = _outgoing[id];
        final state = e['state'];
        if (o != null) {
          _outgoing[id] = o.copyWith(state: state == 'ACCEPTED' ? OutgoingState.accepted : OutgoingState.closed, channelId: e['channelId']?.toString());
        }
        if (state == 'CLOSED') {
          _incoming.remove(id);
          _incomingLines.remove(id);
        }
        break;
      case 'PR_CHANNEL':
        final id = e['channelId']?.toString() ?? '';
        if (id.isEmpty) return;
        if (e['state'] == 'OPEN') {
          final w = e['with'];
          final exp = e['expiresAt'];
          final reqId = e['requestId']?.toString();
          final seed = reqId == null ? const <ContactLine>[] : [...?_incomingLines[reqId], ...?_outgoing[reqId]?.replies];
          _channels[id] = ContactChannel(
            channelId: id,
            withLabel: w is Map && (w['label']?.toString() ?? '').isNotEmpty ? w['label'].toString() : 'Rider',
            expiresAt: exp is num ? exp.toInt() : now + 30 * 60000,
            lines: seed,
          );
          if (reqId != null) {
            _incoming.remove(reqId);
            _incomingLines.remove(reqId);
          }
        } else {
          final c = _channels[id];
          if (c != null) _channels[id] = c.copyWith(closed: true, sharingMine: false);
        }
        break;
      case 'PR_LOCATION':
        final id = e['channelId']?.toString() ?? '';
        final c = _channels[id];
        if (c == null) return;
        if (e['off'] == true) {
          _channels[id] = c.copyWith(clearTheirLocation: true);
        } else if (e['lat'] is num && e['lng'] is num) {
          _channels[id] = c.copyWith(theirLat: (e['lat'] as num).toDouble(), theirLng: (e['lng'] as num).toDouble(), theirLocationAt: (e['at'] as num?)?.toInt() ?? now);
        }
        break;
      case 'PR_CONTACT_SHARED':
        final id = e['channelId']?.toString() ?? '';
        final c = _channels[id];
        if (c == null) return;
        _channels[id] = c.copyWith(theirName: e['name']?.toString(), theirPhone: e['phone']?.toString());
        break;
      case 'PR_SHARE_CONTACT_OK':
        _say('Your name and number were shared with them.');
        break;
      case 'PR_REPORT_OK':
        _say('Reported. Thank you, we will review it.');
        break;
      case 'PR_BLOCK_OK':
        _say('Blocked for 30 days.');
        break;
      case 'ROAD_WARN_SENT':
        _say(e['merged'] == true ? 'Thanks, you confirmed a warning already reported.' : 'Warning sent to riders coming this way.');
        break;
      case 'ROAD_WARNING':
        final w = RoadWarning.fromJson(e, now: now);
        if (w == null) return;
        _warnings[w.warnId] = w;
        _maybeSpeak(w, now);
        break;
      case 'ROAD_WARNING_CLEAR':
        if (_warnings.remove(e['warnId']?.toString()) == null) return;
        break;
      case 'ERROR':
        final reason = e['reason']?.toString();
        if (reason == null || !_reasons.contains(reason)) return;
        _say(e['message']?.toString() ?? 'Could not send.');
        break;
      default:
        return;
    }
    notifyListeners();
  }

  String _outgoingLabelHint() {
    if (_settings.on && _settings.showName) return 'your ride name';
    return _settings.on ? 'Rider / Group of N' : 'A rider';
  }

  void _maybeSpeak(RoadWarning w, int now) {
    final key = RoadWarningPolicy.speechKey(w, spoken: _spoken, emergencyActive: emergencyActive?.call() ?? false, now: now);
    if (key == null || !roadWarningsOn) return;
    _spoken.add(key);
    try {
      speaker?.call(w.speech, key);
    } catch (_) {/* speech is best effort */}
  }

  void _clearRide() {
    _rides = const [];
    _incoming.clear();
    _incomingLines.clear();
    _outgoing.clear();
    _channels.clear();
    _warnings.clear();
    _voted.clear();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
