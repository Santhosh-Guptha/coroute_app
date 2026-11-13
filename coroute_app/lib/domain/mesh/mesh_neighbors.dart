// Round 10 offline link: the neighbour table (who this phone hears directly, how strongly, and the trend) and the
// group picture (every rider's last position and hop distance, heard directly or relayed). Pure Dart, tested in
// test/mesh_router_test.dart and test/mesh_chain_keeper_test.dart.
library;

import 'dart:math' as math;

import 'mesh_messages.dart';

class MeshNeighbor {
  MeshNeighbor(this.id, this.firstSeenMs);

  final int id;
  final int firstSeenMs;
  int lastSeenMs = 0;
  int caps = 0;
  int psm = 0;
  String name = '';
  double? rssiEwma;
  int lastRssi = -127;
  int _lastBeaconSeq = -1;
  int beaconsHeard = 0;
  int beaconsMissed = 0;

  /// Recent (time ms, rssi) samples, newest last, at most [MeshNeighborTable.maxSamples].
  final List<(int, int)> samples = <(int, int)>[];

  bool get longRange => MeshCaps.longRange(caps);
  bool get hasInternet => caps & MeshCaps.internet != 0;

  /// Share of beacons missed (0..1) from the beacon sequence numbers.
  double get beaconLoss => beaconsHeard + beaconsMissed == 0 ? 0 : beaconsMissed / (beaconsHeard + beaconsMissed);
}

class MeshRiderFix {
  const MeshRiderFix({required this.lat, required this.lng, required this.speedKmh, required this.heading, required this.atMs, required this.hops, this.role = 'PACK', this.hasInternet = false});
  final double lat;
  final double lng;
  final double speedKmh;
  final double heading;
  final int atMs;
  final int hops;
  final String role;
  final bool hasInternet;
}

class MeshNeighborTable {
  MeshNeighborTable({this.staleMs = 10000, this.forgetMs = 60000});

  static const int maxSamples = 40;

  /// A neighbour not heard for this long is no longer "active" (but its history is kept until [forgetMs]).
  final int staleMs;
  final int forgetMs;

  final Map<int, MeshNeighbor> _n = <int, MeshNeighbor>{};
  final Map<int, MeshRiderFix> _fixes = <int, MeshRiderFix>{};
  final Map<int, int> _riderCaps = <int, int>{};

  MeshNeighbor? operator [](int id) => _n[id];

  /// How long the rider passed to the last [noteHeard] had been silent before (-1 = never heard before).
  int lastAbsenceMs = -1;
  Iterable<MeshNeighbor> get all => _n.values;
  Map<int, MeshRiderFix> get fixes => _fixes;
  Map<int, int> get riderCaps => _riderCaps;

  List<MeshNeighbor> active(int nowMs) => _n.values.where((e) => nowMs - e.lastSeenMs <= staleMs).toList();

  /// Heard [id] directly (a beacon or any frame it transmitted). Returns true when it is a NEW link (first time, or
  /// back after being stale): the store-and-forward buffer then offers it what it may have missed.
  bool noteHeard(int id, int rssi, int nowMs, {int? caps, int? beaconSeq, int? psm, String? name}) {
    var e = _n[id];
    final isNew = e == null || nowMs - e.lastSeenMs > staleMs;
    lastAbsenceMs = e == null ? -1 : nowMs - e.lastSeenMs;
    e ??= _n[id] = MeshNeighbor(id, nowMs);
    e.lastSeenMs = nowMs;
    if (rssi > -127 && rssi < 20) {
      e.lastRssi = rssi;
      e.rssiEwma = e.rssiEwma == null ? rssi.toDouble() : e.rssiEwma! * 0.7 + rssi * 0.3;
      e.samples.add((nowMs, rssi));
      if (e.samples.length > maxSamples) e.samples.removeAt(0);
    }
    if (caps != null) {
      e.caps = caps;
      _riderCaps[id] = caps;
    }
    if (psm != null) e.psm = psm;
    if (name != null && name.isNotEmpty) e.name = name;
    if (beaconSeq != null) {
      if (e._lastBeaconSeq >= 0) {
        final gap = (beaconSeq - e._lastBeaconSeq) & 0xff;
        if (gap > 1 && gap < 32) e.beaconsMissed += gap - 1;
      }
      e._lastBeaconSeq = beaconSeq;
      e.beaconsHeard++;
      if (e.beaconsHeard + e.beaconsMissed > 200) {
        e.beaconsHeard ~/= 2;
        e.beaconsMissed ~/= 2;
      }
    }
    return isNew;
  }

  void noteCaps(int id, int caps) => _riderCaps[id] = caps;

  void noteFix(int id, MeshRiderFix fix) {
    final cur = _fixes[id];
    if (cur != null && cur.atMs > fix.atMs) return; // never replace a newer fix with an older (store-and-forward) one
    _fixes[id] = fix;
  }

  /// RSSI trend in dB per second over the last [windowMs] (least squares), null with fewer than 4 samples.
  double? rssiSlope(int id, int nowMs, {int windowMs = 15000}) {
    final e = _n[id];
    if (e == null) return null;
    final pts = e.samples.where((s) => nowMs - s.$1 <= windowMs).toList();
    if (pts.length < 4) return null;
    final t0 = pts.first.$1;
    var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
    for (final p in pts) {
      final x = (p.$1 - t0) / 1000.0, y = p.$2.toDouble();
      sx += x;
      sy += y;
      sxx += x * x;
      sxy += x * y;
    }
    final n = pts.length.toDouble();
    final den = n * sxx - sx * sx;
    if (den.abs() < 1e-9) return null;
    return (n * sxy - sx * sy) / den;
  }

  /// Fewest hops to [id] seen recently (0 = direct neighbour), null when unknown.
  int? hopsTo(int id, int nowMs) {
    final e = _n[id];
    if (e != null && nowMs - e.lastSeenMs <= staleMs) return 0;
    final f = _fixes[id];
    if (f == null || nowMs - f.atMs > 30000) return null;
    return f.hops;
  }

  int maxHops(int nowMs) {
    var m = 0;
    for (final e in _fixes.entries) {
      if (nowMs - e.value.atMs <= 30000) m = math.max(m, _n[e.key] != null && nowMs - _n[e.key]!.lastSeenMs <= staleMs ? 0 : e.value.hops);
    }
    return m;
  }

  void prune(int nowMs) {
    _n.removeWhere((_, e) => nowMs - e.lastSeenMs > forgetMs);
    _fixes.removeWhere((_, f) => nowMs - f.atMs > 10 * 60000);
  }

  void clear() {
    _n.clear();
    _fixes.clear();
    _riderCaps.clear();
  }
}
