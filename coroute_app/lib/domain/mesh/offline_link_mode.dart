// Round 10 offline link: automatic switching, radio duty cycles and the group capability report. Pure Dart, tested in
// test/mesh_mode_test.dart.
//
// Modes (no rider action, no hotspot):
//   off      not in a group ride (or no Bluetooth LE): radios off, nothing runs.
//   standby  group ride, server link healthy: a slow, low-power beacon and a low-power scan, so a phone that loses
//            signal is noticed by its neighbours within seconds. No connections.
//   bridge   server link healthy AND a rider in range has lost signal: this phone carries the mesh to the gateway and
//            the gateway's room traffic back (MESH_BRIDGE), with a balanced duty cycle.
//   offline  the ride socket has been down for [OfflineModeSwitch.downAfterMs] (or the network is gone for
//            [OfflineModeSwitch.noNetworkAfterMs]): full mesh, connections, store-and-forward, voice over the mesh.
// Leaving offline needs the socket healthy for [OfflineModeSwitch.upAfterMs] (hysteresis: a flapping link at the edge
// of coverage does not toggle the radios every few seconds).
library;

import 'mesh_messages.dart';

enum OfflineLinkMode { off, standby, bridge, offline }

class OfflineModeSwitch {
  OfflineModeSwitch({this.downAfterMs = 8000, this.noNetworkAfterMs = 3000, this.upAfterMs = 10000});

  final int downAfterMs;
  final int noNetworkAfterMs;
  final int upAfterMs;

  OfflineLinkMode _mode = OfflineLinkMode.off;
  int? _downSince;
  int? _upSince;
  int? _noNetSince;

  OfflineLinkMode get mode => _mode;

  OfflineLinkMode update({
    required int nowMs,
    required bool inGroupRide,
    required bool radioAvailable,
    required bool socketConnected,
    required bool networkAvailable,
    required bool hearsOfflinePeers,
  }) {
    if (!inGroupRide || !radioAvailable) {
      _downSince = _upSince = _noNetSince = null;
      return _mode = OfflineLinkMode.off;
    }
    if (socketConnected) {
      _downSince = null;
      _upSince ??= nowMs;
    } else {
      _upSince = null;
      _downSince ??= nowMs;
    }
    if (networkAvailable) {
      _noNetSince = null;
    } else {
      _noNetSince ??= nowMs;
    }
    final goOffline = !socketConnected &&
        ((nowMs - _downSince! >= downAfterMs) || (_noNetSince != null && nowMs - _noNetSince! >= noNetworkAfterMs));
    if (_mode == OfflineLinkMode.offline) {
      final healthy = socketConnected && nowMs - _upSince! >= upAfterMs;
      if (!healthy) return _mode;
    } else if (goOffline) {
      return _mode = OfflineLinkMode.offline;
    }
    if (!socketConnected) {
      // Socket down but not long enough yet: keep what we had (standby / bridge keep listening).
      return _mode = _mode == OfflineLinkMode.off ? OfflineLinkMode.standby : _mode;
    }
    return _mode = hearsOfflinePeers ? OfflineLinkMode.bridge : OfflineLinkMode.standby;
  }

  void reset() {
    _mode = OfflineLinkMode.off;
    _downSince = _upSince = _noNetSince = null;
  }
}

enum MeshScanMode { off, lowPower, balanced, lowLatency }

/// Radio settings for a mode. Android's own scan modes: LOW_POWER scans 0.5 s every 5 s (10 %), BALANCED 1 s every
/// 4 s (25 %), LOW_LATENCY continuously (100 %).
class MeshDutyPlan {
  const MeshDutyPlan({required this.scan, required this.advIntervalMs, required this.txPowerHigh, required this.maxLinks, required this.estimatedMilliAmps});
  final MeshScanMode scan;

  /// 0 = not advertising.
  final int advIntervalMs;
  final bool txPowerHigh;

  /// Connection-oriented links (L2CAP / GATT) to keep (0 = beacons only).
  final int maxLinks;

  /// Paper estimate of the extra current (docs/features_355/offline_long_range_link.md, "Battery").
  final double estimatedMilliAmps;

  static const MeshDutyPlan off = MeshDutyPlan(scan: MeshScanMode.off, advIntervalMs: 0, txPowerHigh: false, maxLinks: 0, estimatedMilliAmps: 0);

  static MeshDutyPlan forMode(OfflineLinkMode mode, {bool lowBattery = false, bool moving = true, bool sosActive = false}) {
    switch (mode) {
      case OfflineLinkMode.off:
        return off;
      case OfflineLinkMode.standby:
        return const MeshDutyPlan(scan: MeshScanMode.lowPower, advIntervalMs: 1000, txPowerHigh: false, maxLinks: 0, estimatedMilliAmps: 1.5);
      case OfflineLinkMode.bridge:
        return const MeshDutyPlan(scan: MeshScanMode.balanced, advIntervalMs: 250, txPowerHigh: true, maxLinks: 3, estimatedMilliAmps: 6);
      case OfflineLinkMode.offline:
        if (sosActive) {
          return const MeshDutyPlan(scan: MeshScanMode.lowLatency, advIntervalMs: 100, txPowerHigh: true, maxLinks: 4, estimatedMilliAmps: 14);
        }
        if (lowBattery || !moving) {
          return const MeshDutyPlan(scan: MeshScanMode.balanced, advIntervalMs: 250, txPowerHigh: true, maxLinks: 3, estimatedMilliAmps: 6);
        }
        return const MeshDutyPlan(scan: MeshScanMode.lowLatency, advIntervalMs: 250, txPowerHigh: true, maxLinks: 4, estimatedMilliAmps: 12);
    }
  }
}

/// "4 of 6 phones support long range" for the ride's group panel.
class MeshCapabilityReport {
  const MeshCapabilityReport({required this.total, required this.known, required this.longRange});
  final int total;
  final int known;
  final int longRange;

  /// Builds the report from every rider's capability bits (server MESH_CAPS and mesh beacons), null = not reported.
  static MeshCapabilityReport of(Iterable<String> riderIds, int? Function(String userId) capsOf) {
    var total = 0, known = 0, lr = 0;
    for (final id in riderIds) {
      total++;
      final c = capsOf(id);
      if (c == null) continue;
      known++;
      if (MeshCaps.longRange(c)) lr++;
    }
    return MeshCapabilityReport(total: total, known: known, longRange: lr);
  }

  /// Panel line, e.g. "4 of 6 phones support long range"; "(2 not checked yet)" when some phones have not reported.
  String get line {
    if (total == 0) return '';
    final base = '$longRange of $total phone${total == 1 ? '' : 's'} support${longRange == 1 ? 's' : ''} long range';
    final unknown = total - known;
    return unknown > 0 ? '$base ($unknown not checked yet)' : base;
  }
}

/// "Offline link: 5 riders, 2 hops" (the status chip).
String offlineLinkChipText({required int riders, required int maxHops}) {
  if (riders <= 0) return 'Offline link: searching for riders';
  final r = '$riders rider${riders == 1 ? '' : 's'}';
  return maxHops <= 1 ? 'Offline link: $r' : 'Offline link: $r, $maxHops hops';
}
