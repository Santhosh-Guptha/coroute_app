// Round 10 rescue beacon, RESPONDER side: listens for a down rider's locator (near-ultrasonic
// packets through the ride mic, BLE advertisements) and feeds the rescue finder screen.
// Docs: docs/features_355/rescue_beacon.md.
//
// When it listens (RescueListenGate): only while another rider's SOS is open in my group, or I
// accepted to help a nearby rider (ASSIST), AND either the finder screen is open or I am within
// 1 km of the victim's last position (2 km when offline). Never otherwise: no mic at 48 kHz and
// no BLE scan in a normal ride.
//
// Privacy: the microphone frames are analysed in memory on this phone (a few Goertzel filters
// around 14..20 kHz) and dropped; nothing is recorded, stored or sent. BLE: only CoRoute rescue
// advertisements are kept (by service UUID), as an id and a signal strength.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';

import '../../domain/diag/diag_log.dart';
import '../../domain/rescue/proximity_trend.dart';
import '../../domain/rescue/rescue_acoustics.dart';
import '../../domain/rescue/rescue_beacon_detector.dart';
import '../../domain/rescue/rescue_finder_model.dart';
import '../../domain/rescue/rescue_id.dart';
import 'ride_mic_hub.dart';
import 'rescue_native.dart';

/// A rider to find.
class RescueTarget {
  /// The group alert id (empty for a nearby-rider ASSIST incident).
  final String alertId;

  /// The nearby-rider incident id (ASSIST), empty for a group alert.
  final String incidentId;
  final String userId;
  final String name;
  final int rescueId;
  final double lat;
  final double lng;
  final int lastUpdateAt;
  final double? accuracyM;

  const RescueTarget({
    this.alertId = '',
    this.incidentId = '',
    this.userId = '',
    required this.name,
    required this.rescueId,
    this.lat = 0,
    this.lng = 0,
    this.lastUpdateAt = 0,
    this.accuracyM,
  });

  String get key => alertId.isNotEmpty ? alertId : 'net:$incidentId';

  String get firstName {
    final n = name.trim();
    if (n.isEmpty) return 'the rider';
    final i = n.indexOf(' ');
    return i > 0 ? n.substring(0, i) : n;
  }
}

/// What "Ping the phone" did.
enum PingOutcome { sent, wait, offline, noTarget }

class RescueFinderService extends ChangeNotifier {
  RescueFinderService({
    this.hub,
    RescueNativePort? native,
    int Function()? clock,
    required this.groupTargets,
    required this.myPosition,
    this.sendMessage,
    this.online,
    this.notify,
    bool runTimer = true,
  })  : _native = native ?? RescueNative.instance,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _bleSub = _native.sightings.listen(_onSighting);
    if (runTimer) _timer = Timer.periodic(const Duration(seconds: 5), (_) => reevaluate());
  }

  /// The ride's one microphone (null in tests: no acoustic listening).
  final RideMicHub? hub;
  final RescueNativePort _native;
  final int Function() _clock;

  /// Open SOS alerts of OTHER riders in my group (main.dart: from ConvoyService).
  final List<RescueTarget> Function() groupTargets;

  /// My position (0, 0 when unknown).
  final (double, double) Function() myPosition;

  /// Sends a socket message (RealtimeService.send); false when not connected.
  final bool Function(Map<String, dynamic> message)? sendMessage;

  /// The socket is connected.
  final bool Function()? online;

  /// A heads-up while the finder is closed ("You can hear Ravi's rescue beacon").
  final void Function(String title, String body)? notify;

  Timer? _timer;
  StreamSubscription<RescueBleSighting>? _bleSub;
  StreamSubscription<CompassEvent>? _compassSub;
  bool _disposed = false;

  RescueTarget? _finderTarget;
  final Map<String, RescueTarget> _assist = {};
  final RescueBeaconTracker _tracker = RescueBeaconTracker();
  RescueBeaconDetector? _detector;
  final Map<int, ProximityTrend> _ble = {};
  final RescuePingLimiter _pingLimiter = RescuePingLimiter();
  final Set<String> _noticed = {};
  bool _micOn = false;
  bool _bleOn = false;
  bool _bleLowLatency = false;
  double? _heading;
  int _lastNotify = 0;

  /// "Help anyone": also lock on to rescue beacons of riders I am not looking for.
  bool get helpAnyone => _tracker.helpAnyone;
  set helpAnyone(bool v) {
    _tracker.helpAnyone = v;
    notifyListeners();
  }

  RescueTarget? get finderTarget => _finderTarget;
  bool get finderOpen => _finderTarget != null;
  bool get micListening => _micOn && (hub?.wideBandActive ?? false);
  bool get micWanted => _micOn;
  bool get bleScanning => _bleOn;
  double? get heading => _heading;
  int get pingWaitSeconds => _pingLimiter.secondsUntilNext(_clock());

  /// Rescue ids heard that are not the one I am looking for.
  Set<int> get otherBeacons => _tracker.otherIds;

  /// Every rider I could look for now: my group's open SOS alerts and accepted nearby incidents.
  List<RescueTarget> get targets => [...groupTargets(), ..._assist.values];

  RescueTarget? assistTarget(String incidentId) => _assist[incidentId];

  // ---------------------------------------------------------------- finder screen
  void openFinder(RescueTarget t) {
    _finderTarget = t;
    _tracker.targetId = t.rescueId;
    _compassSub ??= FlutterCompass.events?.listen((e) {
      final h = e.heading;
      if (h != null && h.isFinite) {
        _heading = (h + 360) % 360;
        notifyListeners();
      }
    }, onError: (Object _) {});
    DiagLog.info(DiagCat.sos, 'rescue_finder_open', {'id': RescueId.hex(t.rescueId)});
    reevaluate();
  }

  void closeFinder() {
    _finderTarget = null;
    _compassSub?.cancel();
    _compassSub = null;
    _heading = null;
    reevaluate();
  }

  /// The freshest view of the target (position updates come with the alert).
  RescueTarget? currentTarget() {
    final t = _finderTarget;
    if (t == null) return null;
    for (final x in targets) {
      if (x.key == t.key) return x;
    }
    return t;
  }

  /// The target's SOS is no longer open.
  bool get targetClosed {
    final t = _finderTarget;
    if (t == null) return false;
    return !targets.any((x) => x.key == t.key);
  }

  // ---------------------------------------------------------------- nearby-rider (ASSIST) incidents
  /// Socket events: an accepted nearby incident carries `rescueId` (gateway round 10).
  StreamSubscription<Map<String, dynamic>> attachRealtime(Stream<Map<String, dynamic>> events) => events.listen((e) {
        final type = e['type'];
        if (type == 'ASSIST_UPDATE') {
          final id = e['incidentId']?.toString() ?? '';
          final rid = RescueId.parseHex(e['rescueId']);
          final active = const {'ACCEPTED', 'EN_ROUTE', 'ARRIVING', 'ARRIVED'}.contains(e['myStatus']?.toString());
          if (id.isEmpty) return;
          if (rid == null || !active) {
            if (_assist.remove(id) != null) reevaluate();
            return;
          }
          final subject = e['subject'] is Map ? e['subject'] as Map : const {};
          _assist[id] = RescueTarget(
            incidentId: id,
            name: subject['firstName']?.toString() ?? 'the rider',
            rescueId: rid,
            lat: (e['lat'] as num?)?.toDouble() ?? 0,
            lng: (e['lng'] as num?)?.toDouble() ?? 0,
            lastUpdateAt: (e['lastUpdateAt'] as num?)?.toInt() ?? 0,
          );
          reevaluate();
        } else if (type == 'ASSIST_CLOSED') {
          if (_assist.remove(e['incidentId']?.toString() ?? '') != null) reevaluate();
        }
      });

  // ---------------------------------------------------------------- gate
  /// Starts / stops the listeners (every 5 s, on alert changes and when the finder opens / closes).
  void reevaluate() {
    if (_disposed) return;
    final all = targets;
    final (la, ln) = myPosition();
    double? nearest;
    for (final t in all) {
      if ((t.lat == 0 && t.lng == 0) || (la == 0 && ln == 0)) continue;
      final d = RescueFinderModel.guide(FinderInputs(victimLat: t.lat, victimLng: t.lng, myLat: la, myLng: ln)).distanceM;
      if (d != null && (nearest == null || d < nearest)) nearest = d;
    }
    final listen = RescueListenGate.shouldListen(
      openSosOfOther: all.isNotEmpty,
      finderOpen: finderOpen && !targetClosed,
      distanceToVictimM: nearest,
      offline: !(online?.call() ?? true),
    );
    final ids = {for (final t in all) if (t.rescueId > 0) t.rescueId};
    _detector?.setTargets(ids);
    _tracker.alsoAccept
      ..clear()
      ..addAll(ids);
    _setMic(listen);
    _setBle(listen, lowLatency: finderOpen);
    final now = _clock();
    _tracker.expire(now);
    _ble.removeWhere((_, t) => now - t.lastAt > 30000);
    notifyListeners();
  }

  void _setMic(bool on) {
    final h = hub;
    if (h == null || on == _micOn) return;
    _micOn = on;
    if (on) {
      _detector = RescueBeaconDetector(
        sampleRate: RideMicHub.wideSampleRate,
        bands: BeaconBand.values,
        targets: {for (final t in targets) if (t.rescueId > 0) t.rescueId},
      );
      h.addWideBandListener(_onFrame);
    } else {
      h.removeWideBandListener(_onFrame);
      _detector = null;
    }
    DiagLog.info(DiagCat.sos, 'rescue_listen', {'mic': on});
  }

  void _setBle(bool on, {required bool lowLatency}) {
    if (on == _bleOn && lowLatency == _bleLowLatency) return;
    _bleOn = on;
    _bleLowLatency = lowLatency;
    _native.bleScan(on: on, lowLatency: lowLatency).ignore();
  }

  void _onFrame(Int16List frame, MicFrameInfo info) {
    final d = _detector;
    if (d == null) return;
    final packets = d.addPcm16(frame);
    if (packets.isEmpty) return;
    final now = _clock();
    var changed = false;
    for (final p in packets) {
      _tracker.onPacket(p, now);
      changed = true;
    }
    if (changed) {
      _maybeNotify(now);
      notifyListeners();
    }
  }

  void _onSighting(RescueBleSighting s) {
    if (!_bleOn) return;
    _ble.putIfAbsent(s.rescueId, () => ProximityTrend()).add(s.atMs, s.rssi.toDouble());
    _maybeNotify(s.atMs);
    if (finderOpen) notifyListeners();
  }

  /// Finder closed and a target's beacon heard: one heads-up per alert.
  void _maybeNotify(int now) {
    if (finderOpen || notify == null || now - _lastNotify < 30000) return;
    for (final t in targets) {
      if (_noticed.contains(t.key)) continue;
      final lock = _tracker.lockFor(t.rescueId, now);
      final ble = _ble[t.rescueId];
      if (lock != null || (ble != null && (ble.smoothed ?? -127) > -95 && ble.count >= 3)) {
        _noticed.add(t.key);
        _lastNotify = now;
        notify!.call('${t.firstName} is close', "You are picking up ${t.firstName}'s rescue beacon. Open CoRoute and tap Find ${t.firstName}.");
        DiagLog.warn(DiagCat.sos, 'rescue_heard_nearby', {'id': RescueId.hex(t.rescueId), 'sound': lock != null, 'ble': ble != null});
        return;
      }
    }
  }

  // ---------------------------------------------------------------- readings for the screen
  FinderGuide guide() {
    final t = currentTarget();
    final now = _clock();
    final (la, ln) = myPosition();
    BeaconLock? lock;
    ProximityTrend? ble;
    if (t != null) {
      lock = _tracker.best(now);
      ble = _ble[t.rescueId];
      if (ble != null && now - ble.lastAt > 15000) ble = null;
    }
    return RescueFinderModel.guide(
      FinderInputs(
        victimLat: t?.lat ?? 0,
        victimLng: t?.lng ?? 0,
        victimFixAgeMs: t == null || t.lastUpdateAt <= 0 ? 0 : (now - t.lastUpdateAt).clamp(0, 1 << 40).toInt(),
        victimAccuracyM: t?.accuracyM,
        myLat: la,
        myLng: ln,
        myHeadingDeg: _heading,
        bleRssi: ble?.smoothed,
        bleTrend: ble?.at(now) ?? TrendDirection.unknown,
        beaconConfirmed: lock != null,
        beaconSnrDb: lock?.snrDb,
        beaconTrend: lock?.trend.at(now) ?? TrendDirection.unknown,
        micListening: micListening,
        bleScanning: _bleOn,
      ),
      name: t?.firstName ?? 'the rider',
    );
  }

  /// 0..1 for the BLE meter (null when not heard).
  double? bleMeter() {
    final t = _finderTarget;
    final b = t == null ? null : _ble[t.rescueId];
    if (b == null || _clock() - b.lastAt > 15000) return null;
    final v = b.smoothed;
    return v == null ? null : BleRanges.meter(v);
  }

  TrendDirection bleTrend() {
    final t = _finderTarget;
    final b = t == null ? null : _ble[t.rescueId];
    return b?.at(_clock()) ?? TrendDirection.unknown;
  }

  /// 0..1 for the locator meter (null when not confirmed): 3 dB = 0, 30 dB = 1.
  double? beaconMeter() {
    final l = _tracker.best(_clock());
    final v = l?.snrDb;
    if (v == null) return null;
    return ((v - 3) / 27).clamp(0.0, 1.0);
  }

  TrendDirection beaconTrend() => _tracker.best(_clock())?.trend.at(_clock()) ?? TrendDirection.unknown;

  // ---------------------------------------------------------------- ping
  /// "Ping the phone": asks the victim's phone, through the server, to play a loud burst now.
  /// INTEGRATION POINT (offline mesh, Agent A): when [online] is false, [meshPing] (if set) is
  /// tried with the rescue id; see docs/quality/ROUND10_RESCUE_NOTES.md.
  PingOutcome ping() {
    final t = currentTarget();
    if (t == null) return PingOutcome.noTarget;
    final now = _clock();
    if (_pingLimiter.secondsUntilNext(now) > 0) return PingOutcome.wait;
    final msg = <String, dynamic>{
      'type': 'RESCUE_PING',
      if (t.alertId.isNotEmpty) 'alertId': t.alertId,
      if (t.incidentId.isNotEmpty) 'incidentId': t.incidentId,
    };
    var sent = (online?.call() ?? true) && (sendMessage?.call(msg) ?? false);
    if (!sent && meshPing != null) {
      try {
        sent = meshPing!(t.rescueId);
      } catch (_) {
        sent = false;
      }
    }
    if (!sent) return PingOutcome.offline;
    _pingLimiter.tryPress(now);
    DiagLog.info(DiagCat.sos, 'rescue_ping_sent', {'id': RescueId.hex(t.rescueId)});
    notifyListeners();
    return PingOutcome.sent;
  }

  /// Set by the offline mesh (Agent A) when it can carry a ping to [rescueId]; true when queued.
  static bool Function(int rescueId)? meshPing;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _bleSub?.cancel();
    _compassSub?.cancel();
    if (_micOn) hub?.removeWideBandListener(_onFrame);
    if (_bleOn) _native.bleScan(on: false).ignore();
    super.dispose();
  }
}
