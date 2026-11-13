// Round 10 offline link: the Bluetooth LE Long Range transport behind the existing [MeshTransport] interface, plus a
// combined transport (BLE + the existing UDP broadcast path for phones that happen to share Wi-Fi / a hotspot).
//
// Link management (pure decisions in lib/domain/mesh/mesh_link_planner.dart): from the beacons heard, keep up to the duty plan's
// [MeshDutyPlan.maxLinks] links, strongest first; the rider with the LOWER short id opens the link (no duplicate links),
// the other side opens it itself if nothing happened after [connectFallbackMs]. Coded PHY is asked for only when both
// phones support it; otherwise 1M (the fallback for phones without Coded PHY).
library;

import 'dart:async';
import 'dart:typed_data';

import '../../../domain/mesh/mesh_transport.dart';
import '../../../domain/mesh/offline_link_mode.dart';
import 'mesh_ble_platform.dart';

class MeshBeaconSighting {
  const MeshBeaconSighting({required this.address, required this.rssi, required this.data, required this.coded, required this.atMs});
  final String address;
  final int rssi;
  final Uint8List data;
  final bool coded;
  final int atMs;
}

class BleLongRangeTransport implements MeshTransport {
  BleLongRangeTransport({MeshBlePlatform? platform}) : _p = platform ?? MeshBlePlatform.instance;

  final MeshBlePlatform _p;
  final StreamController<MeshIncomingPacket> _incoming = StreamController<MeshIncomingPacket>.broadcast();
  final StreamController<MeshBeaconSighting> _beacons = StreamController<MeshBeaconSighting>.broadcast();
  final StreamController<({String address, bool up})> _linkEvents = StreamController<({String address, bool up})>.broadcast();
  StreamSubscription<Map<dynamic, dynamic>>? _sub;
  bool _running = false;
  int psm = 0;
  MeshBleCaps caps = MeshBleCaps.none;
  final Map<String, int> _rssi = <String, int>{};
  final Set<String> linked = <String>{};
  final Map<String, int> pending = <String, int>{};

  @override
  bool get isRunning => _running;
  @override
  Stream<MeshIncomingPacket> get incoming => _incoming.stream;
  Stream<MeshBeaconSighting> get beacons => _beacons.stream;
  Stream<({String address, bool up})> get linkEvents => _linkEvents.stream;

  /// [joinCode] carries the group tag as hex (the BLE layer filters on it in hardware).
  @override
  Future<void> start({required String joinCode, int port = 0}) async {
    caps = await _p.caps();
    if (!caps.usable) return;
    _sub ??= _p.events.listen(_onEvent);
    psm = await _p.start(int.tryParse(joinCode, radix: 16) ?? -1);
    _running = true;
  }

  Future<void> setBeacon(Uint8List b) => _running ? _p.setBeacon(b) : Future.value();
  Future<void> setDuty(MeshDutyPlan plan) => _running ? _p.setDuty(plan) : Future.value();

  Future<void> connect(String addr, int peerPsm, {required bool coded, required int nowMs}) async {
    if (!_running) return;
    pending[addr] = nowMs;
    await _p.connect(addr, peerPsm, coded: coded);
  }

  Future<void> disconnect(String addr) => _p.disconnect(addr);

  /// Pending connects older than 15 s are forgotten (the stack never answered).
  void expirePending(int nowMs) => pending.removeWhere((_, t) => nowMs - t > 15000);

  void _onEvent(Map<dynamic, dynamic> e) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final addr = e['addr']?.toString() ?? '';
    switch (e['t']) {
      case 'beacon':
        final data = e['data'];
        final rssi = (e['rssi'] as num?)?.toInt() ?? -127;
        if (data is Uint8List) {
          _rssi[addr] = rssi;
          _beacons.add(MeshBeaconSighting(address: addr, rssi: rssi, data: data, coded: e['phy'] == 3, atMs: now));
        }
      case 'frame':
        final data = e['data'];
        if (data is Uint8List) {
          _incoming.add(MeshIncomingPacket(data: data, senderAddress: addr, senderPort: 0, receivedAtMs: now, rssi: _rssi[addr], via: e['via']?.toString() ?? 'ble'));
        }
      case 'rssi':
        final r = (e['rssi'] as num?)?.toInt();
        if (r != null) _rssi[addr] = r;
      case 'link':
        final up = e['up'] == true;
        pending.remove(addr);
        if (up) {
          linked.add(addr);
        } else {
          linked.remove(addr);
        }
        _linkEvents.add((address: addr, up: up));
      case 'state':
        if (e['enabled'] != true) {
          _running = false;
          linked.clear();
          pending.clear();
        }
    }
  }

  @override
  void send(Uint8List data) {
    if (_running && linked.isNotEmpty) _p.send(data).ignore();
  }

  @override
  Future<void> stop() async {
    _running = false;
    linked.clear();
    pending.clear();
    await _p.stop();
  }
}

/// Several transports as one: sends on all, merges what they receive (the router drops the duplicates).
class MultiMeshTransport implements MeshTransport {
  MultiMeshTransport(this.parts);
  final List<MeshTransport> parts;
  final StreamController<MeshIncomingPacket> _incoming = StreamController<MeshIncomingPacket>.broadcast();
  final List<StreamSubscription<MeshIncomingPacket>> _subs = [];

  @override
  bool get isRunning => parts.any((p) => p.isRunning);
  @override
  Stream<MeshIncomingPacket> get incoming => _incoming.stream;

  @override
  Future<void> start({required String joinCode, int port = 0}) async {
    for (final p in parts) {
      try {
        await p.start(joinCode: joinCode); // each part keeps its own port (UDP: 42425)
      } catch (_) {}
      _subs.add(p.incoming.listen(_incoming.add));
    }
  }

  @override
  void send(Uint8List data) {
    for (final p in parts) {
      if (p.isRunning) p.send(data);
    }
  }

  @override
  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final p in parts) {
      try {
        await p.stop();
      } catch (_) {}
    }
  }
}
