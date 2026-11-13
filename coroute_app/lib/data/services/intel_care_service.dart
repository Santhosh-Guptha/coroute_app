// Round 4 road & safety intelligence on the phone (docs/intelligence/ROAD_AND_SAFETY_INTELLIGENCE.md).
//
// Owned by SafetyService (like RoadCareService), which feeds it my fixes, the 1 s accelerometer buckets, road
// surface events, hard stops and crash alarm outcomes. Everything that decides is pure (lib/domain/intel/); this
// class only stores, uploads, prefetches and shows / speaks through the road care cockpit slot (also on the
// lock-screen cockpit). It never shows or speaks over an SOS / crash alarm, and it never touches SOS, crash
// detection's countdown, emergency texts or Medical ID.
//
//  * consent "Help make roads safer" (opt-in, server-side with a timestamp): events leave the phone only with it;
//  * signals: hard braking, swerve, skid, potholes / rough road (mount aware), trimmed (first / last 300 m), queued
//    offline and uploaded in batches after the ride;
//  * warnings for everyone: hazard ahead (1 per 2 km), rough road ahead (1 per 5 km, low priority), twisty section
//    ahead, from tiles prefetched along the route at ride start (offline after that);
//  * long ride and night nudges (LongRideNudges), the pre-ride tip (once a day);
//  * crash brain: features of each crash alarm with its outcome, "Was this a real crash?" after a cancelled alarm,
//    approved parameters with checksum (defaults on any error).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/intel/geohash.dart';
import '../../domain/intel/hazard_ahead.dart';
import '../../domain/intel/intel_event.dart';
import '../../domain/intel/intel_policies.dart';
import '../../domain/intel/long_ride_nudges.dart';
import '../../domain/intel/ride_signal_detector.dart';
import '../../domain/safety/accel_bucket.dart';
import '../../domain/safety/crash_detector.dart';
import '../../domain/safety/mount_classifier.dart';
import '../../domain/safety/road_surface_detector.dart';
import '../../domain/tracking/geo_math.dart';
import '../../domain/tracking/track_point.dart';
import 'api_client.dart';
import 'road_care_service.dart';
import 'private_places_store.dart';

/// Road safety warnings kept on the phone (consent itself lives on the server).
///
/// Round 9 (docs/quality/ROUND9_SETTINGS_NOTES.md): hazard, rough road, twisty and long ride / night
/// warnings are always on (no switches; the warning scheduler rate-limits them, and rough road, twisty
/// and nudges can be muted for one ride from their card). A stored "off" from an older build is ignored
/// and written back as on; the setters are kept for callers and do nothing. The break interval has no
/// picker any more: a shorter interval a rider chose before (90 or 105 min, the safer side) is kept,
/// anything else is the always-on 2 h.
class IntelSettings {
  IntelSettings({int breakIntervalMin = 120, this.consentAnswered = false, this.completedRides = 0, this.tipDay, this.debugBreakMin = 0, this.consentOn = false, this.consentAt})
      : breakIntervalMin = breakIntervalMin.clamp(90, 120);

  /// Hazard warnings: always on (round 9).
  bool get hazardWarnings => true;
  set hazardWarnings(bool _) {}

  /// Rough road ahead: always on (round 9; low priority, max one per 5 km, mutable for one ride).
  bool get roughRoadWarnings => true;
  set roughRoadWarnings(bool _) {}

  /// Twisty section ahead: always on (round 9; mutable for one ride).
  bool get twistyWarnings => true;
  set twistyWarnings(bool _) {}

  /// Long ride (4 h) and night riding nudges: always on (round 9; mutable for one ride).
  bool get longRideNudges => true;
  set longRideNudges(bool _) {}

  /// Break reminder interval, 90-120 min (no picker since round 9; the always-on 2 h prompt is 120).
  int breakIntervalMin;
  bool consentAnswered;
  int completedRides;
  String? tipDay;

  /// Debug builds only: a shortened break interval in minutes for device QA (0 = off).
  int debugBreakMin;
  bool consentOn;
  int? consentAt;

  Map<String, Object?> toJson() => {
        'hw': hazardWarnings, 'rr': roughRoadWarnings, 'tw': twistyWarnings, 'ln': longRideNudges, 'bi': breakIntervalMin,
        'ans': consentAnswered, 'rides': completedRides, 'tip': tipDay, 'dbg': debugBreakMin, 'con': consentOn, 'cat': consentAt,
      };

  static IntelSettings fromJson(Object? j) {
    if (j is! Map) return IntelSettings();
    bool b(String k, bool d) => j[k] is bool ? j[k] as bool : d;
    int i(String k, int d) => j[k] is num ? (j[k] as num).toInt() : d;
    // Round 9: 'hw' / 'rr' / 'tw' / 'ln' are ignored (always on); toJson writes them back as true.
    return IntelSettings(
      breakIntervalMin: i('bi', 120),
      consentAnswered: b('ans', false),
      completedRides: i('rides', 0),
      tipDay: j['tip'] is String ? j['tip'] as String : null,
      debugBreakMin: i('dbg', 0).clamp(0, 60),
      consentOn: b('con', false),
      consentAt: j['cat'] is num ? (j['cat'] as num).toInt() : null,
    );
  }
}

/// One crash alarm waiting for the rider's "Was this a real crash?" answer.
class CrashFeedbackAsk {
  const CrashFeedbackAsk(this.id, this.atMs);
  final String id;
  final int atMs;
  static const String title = 'Was this a real crash?';
  static const String body = 'Your answer helps crash detection raise fewer false alarms. Optional, one tap.';
}

class IntelCareService extends ChangeNotifier {
  IntelCareService({required this.roadCare, required this.emergency, required this.routeLine, this.featureOn, int Function()? now, bool persist = true})
      : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _persist = persist; // ignore: prefer_initializing_formals

  final RoadCareService roadCare;

  /// An SOS / crash alarm (mine or the group's) is open: nothing is shown or spoken.
  final bool Function() emergency;

  /// The group's planned route line (null without one).
  final List<(double, double)>? Function() routeLine;
  final bool Function(String id)? featureOn;
  final int Function() _now;
  final bool _persist;

  /// Set in main.dart (null in tests: nothing is uploaded or fetched).
  ApiClient? api;

  /// The device model for crash brain groups (main.dart; '' when unknown).
  String Function()? deviceModel;

  /// Applies the approved crash brain impact scale (SafetyService -> CrashDetector.setBrainImpactScale).
  void Function(double scale)? onBrainScale;

  /// Round 7: places where riders brake hard or skid (hazard cells), for the curve predictor.
  void Function(List<(double, double)> spots)? onHardBrakeSpots;

  /// Round 7: the route line whose tiles are being fetched (road cells are fetched with it).
  void Function(List<(double, double)> line)? onRouteLine;

  /// The phone mount the sensor hub found this ride.
  MountKind Function()? mount;

  /// The lead's regroup suggestion name for the group break nudge (GroupSafetyService), or null.
  String? Function()? regroupName;

  /// True when this phone is the lead of a group ride.
  bool Function()? isLead;

  IntelSettings settings = IntelSettings();
  final IntelEventQueue queue = IntelEventQueue();
  final RideSignalDetector signals = RideSignalDetector();
  final AheadMonitor hazards = AheadMonitor(spacingM: 2000);
  final AheadMonitor rough = AheadMonitor(spacingM: 5000);
  final TwistyAhead twisty = TwistyAhead();
  LongRideNudges nudges = LongRideNudges();
  IntelTileCache hazardTiles = IntelTileCache();
  IntelTileCache roughTiles = IntelTileCache();
  IntelTileCache twistyTiles = IntelTileCache();
  IntelTileCache stopTiles = IntelTileCache();

  bool _loaded = false;
  bool _riding = false;
  TrackPoint? _headingFrom;
  double? _heading;
  TrackPoint? _lastFix;
  int _brakesSeen = 0;
  String? _routeKey;
  bool _uploading = false;
  bool _tipAsked = false;
  CrashFeedbackAsk? _feedbackAsk;
  double brainScale = 1.0;

  /// The pending "Was this a real crash?" question (shown by IntelPromptHost when not riding).
  CrashFeedbackAsk? get feedbackAsk => _feedbackAsk;

  bool get consentOn => settings.consentOn;

  bool _on(String id) => featureOn?.call(id) ?? true;

  // ---------------------------------------------------------------- storage
  static const String keySettings = 'intel_settings_v1';
  static const String keyQueue = 'intel_queue_v1';
  static const String keyTiles = 'intel_tiles_v1';
  static const String keyBrain = 'intel_brain_v1';

  Future<void> load() async {
    if (_loaded || !_persist) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      settings = IntelSettings.fromJson(_decode(p.getString(keySettings)));
      final q = _decode(p.getString(keyQueue));
      if (q is List) queue.ready.addAll([for (final e in q) ?IntelEvent.fromStore(e)]);
      final t = _decode(p.getString(keyTiles));
      if (t is Map) {
        hazardTiles = IntelTileCache.fromJson(t['hz']);
        roughTiles = IntelTileCache.fromJson(t['rq']);
        twistyTiles = IntelTileCache.fromJson(t['tw']);
        stopTiles = IntelTileCache.fromJson(t['st']);
      }
      final brain = _decode(p.getString(keyBrain));
      _applyBrain(brain);
    } catch (e) {
      debugPrint('intel load: ${e.runtimeType}');
    }
    _applyInterval();
    notifyListeners();
  }

  static Object? _decode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  Future<void> _save({bool queueToo = false, bool tilesToo = false}) async {
    if (!_persist) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(keySettings, jsonEncode(settings.toJson()));
      if (queueToo) await p.setString(keyQueue, jsonEncode([for (final e in queue.ready) e.toStore()]));
      if (tilesToo) {
        await p.setString(keyTiles, jsonEncode({'hz': hazardTiles.toJson(), 'rq': roughTiles.toJson(), 'tw': twistyTiles.toJson(), 'st': stopTiles.toJson()}));
      }
    } catch (_) {}
  }

  void _applyInterval() {
    final dbg = kDebugMode && settings.debugBreakMin > 0;
    nudges = LongRideNudges(
      interval: Duration(minutes: settings.breakIntervalMin),
      baseRuleMin: dbg ? 0 : 120,
    );
    if (dbg) nudges.interval = Duration(minutes: settings.debugBreakMin); // QA only: bypasses the 90 min floor
  }

  // ---------------------------------------------------------------- settings and consent
  Future<void> update(void Function(IntelSettings s) change) async {
    change(settings);
    settings.breakIntervalMin = settings.breakIntervalMin.clamp(90, 120);
    _applyInterval();
    notifyListeners();
    await _save();
  }

  /// Reads the server-side consent (GET /api/intel/consent).
  Future<void> refreshConsent() async {
    final a = api;
    if (a == null) return;
    try {
      final r = await a.get('/intel/consent');
      if (r is Map) {
        settings.consentOn = r['on'] == true;
        settings.consentAt = (r['at'] as num?)?.toInt();
        if (r['promptedAt'] != null) settings.consentAnswered = true;
        notifyListeners();
        await _save();
      }
    } catch (_) {}
  }

  /// Turns "Help make roads safer" on or off (server first; off clears anything still waiting on the phone).
  Future<bool> setConsent(bool on, {bool fromPrompt = false}) async {
    final a = api;
    try {
      if (a != null) await a.put('/intel/consent', {'on': on, 'prompted': fromPrompt});
    } catch (_) {
      return false;
    }
    settings.consentOn = on;
    settings.consentAt = _now();
    settings.consentAnswered = true;
    if (!on) queue.clear();
    notifyListeners();
    await _save(queueToo: true);
    return true;
  }

  /// "Not now" on the one-time prompt.
  Future<void> dismissPrompt() async {
    settings.consentAnswered = true;
    notifyListeners();
    await _save();
  }

  bool shouldPromptConsent({required bool riding}) => ConsentPromptPolicy.shouldPrompt(
      completedRides: settings.completedRides, answered: settings.consentAnswered, consentOn: settings.consentOn, riding: riding, emergency: emergency());

  Future<Object?> exportContributions() async => api?.get('/intel/me/contributions', timeout: const Duration(seconds: 20));

  Future<String?> deleteContributions() async {
    queue.clear();
    await _save(queueToo: true);
    final r = await api?.delete('/intel/me/contributions');
    return r is Map ? r['message']?.toString() : null;
  }

  // ---------------------------------------------------------------- ride lifecycle
  void startRide() {
    _riding = true;
    queue.startRide();
    signals.reset();
    hazards.reset();
    rough.reset();
    nudges.reset();
    _headingFrom = null;
    _heading = null;
    _lastFix = null;
    _brakesSeen = 0;
    _routeKey = null;
    _tipAsked = false;
    load().then((_) {
      _prefetchForRide();
      _fetchBrain();
    }).ignore();
  }

  void endRide() {
    if (!_riding) return;
    _riding = false;
    final f = _lastFix;
    queue.endRide(f?.lat, f?.lng);
    settings.completedRides++;
    _save(queueToo: true).ignore();
    upload().ignore();
    notifyListeners(); // IntelPromptHost may ask the one-time question now
  }

  /// Uploads waiting events (consent required; offline: they wait, up to 1000).
  Future<void> upload() async {
    final a = api;
    if (a == null || _uploading || !settings.consentOn || queue.ready.isEmpty) return;
    _uploading = true;
    try {
      while (queue.ready.isNotEmpty) {
        final batch = queue.batch(200);
        await a.post('/intel/events', {'events': [for (final e in batch) e.toWire()]});
        queue.confirm(batch.length);
      }
    } catch (_) {
      // Offline or the server said no: kept for the next ride end.
    } finally {
      _uploading = false;
      await _save(queueToo: true);
    }
  }

  // ---------------------------------------------------------------- inputs from SafetyService
  void _trackHeading(TrackPoint p) {
    final from = _headingFrom;
    if (from == null) {
      _headingFrom = p;
      return;
    }
    if (p.speedKmh < 5) return;
    if (GeoMath.haversine(from.lat, from.lng, p.lat, p.lng) >= 15) {
      _heading = GeoMath.bearing(from.lat, from.lng, p.lat, p.lng);
      _headingFrom = p;
    }
  }

  /// My fix during a ride. [stretchStartMs]: FatigueTracker's riding stretch.
  void onFix(TrackPoint p, {int? stretchStartMs}) {
    if (!_riding || (p.lat == 0 && p.lng == 0)) return;
    _lastFix = p;
    if (!_tipAsked) {
      _tipAsked = true;
      maybeRideTip(p.lat, p.lng).ignore(); // once per ride, at most once a day
      if (_routeKey == null) _prefetchForRide(); // no route: tiles around where the ride starts
    }
    _trackHeading(p);
    signals.onFix(p);
    if (settings.consentOn) {
      // 3.56 (round 6): the rider's private places are privacy zones (nothing within 300 m is queued).
      queue.zones = PrivatePlacesStore.shared.zones;
      queue.onFix(p.lat, p.lng);
    }
    final em = emergency();
    if (p.accuracyM <= 50) {
      if (settings.hazardWarnings && _on('hazardAhead')) {
        final w = hazards.onFix(lat: p.lat, lng: p.lng, headingDeg: _heading, speedKmh: p.speedKmh, emergency: em, describe: AheadMonitor.hazard);
        if (w != null) _warn('HAZARD:${w.cell.id}', w.title, w.speech, rank: 4, hazard: true, seconds: 25);
      }
      if (settings.roughRoadWarnings && _on('roughRoadAhead')) {
        final w = rough.onFix(lat: p.lat, lng: p.lng, headingDeg: _heading, speedKmh: p.speedKmh, emergency: em, describe: AheadMonitor.rough);
        if (w != null) _warn('ROUGH:${w.cell.id}', w.title, w.speech, rank: 1, seconds: 15);
      }
      if (settings.twistyWarnings && _on('twistyAhead')) _checkTwisty(p, em);
    }
    if (settings.longRideNudges && _on('longRideNudges')) {
      final n = nudges.update(nowMs: p.ts, stretchStartMs: stretchStartMs, local: DateTime.fromMillisecondsSinceEpoch(p.ts), moving: p.speedKmh >= 10, emergency: em);
      if (n != null) _warn('NUDGE:${n.kind.name}:${p.ts ~/ 60000}', n.title, n.speech, rank: n.kind == NudgeKind.strongBreak ? 3 : 1, seconds: 60);
      if (isLead?.call() ?? false) {
        final g = nudges.groupUpdate(nowMs: p.ts, stretchStartMs: stretchStartMs, emergency: em, regroupName: regroupName?.call());
        if (g != null) _warn('NUDGE:group:${p.ts ~/ 60000}', g.title, g.speech, rank: 2, seconds: 60);
      }
    }
  }

  /// "Snooze" on a nudge chip.
  void snoozeNudges() => nudges.snooze(_now());

  /// The 1 s accelerometer bucket. [busy]: the crash detector weighs an impact or an alarm / SOS is open.
  /// [hardStops]: HardBrakeCounter.count so far this ride.
  void onAccel(AccelBucket b, {required bool busy, required int hardStops}) {
    if (!_riding || !settings.consentOn) {
      _brakesSeen = hardStops;
      return;
    }
    final f = _lastFix;
    if (f == null) return;
    for (var i = _brakesSeen; i < hardStops; i++) {
      final e = IntelEvent.at(type: IntelEventType.hardBrake, lat: f.lat, lng: f.lng, headingDeg: _heading, speedKmh: f.speedKmh, ts: b.tMs);
      if (e != null) queue.add(e);
    }
    _brakesSeen = hardStops;
    final t = signals.onBucket(b, busy: busy, mount: mount?.call() ?? MountKind.unknown);
    if (t != null) {
      final e = IntelEvent.at(type: t, lat: f.lat, lng: f.lng, headingDeg: _heading, speedKmh: f.speedKmh, ts: b.tMs);
      if (e != null) queue.add(e);
    }
  }

  void onRoadSurface(RoadSurfaceEvent ev) {
    if (!_riding || !settings.consentOn) return;
    final e = PotholeIntelGate.eventOf(ev, mount: mount?.call() ?? MountKind.unknown, headingDeg: _heading);
    if (e != null) queue.add(e);
  }

  /// A crash alarm ended: [sent] = the SOS went out (label real), else "I'm OK" (label false alarm).
  void onCrashAlarm(CrashEvent e, {required bool sent, required bool riderDown, required bool external, double thresholdG = 4.0, double stillS = 0}) {
    if (external || !settings.consentOn) return;
    final id = 'c${_now().toRadixString(36)}${e.impactAtMs.toRadixString(36)}';
    final path = riderDown ? 'riderdown' : e.isSlideFall ? 'slide' : e.hasRotationOrTilt && e.impactG < thresholdG ? 'lowfall' : 'impact';
    final body = {
      'id': id,
      'outcome': sent ? 'sent' : 'ok',
      'features': {
        'pg': double.parse(e.impactG.toStringAsFixed(2)),
        'v': double.parse(e.speedBeforeKmh.toStringAsFixed(1)),
        'still': stillS,
        'rot': e.hasRotationOrTilt ? 1 : 0,
        'mount': (mount?.call() ?? MountKind.unknown).wire,
        'path': path,
        'thr': thresholdG * brainScale,
        'dm': deviceModel?.call() ?? '',
        'sev': e.impactG >= 7.0,
      },
    };
    api?.post('/intel/crash', body).ignore();
    if (!sent) {
      _feedbackAsk = CrashFeedbackAsk(id, _now());
      notifyListeners();
    }
  }

  /// "Was this a real crash?" answer (null = skipped).
  void answerCrashFeedback(bool? real) {
    final ask = _feedbackAsk;
    _feedbackAsk = null;
    notifyListeners();
    if (ask == null || real == null) return;
    api?.post('/intel/crash/feedback', {'id': ask.id, 'real': real}).ignore();
  }

  // ---------------------------------------------------------------- warnings
  void _warn(String key, String title, String speech, {required int rank, bool hazard = false, int seconds = 20}) {
    if (emergency()) return;
    final shown = roadCare.showExternal(RoadCareNotice(key: 'INTEL:$key', title: title, message: '', rank: rank, important: rank >= 3), Duration(seconds: seconds));
    if (shown) roadCare.sayExternal(speech, key: 'intel_$key', hazard: hazard);
  }

  void _checkTwisty(TrackPoint p, bool em) {
    final line = routeLine();
    if (line == null || line.length < 2 || twisty.sections.isEmpty) return;
    final a = GeoMath.alongRoute(p.lat, p.lng, line);
    if (a == null || a.offRoute > 300) return;
    final s = twisty.onAlong(a.along, emergency: em);
    if (s != null) _warn('TWISTY:${s.startM.round()}', TwistyAhead.title(s), TwistyAhead.speech(s), rank: 2, seconds: 30);
  }

  /// Tiles along the route (or around me) fetched once per ride and kept 14 days for offline use. Also called
  /// when offline maps are saved for a route.
  Future<void> prefetchAlong(List<(double, double)> line) async {
    final a = api;
    if (line.isEmpty) return;
    try {
      if (line.length >= 2) onRouteLine?.call(line);
    } catch (_) {}
    final now = _now();
    final tiles = Geohash.tilesAlong(line);
    final stale = tiles.where((t) => !hazardTiles.fresh(t, now)).toList();
    if (a != null && stale.isNotEmpty) {
      final q = stale.join(',');
      Future<List<IntelCell>> get(String path) async {
        try {
          final r = await a.get('/intel/$path?tiles=$q', timeout: const Duration(seconds: 15));
          final list = r is Map ? r['cells'] : null;
          return [if (list is List) for (final c in list) ?IntelCell.fromJson(c)];
        } catch (_) {
          return const [];
        }
      }

      final hz = await get('hazards'), rq = await get('road-quality'), tw = await get('twisty'), st = await get('stops');
      String tileOf(IntelCell c) => Geohash.encode(c.lat, c.lng, 4) ?? '';
      for (final t in stale) {
        hazardTiles.put(t, [for (final c in hz) if (tileOf(c) == t) c], now);
        roughTiles.put(t, [for (final c in rq) if (tileOf(c) == t) c], now);
        twistyTiles.put(t, [for (final c in tw) if (tileOf(c) == t) c], now);
        stopTiles.put(t, [for (final c in st) if (tileOf(c) == t) c], now);
      }
      await _save(tilesToo: true);
    }
    _applyCells(line);
  }

  void _applyCells(List<(double, double)> line) {
    final now = _now();
    hazards.setCells(hazardTiles.cells(now));
    try {
      onHardBrakeSpots?.call([
        for (final c in hazardTiles.cells(now))
          if (c.kind == 'hard_brake' || c.kind == 'skid') (c.lat, c.lng)
      ]);
    } catch (_) {}
    rough.setCells(roughTiles.cells(now));
    final along = <({double alongM, bool ghat})>[];
    if (line.length >= 2) {
      for (final c in twistyTiles.cells(now)) {
        if (c.score < 30) continue;
        final a = GeoMath.alongRoute(c.lat, c.lng, line);
        if (a != null && a.offRoute <= 400) along.add((alongM: a.along, ghat: c.ghat));
      }
    }
    twisty.setSections(TwistyAhead.sectionsOf(along));
  }

  /// Learned stops along the route (regroup suggestions, fuel gaps).
  List<IntelCell> get learnedStops => stopTiles.cells(_now());

  void _prefetchForRide() {
    final line = routeLine();
    final f = _lastFix;
    final use = line != null && line.length >= 2 ? line : (f != null ? [(f.lat, f.lng)] : const <(double, double)>[]);
    final key = use.isEmpty ? null : '${use.length}:${use.first}:${use.last}';
    if (key == null || key == _routeKey) return;
    _routeKey = key;
    prefetchAlong(use).ignore();
  }

  /// The route changed during the ride (a new plan or a re-route).
  void routeChanged() {
    if (_riding) _prefetchForRide();
  }

  // ---------------------------------------------------------------- pre-ride tip, fuel gaps
  Future<void> maybeRideTip(double lat, double lng) async {
    final a = api;
    final local = DateTime.fromMillisecondsSinceEpoch(_now());
    if (a == null || !settings.hazardWarnings || !RideTipGate.allowed(lastShownDay: settings.tipDay, local: local)) return;
    try {
      final r = await a.get('/intel/ride-tip?lat=${lat.toStringAsFixed(3)}&lng=${lng.toStringAsFixed(3)}');
      final tip = r is Map ? r['tip'] : null;
      if (tip is! String || tip.isEmpty) return;
      settings.tipDay = RideTipGate.dayKey(local);
      await _save();
      _warn('TIP:${settings.tipDay}', 'Ride safe', tip, rank: 1, seconds: 20);
    } catch (_) {}
  }

  /// No-fuel gaps on a planned route from known fuel (map places corridor) and learned stops tagged fuel.
  List<FuelGap> fuelGaps(List<(double, double)> route, Iterable<({double lat, double lng, String name})> knownFuel, {double gapKm = 80}) =>
      FuelGapFinder.gaps(route, [...knownFuel, for (final s in learnedStops) if (s.fuel) (lat: s.lat, lng: s.lng, name: s.name)], gapKm: gapKm);

  // ---------------------------------------------------------------- crash brain params
  Future<void> _fetchBrain() async {
    final a = api;
    if (a == null) return;
    try {
      final model = Uri.encodeQueryComponent(deviceModel?.call() ?? '');
      final r = await a.get('/intel/crash-params?model=$model');
      _applyBrain(r);
      if (_persist) {
        final p = await SharedPreferences.getInstance();
        await p.setString(keyBrain, jsonEncode(r));
      }
    } catch (_) {
      // Offline: the last verified answer (or the defaults) stays.
    }
  }

  void _applyBrain(Object? j) {
    brainScale = CrashBrainParams.impactScaleOf(j);
    try {
      onBrainScale?.call(brainScale);
    } catch (_) {}
  }
}
