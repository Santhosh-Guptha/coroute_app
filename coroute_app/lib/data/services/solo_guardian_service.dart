import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/ride/ride_facts.dart';
import '../../domain/safety/coverage_log.dart';
import '../../domain/safety/eta_check_in.dart';
import '../../domain/tracking/geo_math.dart';
import '../../domain/tracking/track_point.dart';
import '../models/convoy_model.dart';
import 'auth_service.dart';
import 'convoy_service.dart';
import 'realtime_service.dart';
import 'safety_service.dart';
import 'settings_service.dart';
import 'sms_sender.dart';
import 'voice_service.dart';

/// An informational card for the ride screen (never blocks, never needs a tap while riding).
class SoloGuardianNotice {
  final String key;
  final String title;
  final String message;
  final int untilMs;
  const SoloGuardianNotice({required this.key, required this.title, required this.message, required this.untilMs});
}

/// What happened to the overdue text (for the ride screen line and the docs' device checks).
enum EtaSmsState { none, sent, composer, failed }

/// 3.55 solo and guardian safety on the phone (docs/features_355/solo_guardian.md):
///
///  * Solo check-in timer ([EtaCheckIn], switch `soloCheckIn`, setting `etaCheckIn`): a solo ride
///    with a destination and an emergency contact is checked on at ETA + margin. "Are you OK?"
///    (voice + prompt, through [SafetyService.showOwnedPrompt]) for 3 min, then one text to the
///    emergency contact with the last known position (phone SMS, works without internet).
///  * No-signal ahead ([CoverageLog], switch `noSignalAhead`, setting `noSignalAhead`): logs
///    online / offline per ~500 m cell on every ride; while still online and a stretch that had no
///    signal on 2+ earlier passes starts 2 to 5 km ahead, says so ONCE to the group and guardian
///    links (WS SIGNAL_AHEAD) and shows the rider a card. Other riders' notices are shown as cards.
///
/// Never speaks or asks while a crash alarm or an SOS is open; never on the SOS lanes.
class SoloGuardianService extends ChangeNotifier {
  SoloGuardianService(
    this._convoys,
    this._settings,
    this._auth,
    this._rt, {
    SafetyService? safety,
    SmsSender? sms,
    VoiceService? voice,
    bool Function(String id)? featureOn,
    int Function()? clock,
    SharedPreferences? prefs,
  })  : _safety = safety, // ignore: prefer_initializing_formals
        _sms = sms ?? NativeSmsSender(),
        _voice = voice, // ignore: prefer_initializing_formals
        _featureOn = featureOn ?? ((_) => true),
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _prefs = prefs { // ignore: prefer_initializing_formals
    _convoys.addListener(_onConvoy);
    _settings.addListener(_onConvoy);
    _fixSub = _convoys.myFixes.listen(_onFix, onError: (Object _) {});
    _rtSub = _rt.events.listen(_onEvent, onError: (Object _) {});
    _loadLog().ignore();
    _onConvoy();
  }

  static const String promptKey = 'LOCAL:ETA_CHECK_IN';
  static const String _logKey = 'coverage_log_v1';
  static const Duration _tickEvery = Duration(seconds: 30);
  static const double _arriveM = 200;
  static const double _movingKmh = 15;

  final ConvoyService _convoys;
  final SettingsService _settings;
  final AuthService _auth;
  final RealtimeService _rt;
  final SafetyService? _safety;
  final SmsSender _sms;
  final VoiceService? _voice;
  final bool Function(String id) _featureOn;
  final int Function() _clock;
  SharedPreferences? _prefs;

  StreamSubscription<TrackPoint>? _fixSub;
  StreamSubscription<Map<String, dynamic>>? _rtSub;
  Timer? _timer;
  bool _disposed = false;

  // ---- solo check-in
  final EtaCheckIn checkIn = EtaCheckIn();
  String? _armedFor; // groupId the timer belongs to
  final Set<String> _armedOnce = <String>{};
  EtaSmsState _smsState = EtaSmsState.none;
  EtaSmsState get smsState => _smsState;

  // ---- no-signal ahead
  CoverageLog _log = CoverageLog();
  bool _logLoaded = false;
  int _lastSampleAt = 0;
  int _lastSaveAt = 0;
  final Set<String> _sentStretch = <String>{};
  int _lastNoticeSentAt = 0;
  bool _noticeOpen = false; // sent and not yet cleared
  bool _wentOffline = false;
  String? _logRide;

  final Map<String, SoloGuardianNotice> _notices = <String, SoloGuardianNotice>{};

  /// Cards for the ride screen (expired ones are left out).
  List<SoloGuardianNotice> get notices {
    final now = _clock();
    return _notices.values.where((n) => n.untilMs > now).toList(growable: false);
  }

  /// [key] is the notice's own [SoloGuardianNotice.key].
  void dismissNotice(String key) {
    final before = _notices.length;
    _notices.removeWhere((_, n) => n.key == key);
    if (_notices.length != before) notifyListeners();
  }

  @visibleForTesting
  CoverageLog get coverageLog => _log;

  ConvoyModel? get _ride {
    final c = _convoys.activeConvoy;
    return c != null && c.tripStatus == 'STARTED' ? c : null;
  }

  bool get _emergency =>
      (_safety?.emergencyOpen ?? false) || _convoys.pendingSos != null || _convoys.myOpenSosAlertId != null;

  String get _contactPhone => (_auth.emergencyContact ?? '').trim();

  // ------------------------------------------------------------------ lifecycle
  void _onConvoy() {
    if (_disposed) return;
    final ride = _ride;
    final on = ride != null;
    if (on && _timer == null) {
      _timer = Timer.periodic(_tickEvery, (_) => _tick());
    } else if (!on && _timer != null) {
      _timer?.cancel();
      _timer = null;
    }
    if (!on) {
      _endRide();
      return;
    }
    _evalCheckIn(ride, fromTick: false);
  }

  void _endRide() {
    if (checkIn.active) _disarm();
    _armedFor = null;
    _noticeOpen = false;
    _wentOffline = false;
    if (_log.dirty) _saveLog().ignore();
  }

  void _tick() {
    final ride = _ride;
    if (ride == null || _disposed) return;
    _evalCheckIn(ride, fromTick: true);
    _evalSignalAhead(ride);
    final now = _clock();
    final before = _notices.length;
    _notices.removeWhere((_, n) => n.untilMs <= now);
    if (_notices.length != before) notifyListeners();
    if (_log.dirty && now - _lastSaveAt > 120000) _saveLog().ignore();
  }

  // ------------------------------------------------------------------ solo check-in by ETA
  ({double lat, double lng, double speedKmh, int at})? _me(ConvoyModel ride) {
    final uid = _convoys.myUserId;
    final me = uid == null ? null : ride.riders[uid];
    if (me == null || !RideFacts.hasPosition(me)) return null;
    return (lat: me.lat, lng: me.lng, speedKmh: me.speedKmh, at: me.lastSeenEpochMs);
  }

  /// Riding time left to the destination at the route's pace (as the crow flies at 40 km/h x 1.3
  /// when there is no usable route).
  Duration? _eta(ConvoyModel ride, double lat, double lng) {
    final left = RideFacts.remainingM(lat: lat, lng: lng, line: ride.routeLine, destLat: ride.destinationLat, destLng: ride.destinationLng);
    if (left == null) return null;
    final byRoute = RideFacts.etaFor(left, ride.route);
    if (byRoute != null) return byRoute;
    return Duration(seconds: (left * 1.3 / (40 / 3.6)).round());
  }

  bool _arrived(ConvoyModel ride, double lat, double lng) {
    final uid = _convoys.myUserId;
    if (uid != null && (ride.destinationArrivals[uid]?.reached ?? false)) return true;
    return GeoMath.haversine(lat, lng, ride.destinationLat, ride.destinationLng) <= _arriveM;
  }

  bool _checkInAllowed(ConvoyModel ride) =>
      _featureOn('soloCheckIn') && _settings.etaCheckIn && ride.isSolo && RideFacts.hasDestination(ride) && _contactPhone.length >= 7;

  void _evalCheckIn(ConvoyModel ride, {required bool fromTick}) {
    if (_armedFor != null && _armedFor != ride.groupId) _disarm();
    final me = _me(ride);
    if (!_checkInAllowed(ride)) {
      if (checkIn.active) {
        _disarm();
        // 3.55 fix: switched off (setting, admin switch, contact removed) before arriving: switching
        // it back on in the same ride arms it again. It used to stay off until the next ride.
        _armedOnce.remove(ride.groupId);
      }
      return;
    }
    if (me == null) return;
    final now = _clock();
    if (_arrived(ride, me.lat, me.lng)) {
      if (checkIn.active) _disarm();
      _armedOnce.add(ride.groupId); // arrived: not armed again for this ride
      return;
    }
    final eta = _eta(ride, me.lat, me.lng);
    if (!checkIn.active) {
      if (_armedOnce.contains(ride.groupId) || eta == null) return;
      checkIn.arm(nowMs: now, eta: eta);
      _armedFor = ride.groupId;
      _armedOnce.add(ride.groupId);
      _smsState = EtaSmsState.none;
      notifyListeners();
      return;
    }
    if (!fromTick) return;
    if (eta != null && me.speedKmh >= _movingKmh) checkIn.updateEta(nowMs: now, eta: eta);
    // Never ask during an emergency (the SOS has its own texts); the step waits.
    if (_emergency) return;
    // Riding along: the timer moves with the ETA above, so nothing is asked of a moving rider.
    if (checkIn.phase == EtaCheckInPhase.armed && me.speedKmh >= _movingKmh) return;
    final action = checkIn.tick(now);
    if (action == EtaCheckInAction.ask) {
      _ask(ride, told: false);
    } else if (action == EtaCheckInAction.escalate) {
      _ask(ride, told: true);
      _textContact(ride, me).ignore();
    }
  }

  void _ask(ConvoyModel ride, {required bool told}) {
    final dest = ride.destinationName.trim().isEmpty ? 'your destination' : ride.destinationName.trim();
    final contact = (_auth.emergencyContactName ?? '').trim();
    final who = contact.isEmpty ? 'your emergency contact' : contact;
    final mins = checkIn.askFor.inMinutes;
    _safety?.showOwnedPrompt(
      SafetyPrompt(
        key: promptKey,
        kind: SafetyPromptKind.checkIn,
        title: 'Are you OK?',
        message: told
            ? 'We texted $who that you have not reached $dest. Tap if you are fine.'
            : 'You have not reached $dest yet. Tap if you are fine, or $who is texted in $mins min.',
        primaryLabel: "I'm fine",
        secondaryLabel: 'Add 30 min',
      ),
      _onAnswer,
    );
    if (!told && !_emergency) {
      _voice?.speak('Are you OK? Tap I am fine on the screen.', priority: VoicePriority.important, key: 'eta_check_in').ignore();
    }
    notifyListeners();
  }

  void _onAnswer(bool primary) {
    final ride = _ride;
    final now = _clock();
    final me = ride == null ? null : _me(ride);
    final eta = ride != null && me != null ? _eta(ride, me.lat, me.lng) : null;
    final told = primary ? checkIn.imFine(nowMs: now, eta: eta) : checkIn.extend(nowMs: now);
    if (told) _textFine().ignore();
    notifyListeners();
  }

  void _disarm() {
    checkIn.disarm();
    _safety?.removeOwnedPrompt(promptKey);
    if (!_disposed) notifyListeners();
  }

  /// One text to the emergency contact: phone SMS when this build may send it, otherwise the
  /// messages app with the text filled in (only while the app is in front: Android does not let an
  /// app open another app from the background).
  Future<void> _textContact(ConvoyModel ride, ({double lat, double lng, double speedKmh, int at}) me) async {
    final phone = _contactPhone;
    if (phone.isEmpty) return;
    // The check-in time that passed (the rider was asked then and did not answer).
    final expected = DateTime.fromMillisecondsSinceEpoch(checkIn.askedAtMs ?? _clock());
    final body = EtaCheckInSms.overdue(
      name: _auth.currentUserName ?? '',
      destination: ride.destinationName,
      expectedBy: expected,
      lat: me.lat,
      lng: me.lng,
      fixAt: me.at > 0 ? DateTime.fromMillisecondsSinceEpoch(me.at) : null,
    );
    _smsState = await _sendText(phone, body);
    if (!_disposed) notifyListeners();
  }

  Future<void> _textFine() async {
    final phone = _contactPhone;
    if (phone.isEmpty || _smsState != EtaSmsState.sent) return;
    final body = EtaCheckInSms.fineNow(name: _auth.currentUserName ?? '', at: DateTime.fromMillisecondsSinceEpoch(_clock()));
    await _sendText(phone, body);
  }

  Future<EtaSmsState> _sendText(String phone, String body) async {
    try {
      final cap = await _sms.capability();
      if (cap.ready) {
        final s = await _sms.send(phone, body).timeout(const Duration(seconds: 40), onTimeout: () => SmsStatus.timeout);
        return s == SmsStatus.sent ? EtaSmsState.sent : EtaSmsState.failed;
      }
      if (_inBackground) return EtaSmsState.failed;
      return await SmsComposer.open(to: [phone], body: body) ? EtaSmsState.composer : EtaSmsState.failed;
    } catch (e) {
      debugPrint('check-in text note: ${e.runtimeType}');
      return EtaSmsState.failed;
    }
  }

  bool get _inBackground {
    try {
      final s = SchedulerBinding.instance.lifecycleState;
      return s != null && s != AppLifecycleState.resumed;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------------ coverage log
  Future<void> _loadLog() async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      final raw = prefs.getString(_logKey);
      if (raw != null && raw.isNotEmpty) {
        final loaded = CoverageLog.fromJson(jsonDecode(raw));
        // Samples taken before the load finished are kept on top of the saved history.
        if (_log.length == 0) _log = loaded;
      }
    } catch (_) {
      // A broken saved log starts again empty.
    } finally {
      _logLoaded = true;
    }
  }

  Future<void> _saveLog() async {
    if (!_logLoaded) return;
    _lastSaveAt = _clock();
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      await prefs.setString(_logKey, jsonEncode(_log.toJson()));
      _log.markSaved();
    } catch (_) {}
  }

  void _onFix(TrackPoint p) {
    final ride = _ride;
    if (ride == null || _disposed) return;
    if (p.ts - _lastSampleAt < 5000) return;
    _lastSampleAt = p.ts;
    if (p.accuracyM > 100) return;
    final online = _rt.isConnected;
    if (_logRide != ride.groupId) _logRide = ride.groupId;
    _log.record(lat: p.lat, lng: p.lng, online: online, rideId: ride.groupId, nowMs: p.ts);
    if (!online && _noticeOpen) _wentOffline = true;
    if (online && _noticeOpen && _wentOffline) {
      // Back online after the stretch: the group and the guardian links stop showing the notice.
      _noticeOpen = false;
      _wentOffline = false;
      _rt.send({'type': 'SIGNAL_AHEAD', 'clear': true});
    }
  }

  // ------------------------------------------------------------------ no-signal ahead
  void _evalSignalAhead(ConvoyModel ride) {
    if (!_featureOn('noSignalAhead') || !_settings.noSignalAhead || !_rt.isConnected || _emergency) return;
    final now = _clock();
    if (now - _lastNoticeSentAt < 10 * 60000) return;
    final me = _me(ride);
    if (me == null) return;
    final line = ride.routeLine;
    if (line.length < 2) return;
    final along = GeoMath.alongRoute(me.lat, me.lng, line);
    if (along == null || along.offRoute > 300) return;
    final stretch = _log.deadAhead(line: line, myAlongM: along.along);
    if (stretch == null || _sentStretch.contains('${ride.groupId}|${stretch.startCell}')) return;
    final route = ride.route;
    final mps = route != null && route.distanceM > 0 && route.durationS > 0
        ? route.distanceM / route.durationS
        : (me.speedKmh >= _movingKmh ? me.speedKmh / 3.6 : 40 / 3.6);
    final backAt = now + (stretch.endAheadM / mps * 1000).round();
    final near = _nearName(ride, stretch.lat, stretch.lng);
    final sent = _rt.send({'type': 'SIGNAL_AHEAD', 'backAt': backAt, if (near.isNotEmpty) 'near': near});
    if (!sent) return;
    _sentStretch.add('${ride.groupId}|${stretch.startCell}');
    _lastNoticeSentAt = now;
    _noticeOpen = true;
    _wentOffline = false;
    final km = (stretch.startAheadM / 1000).toStringAsFixed(stretch.startAheadM < 10000 ? 1 : 0);
    final lenKm = (stretch.lengthM / 1000).round();
    _notices['NO_SIGNAL_AHEAD'] = SoloGuardianNotice(
      key: 'NO_SIGNAL_AHEAD:${stretch.startCell}',
      title: 'No signal ahead',
      message: 'Your phone had no signal ${lenKm > 0 ? 'for about $lenKm km ' : ''}from $km km ahead on earlier rides. '
          'Your group and guardians were told you expect to be back online around ${_hm(backAt)}.',
      untilMs: now + 3 * 60000,
    );
    notifyListeners();
  }

  /// A planned stop or the destination within 10 km of the stretch, for "near X" (or '').
  String _nearName(ConvoyModel ride, double lat, double lng) {
    String best = '';
    var bestD = 10000.0;
    void consider(String name, double plat, double plng) {
      if (name.trim().isEmpty || (plat == 0 && plng == 0)) return;
      final d = GeoMath.haversine(lat, lng, plat, plng);
      if (d < bestD) {
        bestD = d;
        best = name.trim();
      }
    }

    for (final s in ride.plannedStops) {
      consider(s.name, s.lat, s.lng);
    }
    consider(ride.destinationName, ride.destinationLat, ride.destinationLng);
    return best.length > 60 ? best.substring(0, 60) : best;
  }

  /// Another rider of my ride said they enter a no-signal stretch (SIGNAL_AHEAD room event).
  void _onEvent(Map<String, dynamic> m) {
    if (m['type'] != 'SIGNAL_AHEAD' || _disposed) return;
    final uid = m['userId']?.toString() ?? '';
    if (uid.isEmpty || uid == _convoys.myUserId) return;
    final key = 'SIGNAL_AHEAD:$uid';
    if (m['clear'] == true) {
      if (_notices.remove(key) != null) notifyListeners();
      return;
    }
    final backAt = (m['backAt'] as num?)?.toInt() ?? 0;
    if (backAt <= 0) return;
    final name = (m['name']?.toString() ?? 'A rider').trim();
    final near = (m['near']?.toString() ?? '').trim();
    _notices[key] = SoloGuardianNotice(
      key: '$key:$backAt',
      title: '$name: no signal ahead',
      message: 'Entering a no-signal stretch${near.isEmpty ? '' : ' near $near'}, expected back online around ${_hm(backAt)}.',
      untilMs: _clock() + 10 * 60000,
    );
    notifyListeners();
  }

  static String _hm(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${two(t.hour)}:${two(t.minute)}';
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _fixSub?.cancel();
    _rtSub?.cancel();
    _convoys.removeListener(_onConvoy);
    _settings.removeListener(_onConvoy);
    if (_log.dirty) _saveLog().ignore();
    super.dispose();
  }
}
