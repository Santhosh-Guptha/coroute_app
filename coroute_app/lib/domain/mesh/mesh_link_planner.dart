// Round 10 offline link: which riders to open Bluetooth links to (pure; tested in test/mesh_bridge_link_test.dart).
// Up to the duty plan's link budget, strongest beacon first; the rider with the LOWER short id opens the link (no
// duplicate links), the other side opens it itself if nothing happened after [MeshLinkPlanner.connectFallbackMs].
// Coded PHY is asked for only when both phones support it (1M otherwise).
library;

import 'mesh_messages.dart';

/// Which peers to open links to (pure).
class MeshLinkPlanner {
  MeshLinkPlanner({this.connectFallbackMs = 10000, this.maxPending = 2});

  final int connectFallbackMs;
  final int maxPending;

  /// [peers]: rider id -> (address, rssi, psm, caps, first heard ms). Returns the addresses to connect now.
  List<({String address, int psm, bool coded})> plan({
    required int myId,
    required bool myCoded,
    required int maxLinks,
    required Set<String> linked,
    required Set<String> pending,
    required Map<int, ({String address, int rssi, int psm, int caps, int firstMs})> peers,
    required int nowMs,
  }) {
    final room = maxLinks - linked.length - pending.length;
    if (room <= 0 || pending.length >= maxPending) return const [];
    final cands = peers.entries
        .where((e) => !linked.contains(e.value.address) && !pending.contains(e.value.address))
        .where((e) => myId < e.key || nowMs - e.value.firstMs >= connectFallbackMs)
        .toList()
      ..sort((a, b) => b.value.rssi.compareTo(a.value.rssi));
    return [
      for (final e in cands.take(room.clamp(0, maxPending - pending.length)))
        (address: e.value.address, psm: e.value.psm, coded: myCoded && e.value.caps & MeshCaps.codedPhy != 0),
    ];
  }
}

