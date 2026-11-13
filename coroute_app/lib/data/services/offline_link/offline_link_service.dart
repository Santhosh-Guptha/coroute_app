// Round 10 offline link (docs/features_355/offline_long_range_link.md): the free, no-extra-hardware group link for riders
// without signal. Bluetooth 5 LE Long Range (Coded PHY) where the phone supports it (1M PHY otherwise) plus the existing
// UDP path on a shared hotspot; multi-hop relay through riders; any phone with data bridges the group to the server;
// store-and-forward; voice degrading to walkie-talkie clips; a chain-keeper; fully automatic.
//
// This service is the glue: it decides the mode (OfflineModeSwitch), runs one MeshNodeEngine (lib/domain/mesh) over the
// radios, feeds positions and SOS from ConvoyService into the mesh and the mesh's into ConvoyService
// (applyMeshTelemetry, the same entry the 3.55 hotspot mesh uses), bridges to the gateway (MESH_HELLO / MESH_KEY /
// MESH_BRIDGE) and implements the intercom's MeshVoiceGate.
//
// Safety rules kept: nothing here sends or replaces an SMS; the rider's own SIM SMS stays the guaranteed SOS path and
// the 3.55 hotspot mesh (P2pMeshService) keeps running unchanged. The admin switch 'offlineMesh' off -> SOS only (no
// positions / voice over the link). Advisory voice (chain-keeper) goes through the round 7 WarningScheduler gate and is
// silent while any emergency is open.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/permissions/nearby_permission.dart';
import '../../../domain/mesh/mesh_chain_keeper.dart';
import '../../../domain/mesh/mesh_frame.dart';
import '../../../domain/mesh/mesh_link_planner.dart';
import '../../../domain/mesh/mesh_messages.dart';
import '../../../domain/mesh/mesh_node.dart';
import '../../../domain/mesh/mesh_router.dart';
import '../../../domain/mesh/mesh_telemetry_packet.dart';
import '../../../domain/mesh/mesh_transport.dart';
import '../../../domain/mesh/mesh_voice_gate.dart';
import '../../../domain/mesh/offline_link_mode.dart';
import '../../models/network_wire.dart' show EmergencySource;
import '../convoy_service.dart';
import '../feature_flags_service.dart';
import '../realtime_service.dart';
import '../udp_broadcast_mesh_transport.dart';
import 'ble_long_range_transport.dart';
import 'mesh_ble_platform.dart';
import 'mesh_bridge_client.dart';
import 'mesh_voice_link.dart';

/// The ride key on the phone (secure storage) so the link still works after a restart in a dead zone.
class OfflineLinkKeyStore {
  OfflineLinkKeyStore({FlutterSecureStorage? storage}) : _s = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  static const String _k = 'offline_link_ride_key_v1';

  Future<({String groupId, Uint8List key, int epoch})?> load() async {
    try {
      final raw = await _s.read(key: _k);
      if (raw == null) return null;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return (groupId: m['g'] as String, key: base64.decode(m['k'] as String), epoch: (m['e'] as num).toInt());
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String groupId, Uint8List key, int epoch) async {
    try {
      await _s.write(key: _k, value: jsonEncode({'g': groupId, 'k': base64.encode(key), 'e': epoch}));
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      await _s.delete(key: _k);
    } catch (_) {}
  }
}

class OfflineLinkService extends ChangeNotifier implements MeshVoiceGate {
  OfflineLinkService(
    this._rt,
    this._convoy, {
    BleLongRangeTransport? ble,
    MeshTransport? udp,
    OfflineLinkKeyStore? keyStore,
    int Function()? clock,
    bool autoStart = true,
  })  : _ble = ble ?? BleLongRangeTransport(),
        _udp = udp ?? UdpBroadcastMeshTransport(port: udpPort),
        _keys = keyStore ?? OfflineLinkKeyStore(),
        _clock = clock ?? _wall {
    if (autoStart) start();
  }

  static int _wall() => DateTime.now().millisecondsSinceEpoch;

  /// The v2 mesh uses its own UDP port (the 3.55 hotspot mesh keeps 42424).
  static const int udpPort = 42425;

  final RealtimeService _rt;
  final ConvoyService _convoy;
  final BleLongRangeTransport _ble;
  final MeshTransport _udp;
  final OfflineLinkKeyStore _keys;
  final int Function() _clock;
  final int _boot = math.Random.secure().nextInt(1 << 32);

  // ---- hooks (main.dart)
  /// Asks the round 7 WarningScheduler (RoadCareService.mayAdviseFallingBehind) before any advisory is spoken.
  bool Function(String key, String text)? advisoryGate;

  /// Speaks an advisory line (VoiceService, warning priority).
  void Function(String text, String key)? speaker;

  /// Voice packets for the intercom (IntercomService.deliverOfflineVoice).
  void Function(VoicePacket p)? onVoicePacket;

  // ---- state
  final OfflineModeSwitch _switch = OfflineModeSwitch();
  OfflineLinkMode _mode = OfflineLinkMode.off;
  MeshBleCaps _bleCaps = MeshBleCaps.none;
  MeshKeyring? _keyring;
  String? _keyGroup;
  MeshNodeEngine? _engine;
  MeshVoiceLink? _voice;
  MeshTransport? _transport;
  bool _radiosOn = false;
  final Map<String, int> _serverCaps = <String, int>{};
  final Map<int, String> _shortToUser = <int, String>{};
  final Map<int, ({String address, int rssi, int psm, int caps, int firstMs})> _peers = {};
  final BridgeUplink _uplink = BridgeUplink();
  final BridgeDownlinkPlanner _downlink = BridgeDownlinkPlanner();
  final MeshLinkPlanner _linkPlanner = MeshLinkPlanner();
  final ChainKeeper _chain = ChainKeeper();
  final Map<String, bool> _sentSos = <String, bool>{}; // clientId -> resolved sent
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _slow;
  Timer? _fast;
  int _beaconSeq = 0;
  int _beaconAt = 0;
  int _beaconCaps = -1;
  int _radioRestartAt = 0;
  int _lastPosAt = 0;
  int _lastHelloAt = 0;
  int _lastChainAt = 0;
  int _lastDownlinkAt = 0;
  int _lastUplinkAt = 0;
  int _lastUdpRxMs = -1 << 40;
  bool _permAsked = false;
  bool _started = false;
  bool _busy = false;
  int _capsAt = 0;
  StreamSubscription<MeshIncomingPacket>? _incomingSub;
  final Map<int, int> _peerSeen = <int, int>{};
  String _chip = '';

  final ValueNotifier<String?> clipNotice = ValueNotifier<String?>(null);
  final ValueNotifier<String?> chainNotice = ValueNotifier<String?>(null);
  Timer? _chainNoticeTimer;

  OfflineLinkMode get mode => _mode;
  bool get hasRideKey => _keyring != null;
  MeshBleCaps get bleCaps => _bleCaps;
  MeshNodeEngine? get engine => _engine;

  /// The status chip ("Offline link: 5 riders, 2 hops"), '' when there is nothing to show.
  String get chipText => _chip;

  /// "4 of 6 phones support long range" for the group panel ('' outside a group ride).
  String get capabilityLine {
    final c = _convoy.activeConvoy;
    if (c == null || c.isSolo) return '';
    return MeshCapabilityReport.of(c.riders.keys, (uid) => _serverCaps[uid] ?? _engine?.table.riderCaps[meshShortId(uid)]).line;
  }

  int get _myShort => meshShortId(_convoy.myUserId ?? '');

  // --------------------------------------------------------------------------------------------- lifecycle
  void start() {
    if (_started) return;
    _started = true;
    _subs.add(_rt.events.listen(_onEvent));
    _subs.add(_ble.beacons.listen(_onBeacon));
    _subs.add(_ble.linkEvents.listen((_) => _refreshChip()));
    _convoy.addListener(_onConvoy);
    _slow = Timer.periodic(const Duration(seconds: 1), (_) => _onSecond());
    _restoreKey().ignore();
    _loadPermAsked().ignore();
  }

  Future<void> _restoreKey() async {
    final k = await _keys.load();
    final gid = _convoy.activeConvoy?.groupId;
    if (k != null && gid != null && k.groupId == gid && _keyring == null) _setKey(gid, k.key, k.epoch, persist: false);
  }

  Future<void> _loadPermAsked() async {
    try {
      _permAsked = await NearbyPermission.wasAsked();
    } catch (_) {}
  }

  void _onConvoy() {
    final gid = _convoy.activeConvoy?.groupId;
    if (_keyGroup != null && gid != _keyGroup) {
      // Another ride (or none): the old key is useless and must not linger.
      _forgetKey();
    }
    if (_mode == OfflineLinkMode.offline) _syncSos();
  }

  void _setKey(String groupId, Uint8List key, int epoch, {bool persist = true}) {
    if (key.length != 32) return;
    if (_keyGroup == groupId && _keyring != null && listEquals(_keyring!.key, key)) return;
    _stopRadios();
    _engine?.reset();
    _engine = null;
    _keyring = MeshKeyring(key, epoch: epoch);
    _keyGroup = groupId;
    if (persist) _keys.save(groupId, key, epoch).ignore();
  }

  void _forgetKey() {
    _stopRadios();
    _engine?.reset();
    _engine = null;
    _voice?.reset();
    _voice = null;
    _keyring = null;
    _keyGroup = null;
    _sentSos.clear();
    _downlink.reset();
    _uplink.clear();
    _chain.reset();
    _keys.clear().ignore();
  }

  // ------------------------------------------------------------------------------------------ server events
  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'SNAPSHOT':
        _sendHello();
      case 'MESH_KEY':
        final gid = e['groupId']?.toString();
        final k = e['key'];
        if (gid != null && gid == _convoy.activeConvoy?.groupId && k is String) {
          try {
            _setKey(gid, base64.decode(k), (e['epoch'] as num?)?.toInt() ?? 0);
          } catch (_) {}
        }
      case 'MESH_CAPS':
        final caps = e['caps'];
        if (caps is Map) {
          _serverCaps
            ..clear()
            ..addAll({for (final x in caps.entries) x.key.toString(): (x.value as num?)?.toInt() ?? 0});
          notifyListeners();
        }
      case 'MESH_BRIDGE_ACK':
        final acks = e['acks'];
        final eng = _engine;
        if (acks is List && eng != null) {
          for (final a in acks) {
            if (a is! Map) continue;
            final o = (a['o'] as num?)?.toInt();
            final cid = a['cid']?.toString();
            if (o != null && cid != null && cid.isNotEmpty) eng.sendSosAck(o, cid, byServer: true, alertId: a['alertId']?.toString() ?? '');
          }
        }
    }
  }

  Future<void> _sendHello() async {
    if (!_rt.supports('mesh1')) return;
    final c = _convoy.activeConvoy;
    if (c == null || c.isSolo) return;
    if (_capsAt == 0) await _loadCaps();
    _rt.send({'type': 'MESH_HELLO', 'caps': _myCaps() & 0x07});
  }

  int _myCaps() {
    var c = _bleCaps.bits;
    if (_rt.isConnected) c |= MeshCaps.internet;
    if (_voice?.opusEncoder ?? false) c |= MeshCaps.opusEnc;
    if (_convoy.isLowBattery) c |= MeshCaps.lowBattery;
    final me = _convoy.activeConvoy?.riders[_convoy.myUserId];
    if (me?.role == 'LEAD') c |= MeshCaps.lead;
    return c & 0xff;
  }

  // ------------------------------------------------------------------------------------------- mode switching
  bool get _inGroupRide {
    final c = _convoy.activeConvoy;
    return c != null && !c.isSolo && c.tripStatus != 'ENDED';
  }

  bool get _hearsOfflinePeers {
    final eng = _engine;
    if (eng == null) return false;
    return eng.table.active(_clock()).any((n) => n.caps & MeshCaps.internet == 0);
  }

  Future<void> _loadCaps() async {
    _capsAt = _clock();
    _bleCaps = await MeshBlePlatform.instance.caps();
  }

  Future<void> _onSecond() async {
    if (_busy) return;
    _busy = true;
    try {
      await _second();
    } finally {
      _busy = false;
    }
  }

  Future<void> _second() async {
    final now = _clock();
    if (!_inGroupRide) {
      if (_mode != OfflineLinkMode.off) _setMode(OfflineLinkMode.off);
      return;
    }
    // Bluetooth turned on / permission granted later: looked at again every 30 s while not usable.
    if (_capsAt == 0 || (!_bleCaps.usable && now - _capsAt >= 30000)) await _loadCaps();
    if (!_bleCaps.usable && !_permAsked && _bleCaps.available) await _askPermissionsOnce();
    final next = _switch.update(
      nowMs: now,
      inGroupRide: _inGroupRide && _keyring != null,
      radioAvailable: true, // UDP always; BLE when usable
      socketConnected: _rt.isConnected,
      networkAvailable: _rt.linkProblem != LinkProblem.noNetwork,
      hearsOfflinePeers: _hearsOfflinePeers,
    );
    if (next != _mode) _setMode(next);
    if (_mode == OfflineLinkMode.off) return;
    // Bluetooth was turned off and on again (the BLE layer stopped itself): bring the radios back.
    if (_radiosOn && _bleCaps.usable && !_ble.isRunning && now - _radioRestartAt >= 30000) {
      _radioRestartAt = now;
      _stopRadios();
      _startRadios();
    }
    _ensureEngine();
    _applyDuty();
    _refreshBeacon(now);
    _planLinks(now);
    if (_mode == OfflineLinkMode.offline || _mode == OfflineLinkMode.bridge) {
      _sendMyPosition(now);
      if (now - _lastHelloAt >= 3000) {
        _lastHelloAt = now;
        _engine?.caps = _myCaps();
        _engine?.sendHello();
      }
    }
    if (_mode == OfflineLinkMode.offline) {
      _syncSos();
      if (now - _lastChainAt >= 2500) {
        _lastChainAt = now;
        _runChainKeeper(now);
      }
    }
    if (_mode == OfflineLinkMode.bridge) {
      if (now - _lastDownlinkAt >= 5000) {
        _lastDownlinkAt = now;
        _bridgeDownlink(now);
      }
    }
    _refreshChip();
  }

  /// Shared with the pre-ride phone check and the rescue finder ([NearbyPermission]): the system prompt shows at
  /// most once across the app, and not at all when the phone check already got it granted.
  Future<void> _askPermissionsOnce() async {
    _permAsked = true;
    try {
      await NearbyPermission.requestOnce(sdk: _bleCaps.sdk);
    } catch (_) {}
    await _loadCaps();
  }

  void _setMode(OfflineLinkMode m) {
    final was = _mode;
    _mode = m;
    if (m == OfflineLinkMode.off) {
      _stopRadios();
      _voice?.reset();
      _fast?.cancel();
      _fast = null;
    } else {
      _startRadios();
      final active = m == OfflineLinkMode.offline || m == OfflineLinkMode.bridge;
      if (active) {
        _fast ??= Timer.periodic(const Duration(milliseconds: 20), (_) => _onTick());
      } else {
        _fast?.cancel();
        _fast = null;
      }
      if (m == OfflineLinkMode.offline && was != OfflineLinkMode.offline) _syncSos();
    }
    _refreshChip(force: true);
  }

  void _ensureEngine() {
    final k = _keyring;
    if (k == null || _engine != null) return;
    final me = _convoy.activeConvoy?.riders[_convoy.myUserId];
    final eng = MeshNodeEngine(
      keyring: k,
      myId: _myShort,
      boot: _boot,
      clockMs: _clock,
      myName: me?.name ?? 'Rider',
      transmit: (bytes, cls) => _transport?.send(bytes),
      config: MeshRouterConfig(linkBytesPerSec: _linkBytesPerSec()),
    );
    eng.onPosition = _onMeshPosition;
    eng.onSos = _onMeshSos;
    eng.onAlert = _onMeshAlert;
    eng.onFreshFrame = (f, sealed) {
      if (_mode == OfflineLinkMode.bridge && _rt.supports('mesh1') && _uplink.offer(f, sealed, myId: _myShort) && _uplink.urgent) {
        _flushUplink(_clock()); // an SOS goes to the gateway at once
      }
    };
    final voice = MeshVoiceLink(
      engine: eng,
      clockMs: _clock,
      env: _voiceEnv,
      userIdOf: _userIdOf,
      nameOf: _nameOf,
      deliver: (p) => onVoicePacket?.call(p),
    );
    voice.onClipNotice = (n) => clipNotice.value = n;
    eng.onLiveVoice = voice.onLiveVoice;
    eng.onClip = voice.onClip;
    _engine = eng;
    _voice = voice;
  }

  int _linkBytesPerSec() {
    final now = _clock();
    if (now - _lastUdpRxMs < 10000) return 100000; // a shared Wi-Fi / hotspot
    final eng = _engine;
    final coded = _bleCaps.longRange && (eng == null || eng.table.active(now).every((n) => n.longRange));
    return coded ? 6000 : 25000;
  }

  void _startRadios() {
    if (_radiosOn || _keyring == null) return;
    _radiosOn = true;
    _radioRestartAt = _clock();
    _beaconCaps = -1;
    final tag = _keyring!.groupTag.toRadixString(16);
    final parts = <MeshTransport>[_ble];
    if (_mode != OfflineLinkMode.standby) parts.add(_udp);
    final t = MultiMeshTransport(parts);
    _transport = t;
    _incomingSub?.cancel();
    _incomingSub = t.incoming.listen(_onIncoming);
    t.start(joinCode: tag).then((_) => _beaconAt = 0).ignore();
  }

  void _stopRadios() {
    if (!_radiosOn) return;
    _radiosOn = false;
    final t = _transport;
    _transport = null;
    _incomingSub?.cancel();
    _incomingSub = null;
    t?.stop().ignore();
    _peers.clear();
    _peerSeen.clear();
  }

  void _applyDuty() {
    final me = _convoy.activeConvoy?.riders[_convoy.myUserId];
    final sos = _convoy.pendingSos != null;
    final plan = MeshDutyPlan.forMode(_mode, lowBattery: _convoy.isLowBattery, moving: (me?.speedKmh ?? 0) > 3, sosActive: sos);
    _ble.setDuty(plan).ignore();
    _maxLinks = plan.maxLinks;
    if (_maxLinks == 0 && _ble.linked.isNotEmpty) {
      for (final a in _ble.linked.toList()) {
        _ble.disconnect(a).ignore();
      }
    }
    // UDP joins in once the link is past standby (hotspot riders).
    if (_mode != OfflineLinkMode.standby && _transport is MultiMeshTransport && !(_transport as MultiMeshTransport).parts.contains(_udp)) {
      _stopRadios();
      _startRadios();
    }
    _engine?.router.setLinkBytesPerSec(_linkBytesPerSec());
  }

  int _maxLinks = 0;

  void _refreshBeacon(int now) {
    final k = _keyring;
    if (k == null || !_ble.isRunning) return;
    final caps = _myCaps();
    // Every 30 s (the MAC is per minute), and at once when this phone's capabilities change (losing the server link
    // flips the internet bit: that is how a neighbour with signal knows to start bridging).
    if (now - _beaconAt < 30000 && caps == _beaconCaps) return;
    _beaconAt = now;
    _beaconCaps = caps;
    _beaconSeq = (_beaconSeq + 1) & 0xff;
    final b = MeshBeacon(groupTag: k.groupTag, rider: _myShort, seq: _beaconSeq, caps: caps, psm: _ble.psm & 0xff).encode(k, now ~/ 1000);
    _ble.setBeacon(b).ignore();
  }

  void _planLinks(int now) {
    if (_maxLinks == 0) return;
    _ble.expirePending(now);
    _peers.removeWhere((id, _) => now - (_peerSeen[id] ?? 0) > 60000);
    final todo = _linkPlanner.plan(
      myId: _myShort,
      myCoded: _bleCaps.longRange,
      maxLinks: _maxLinks,
      linked: _ble.linked,
      pending: _ble.pending.keys.toSet(),
      peers: _peers,
      nowMs: now,
    );
    for (final c in todo) {
      _ble.connect(c.address, c.psm, coded: c.coded, nowMs: now).ignore();
    }
  }

  void _onTick() => _engine?.tick();

  // ------------------------------------------------------------------------------------------------ radios in
  void _onBeacon(MeshBeaconSighting s) {
    final k = _keyring;
    final eng = _engine;
    if (k == null || eng == null) return;
    final b = MeshBeacon.decode(k, s.data, _clock() ~/ 1000);
    if (b == null || b.rider == _myShort) return;
    final prev = _peers[b.rider];
    _peers[b.rider] = (address: s.address, rssi: s.rssi, psm: b.psm, caps: b.caps, firstMs: prev?.firstMs ?? _clock());
    _peerSeen[b.rider] = _clock();
    eng.onBeacon(b, s.rssi);
  }

  void _onIncoming(MeshIncomingPacket p) {
    final eng = _engine;
    if (eng == null) return;
    if (p.via == 'udp') _lastUdpRxMs = _clock();
    eng.onRadioFrame(p.data, rssi: p.rssi ?? -60, link: p.via);
  }

  // ------------------------------------------------------------------------------------- mesh -> the ride
  String? _userIdOf(int short) {
    final c = _convoy.activeConvoy;
    if (c == null) return null;
    if (_shortToUser.length != c.riders.length) {
      _shortToUser
        ..clear()
        ..addAll({for (final id in c.riders.keys) meshShortId(id): id});
    }
    return _shortToUser[short];
  }

  String _nameOf(int short) {
    final uid = _userIdOf(short);
    return (uid == null ? null : _convoy.activeConvoy?.riders[uid]?.name) ?? 'a rider';
  }

  bool get _sosOnly => !FeatureFlagsService.on('offlineMesh');

  void _onMeshPosition(int origin, MeshPos p, MeshFrame f) {
    if (_sosOnly) return;
    final uid = _userIdOf(origin);
    if (uid == null || uid == _convoy.myUserId) return;
    final rider = _convoy.activeConvoy?.riders[uid];
    _convoy.applyMeshTelemetry(MeshTelemetryPacket(
      joinCodeHash: 0,
      userId: uid,
      userName: rider?.name ?? 'Rider',
      lat: p.lat,
      lng: p.lng,
      speedKmh: p.speedKmh,
      heading: p.heading,
      batteryLevel: p.batteryLevel,
      isCharging: p.isCharging,
      role: p.role,
      isSos: p.sosActive,
      seq: f.seq & 0xffff,
      ttl: f.ttl,
      hopCount: f.hops.clamp(0, 15),
      timestampMs: f.originTimeSec * 1000 - p.fixAgeSec * 1000,
      fuelUsableKm: p.fuelUsableKm,
    ));
  }

  void _onMeshSos(int origin, MeshSos s, MeshFrame f) {
    if (s.resolved) return; // the alert closes when the server confirms (or locally with the rider's own action)
    final uid = _userIdOf(origin);
    if (uid == null || uid == _convoy.myUserId) return;
    _convoy.applyMeshTelemetry(MeshTelemetryPacket(
      joinCodeHash: 0,
      userId: uid,
      userName: s.name.isNotEmpty ? s.name : (_convoy.activeConvoy?.riders[uid]?.name ?? 'Rider'),
      lat: s.lat,
      lng: s.lng,
      speedKmh: s.speedKmh ?? 0,
      heading: s.heading ?? 0,
      isSos: true,
      sosType: _sosTypeFor(s.alertType),
      seq: f.seq & 0xffff,
      ttl: f.ttl,
      hopCount: f.hops.clamp(0, 15),
      timestampMs: s.occurredAtMs,
    ));
  }

  /// Unknown kinds show as CRASH (the most urgent) - never as nothing.
  static String _sosTypeFor(String t) => switch (t) { 'BREAKDOWN' => 'BREAKDOWN', 'MEDICAL' => 'MEDICAL', 'STOPPED' => 'STOPPED', 'CUSTOM' => 'CUSTOM', _ => 'CRASH' };

  void _onMeshAlert(int origin, MeshAlert a, MeshFrame f) {
    if (a.code != MeshAlertCode.chainStretch) return;
    final me = _convoy.activeConvoy?.riders[_convoy.myUserId];
    if (me?.role != 'LEAD') return;
    final advice = _chain.leadNote(nowMs: _clock(), subject: a.subject, name: _nameOf(a.subject), emergency: _emergencyOpen);
    if (advice != null) _advise(advice.key, advice.speech, advice.title);
  }

  bool get _emergencyOpen => _convoy.pendingSos != null || (_convoy.activeConvoy?.activeAlerts.any((x) => !x.resolved) ?? false);

  // ------------------------------------------------------------------------------------- the ride -> mesh
  void _sendMyPosition(int now) {
    final eng = _engine;
    final uid = _convoy.myUserId;
    final me = uid == null ? null : _convoy.activeConvoy?.riders[uid];
    if (eng == null || me == null || (me.lat == 0 && me.lng == 0)) return;
    eng.myPosition = (lat: me.lat, lng: me.lng);
    if (_sosOnly) return;
    final moving = me.speedKmh > 3;
    final every = _convoy.isLowBattery ? 5000 : (moving ? 2000 : 6000);
    if (now - _lastPosAt < every) return;
    _lastPosAt = now;
    eng.sendPosition(MeshPos(
      lat: me.lat,
      lng: me.lng,
      speedKmh: me.speedKmh,
      heading: me.heading,
      batteryLevel: _convoy.currentBatteryLevel,
      role: me.role,
      sosActive: _convoy.pendingSos != null,
      hasInternet: _rt.isConnected,
      fuelUsableKm: me.fuelUsableKm,
    ));
  }

  /// This phone's own SOS not yet confirmed by the server goes over the mesh (store-and-forward resends it until
  /// anyone acknowledges); one the rider closed before it was delivered goes out as resolved.
  void _syncSos() {
    final eng = _engine;
    if (eng == null) return;
    final p = _convoy.pendingSos;
    final c = _convoy.activeConvoy;
    if (p != null && c != null && p.groupId == c.groupId && !_sentSos.containsKey(p.clientId)) {
      _sentSos[p.clientId] = false;
      final me = c.riders[_convoy.myUserId];
      eng.sendSos(MeshSos(
        clientId: p.clientId,
        alertType: p.type.toUpperCase(),
        lat: p.lat,
        lng: p.lng,
        occurredAtMs: p.createdAt,
        auto: p.auto,
        accuracyM: p.accuracyM?.round(),
        speedKmh: p.speedKmh,
        heading: p.heading,
        source: p.source == EmergencySource.crashAuto ? 'CRASH_AUTO' : p.source.wire,
        linkToken: p.linkToken,
        name: me?.name ?? '',
      ));
    }
    // Closed on this phone while offline (the rider is safe): the mesh (and through a bridge, the server) hears it.
    for (final e in _sentSos.entries.where((e) => !e.value).toList()) {
      final stillOpen = p?.clientId == e.key || (c?.activeAlerts.any((a) => a.clientId == e.key && !a.resolved) ?? false);
      if (stillOpen) continue;
      _sentSos[e.key] = true;
      eng.sendSos(MeshSos(clientId: e.key, alertType: 'SOS', lat: 0, lng: 0, occurredAtMs: _clock(), resolved: true));
    }
  }

  // ------------------------------------------------------------------------------------------- chain-keeper
  void _runChainKeeper(int now) {
    final eng = _engine;
    final c = _convoy.activeConvoy;
    final uid = _convoy.myUserId;
    if (eng == null || c == null || uid == null || _sosOnly) return;
    final me = c.riders[uid];
    if (me == null || (me.lat == 0 && me.lng == 0)) return;
    final riders = <ChainRider>[ChainRider(id: _myShort, lat: me.lat, lng: me.lng, lead: me.role == 'LEAD', name: me.name)];
    eng.table.fixes.forEach((id, f) {
      if (now - f.atMs <= 60000 && id != _myShort) riders.add(ChainRider(id: id, lat: f.lat, lng: f.lng, lead: f.role == 'LEAD'));
    });
    if (riders.length < 2) return;
    final order = convoyOrder(riders, meanHeadingDeg: me.heading);
    final advice = _chain.evaluate(nowMs: now, myId: _myShort, order: order, table: eng.table, coded: _bleCaps.longRange, emergency: _emergencyOpen);
    if (advice == null) return;
    _advise(advice.key, advice.speech, advice.title);
    final subject = advice.leadSubject;
    if (subject != null) eng.sendAlert(MeshAlert(code: MeshAlertCode.chainStretch, subject: subject));
  }

  void _advise(String key, String speech, String title) {
    if (_emergencyOpen) return;
    final gate = advisoryGate;
    if (gate == null || gate(key, speech)) speaker?.call(speech, key);
    chainNotice.value = title;
    _chainNoticeTimer?.cancel();
    _chainNoticeTimer = Timer(const Duration(seconds: 8), () => chainNotice.value = null);
  }

  // -------------------------------------------------------------------------------------------------- bridge
  void _bridgeDownlink(int now) {
    final eng = _engine;
    final c = _convoy.activeConvoy;
    final uid = _convoy.myUserId;
    if (eng == null || c == null || uid == null) return;
    // Riders the mesh itself carries (positions heard over the air in the last 30 s, not proxied by a bridge).
    final heard = <int>{for (final e in eng.table.fixes.entries) if (now - e.value.atMs <= 30000) e.key};
    if (!_sosOnly) {
      final ids = _downlink.ridersToProxy(
        riders: [for (final r in c.riders.values) BridgeRider(userId: r.userId, online: r.presence == 'ONLINE', lastSeenMs: r.lastSeenEpochMs, isMeshPeer: r.isMeshPeer)],
        myUserId: uid,
        heardRecently: heard,
        nowMs: now,
      );
      for (final id in ids.take(12)) {
        final r = c.riders[id]!;
        eng.sendPosition(
          MeshPos(lat: r.lat, lng: r.lng, speedKmh: r.speedKmh, heading: r.heading, batteryLevel: r.batteryLevel, isCharging: r.isCharging, role: r.role, hasInternet: true, fixAgeSec: ((now - r.lastSeenEpochMs) ~/ 1000).clamp(0, 65535)),
          proxyOrigin: meshShortId(id),
        );
      }
    }
    final open = [for (final a in c.activeAlerts) if (!a.resolved) (alertId: a.alertId, userId: a.userId, fromMesh: a.source == EmergencySource.meshBeacon || a.alertId.startsWith('mesh_'))];
    for (final aid in _downlink.alertsToProxy(open: open, heardRecently: heard)) {
      final a = c.activeAlerts.firstWhere((x) => x.alertId == aid);
      eng.sendSos(MeshSos(clientId: a.clientId.isNotEmpty ? a.clientId : a.alertId, alertType: a.alertType.toUpperCase(), lat: a.lat, lng: a.lng, occurredAtMs: a.occurredAt, auto: a.auto, name: a.userName), proxyOrigin: meshShortId(a.userId));
    }
  }

  void _flushUplink(int now) {
    if (_mode != OfflineLinkMode.bridge || !_rt.isConnected) {
      _uplink.clear();
      return;
    }
    if (!_uplink.urgent && now - _lastUplinkAt < 1000) return;
    final m = _uplink.take();
    if (m == null) return;
    _lastUplinkAt = now;
    _rt.send(m);
  }

  // ------------------------------------------------------------------------------------------------- the chip
  void _refreshChip({bool force = false}) {
    final now = _clock();
    _flushUplink(now);
    var text = '';
    final eng = _engine;
    if (eng != null && _mode == OfflineLinkMode.offline) {
      final reach = <int>{for (final n in eng.table.active(now)) n.id, for (final e in eng.table.fixes.entries) if (now - e.value.atMs <= 30000) e.key}..remove(_myShort);
      text = offlineLinkChipText(riders: reach.length, maxHops: math.max(1, eng.table.maxHops(now) + 1));
    } else if (eng != null && _mode == OfflineLinkMode.bridge) {
      final n = eng.table.active(now).where((x) => x.caps & MeshCaps.internet == 0).length;
      text = 'Offline link: bridging $n rider${n == 1 ? '' : 's'}';
    }
    if (text != _chip || force) {
      _chip = text;
      notifyListeners();
    }
  }

  // --------------------------------------------------------------------------------------- MeshVoiceGate
  MeshVoiceEnv _voiceEnv() {
    final eng = _engine;
    final now = _clock();
    if (eng == null) return const MeshVoiceEnv(neighbours: 0, maxHops: 0, loss: 1, linkBytesPerSec: 0, coded: false, strongNearLink: false);
    final active = eng.table.active(now);
    final loss = active.isEmpty ? 1.0 : active.map((n) => n.beaconLoss).reduce((a, b) => a + b) / active.length;
    final bps = _linkBytesPerSec();
    return MeshVoiceEnv(
      neighbours: active.length,
      maxHops: math.max(1, eng.table.maxHops(now) + 1),
      loss: loss,
      linkBytesPerSec: bps,
      coded: bps <= 6000,
      strongNearLink: active.any((n) => (n.rssiEwma ?? -127) > -75) && bps > 6000,
    );
  }

  @override
  bool get canTalk => _mode == OfflineLinkMode.offline && _engine != null && !_sosOnly;

  @override
  String codecFor({required bool opusEncoder}) {
    final v = _voice;
    if (v == null) return 'pcm16';
    v.opusEncoder = opusEncoder;
    return v.currentPlan().codec == MeshVoiceCodec.opus ? 'opus1' : 'pcm16';
  }

  @override
  int get opusBitrate => _voice?.currentPlan().bitrate ?? 8000;

  @override
  void send(int kind, Map<String, dynamic> header, Uint8List? payload) {
    if (!canTalk) return;
    _voice?.fromIntercom(kind, header, payload);
  }

  @override
  void dispose() {
    _slow?.cancel();
    _fast?.cancel();
    _chainNoticeTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _incomingSub?.cancel();
    _convoy.removeListener(_onConvoy);
    _stopRadios();
    _voice?.reset();
    clipNotice.dispose();
    chainNotice.dispose();
    super.dispose();
  }
}
