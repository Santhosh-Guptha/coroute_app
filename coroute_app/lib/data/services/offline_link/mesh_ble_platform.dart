// Round 10 offline link: Dart side of "coroute/mesh_ble" (android/.../MeshBleChannel.kt + LongRangeBle.kt). Every failure
// turns into "not available": the offline link then runs on the UDP path only (shared Wi-Fi / hotspot), and the
// existing SOS paths (own SIM SMS first) are untouched. Tests replace [MeshBlePlatform.instance] with a fake.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../domain/mesh/mesh_messages.dart';
import '../../../domain/mesh/offline_link_mode.dart';

class MeshBleCaps {
  const MeshBleCaps({
    this.available = false,
    this.enabled = false,
    this.coded = false,
    this.extended = false,
    this.le2m = false,
    this.l2cap = false,
    this.scanPermission = false,
    this.advertisePermission = false,
    this.connectPermission = false,
    this.sdk = 0,
  });

  final bool available;
  final bool enabled;
  final bool coded;
  final bool extended;
  final bool le2m;
  final bool l2cap;
  final bool scanPermission;
  final bool advertisePermission;
  final bool connectPermission;
  final int sdk;

  static const MeshBleCaps none = MeshBleCaps();

  bool get usable => available && enabled && scanPermission && advertisePermission && connectPermission;
  bool get longRange => coded && extended;

  /// Capability bits for the beacon / HELLO / MESH_HELLO.
  int get bits => (coded ? MeshCaps.codedPhy : 0) | (extended ? MeshCaps.extendedAdv : 0) | (l2cap ? MeshCaps.l2cap : 0);

  factory MeshBleCaps.fromMap(Map<dynamic, dynamic>? m) {
    if (m == null) return none;
    bool b(String k) => m[k] == true;
    return MeshBleCaps(
      available: b('available'),
      enabled: b('enabled'),
      coded: b('coded'),
      extended: b('extended'),
      le2m: b('le2m'),
      l2cap: b('l2cap'),
      scanPermission: b('scanPermission'),
      advertisePermission: b('advertisePermission'),
      connectPermission: b('connectPermission'),
      sdk: (m['sdk'] as num?)?.toInt() ?? 0,
    );
  }
}

class MeshBlePlatform {
  MeshBlePlatform();

  static MeshBlePlatform instance = MeshBlePlatform();
  static const MethodChannel _ch = MethodChannel('coroute/mesh_ble');
  static const EventChannel _ev = EventChannel('coroute/mesh_ble_events');

  Stream<Map<dynamic, dynamic>>? _events;

  bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Stream<Map<dynamic, dynamic>> get events {
    if (!_supported) return const Stream.empty();
    return _events ??= _ev.receiveBroadcastStream().where((e) => e is Map).cast<Map<dynamic, dynamic>>().handleError((Object _) {});
  }

  Future<MeshBleCaps> caps() async {
    if (!_supported) return MeshBleCaps.none;
    try {
      return MeshBleCaps.fromMap(await _ch.invokeMapMethod<dynamic, dynamic>('caps'));
    } catch (_) {
      return MeshBleCaps.none;
    }
  }

  /// Opens the data servers; returns the L2CAP PSM for the beacon (0 = none).
  Future<int> start(int groupTag) async {
    if (!_supported) return 0;
    try {
      return await _ch.invokeMethod<int>('start', {'tag': groupTag}) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> setBeacon(Uint8List beacon) => _call('setBeacon', {'beacon': beacon});

  Future<void> setDuty(MeshDutyPlan plan) => _call('setDuty', {'scan': plan.scan.name, 'advMs': plan.advIntervalMs, 'txHigh': plan.txPowerHigh});

  Future<void> connect(String addr, int psm, {required bool coded}) => _call('connect', {'addr': addr, 'psm': psm, 'coded': coded});

  Future<void> disconnect(String addr) => _call('disconnect', {'addr': addr});

  Future<int> send(Uint8List data) async {
    if (!_supported) return 0;
    try {
      return await _ch.invokeMethod<int>('send', {'data': data}) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> stop() => _call('stop', const {});

  Future<void> _call(String m, Map<String, dynamic> args) async {
    if (!_supported) return;
    try {
      await _ch.invokeMethod<void>(m, args);
    } catch (e) {
      debugPrint('mesh_ble $m: $e');
    }
  }
}
