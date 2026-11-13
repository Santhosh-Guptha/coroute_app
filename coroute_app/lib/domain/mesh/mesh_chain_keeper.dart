// Round 10 offline link: the chain-keeper. A convoy on the offline link is a chain of radio links, rider to rider. When
// the link from this rider to the rider right BEHIND them is about to break (RSSI falling towards the radio's floor,
// or the distance growing towards the radio's range), this rider is the one "at the gap": they hear
// "Signal chain stretching, ease off a little." and the lead gets a note over the mesh:
// "Group link stretched behind Ravi, slow down."
//
// Rules: advisory only (it goes through the round 7 WarningScheduler as a falling-behind warning, never over an SOS or
// a crash alarm: [evaluate] returns nothing while an emergency is open); at most one warning per gap every
// [ChainKeeperConfig.perGapMs] and one a minute overall; it needs a real trend (a falling RSSI or a growing gap), not one
// weak sample. Pure Dart, tested in test/mesh_chain_keeper_test.dart.
library;

import 'dart:math' as math;

import 'mesh_neighbors.dart';
import 'mesh_router.dart' show meshDistanceM;

class ChainKeeperConfig {
  const ChainKeeperConfig({
    this.horizonSec = 25,
    this.perGapMs = 120000,
    this.minGapMs = 60000,
    this.leadPerSubjectMs = 90000,
    this.codedBreakRssi = -100,
    this.oneMBreakRssi = -92,
    this.codedRangeM = 450,
    this.oneMRangeM = 150,
    this.minRssiSlope = -0.25,
    this.minGapRateMps = 0.4,
  });

  /// Warn when the link is predicted to break within this many seconds.
  final int horizonSec;
  final int perGapMs;
  final int minGapMs;
  final int leadPerSubjectMs;

  /// RSSI where the link is lost (Coded PHY S8 sensitivity on phones is about -103..-105 dBm; a margin is kept).
  final int codedBreakRssi;
  final int oneMBreakRssi;

  /// Realistic bike-to-bike range on an open road (docs/features_355/offline_long_range_link.md).
  final double codedRangeM;
  final double oneMRangeM;

  /// A trend is needed: RSSI falling faster than this (dB/s) or the gap growing faster than this (m/s).
  final double minRssiSlope;
  final double minGapRateMps;
}

class ChainAdvice {
  const ChainAdvice({required this.key, required this.speech, required this.title, this.leadSubject, this.secondsToBreak});
  final String key;
  final String speech;
  final String title;

  /// Set when the lead should be told: the rider in front of the gap (this rider's short id).
  final int? leadSubject;
  final double? secondsToBreak;
}

/// One rider in convoy order.
class ChainRider {
  const ChainRider({required this.id, required this.lat, required this.lng, this.lead = false, this.name = ''});
  final int id;
  final double lat;
  final double lng;
  final bool lead;
  final String name;
}

/// Orders the riders front to back: distance from the lead (or, without a lead, from the rider farthest ahead along
/// the group's mean heading).
List<ChainRider> convoyOrder(List<ChainRider> riders, {double? meanHeadingDeg}) {
  if (riders.length < 2) return List.of(riders);
  ChainRider? front = riders.where((r) => r.lead).firstOrNull;
  if (front == null) {
    final h = (meanHeadingDeg ?? 0) * math.pi / 180;
    final lat0 = riders.first.lat;
    double proj(ChainRider r) {
      final x = (r.lng - riders.first.lng) * math.cos(lat0 * math.pi / 180);
      final y = r.lat - lat0;
      return x * math.sin(h) + y * math.cos(h);
    }

    front = riders.reduce((a, b) => proj(a) >= proj(b) ? a : b);
  }
  final f = front;
  final out = List.of(riders)..sort((a, b) => meshDistanceM(f.lat, f.lng, a.lat, a.lng).compareTo(meshDistanceM(f.lat, f.lng, b.lat, b.lng)));
  return out;
}

class ChainKeeper {
  ChainKeeper({this.config = const ChainKeeperConfig()});

  final ChainKeeperConfig config;
  final Map<int, List<(int, double)>> _gaps = <int, List<(int, double)>>{};
  final Map<String, int> _lastPerGap = <String, int>{};
  final Map<int, int> _lastLead = <int, int>{};
  int _lastAny = -1 << 40;

  /// Predicted seconds until the link breaks (null = no break predicted).
  static double? secondsToBreak({required double rssi, double? rssiSlope, required int breakRssi, double? gapM, double? gapRateMps, required double rangeM}) {
    double? t;
    if (rssiSlope != null && rssiSlope < 0) {
      t = math.max(0, (rssi - breakRssi) / -rssiSlope);
    }
    if (gapM != null && gapRateMps != null && gapRateMps > 0) {
      final td = math.max(0.0, (rangeM - gapM) / gapRateMps);
      t = t == null ? td : math.min(t, td);
    }
    return t;
  }

  double? _gapRate(int peer, int nowMs, double gap) {
    final list = _gaps.putIfAbsent(peer, () => <(int, double)>[]);
    list.add((nowMs, gap));
    list.removeWhere((e) => nowMs - e.$1 > 20000);
    if (list.length < 3) return null;
    final dt = (list.last.$1 - list.first.$1) / 1000.0;
    if (dt < 4) return null;
    return (list.last.$2 - list.first.$2) / dt;
  }

  /// This rider's own gap (to the rider right behind). Call every 2-3 s while the offline link runs.
  ChainAdvice? evaluate({
    required int nowMs,
    required int myId,
    required List<ChainRider> order,
    required MeshNeighborTable table,
    required bool coded,
    required bool emergency,
  }) {
    final i = order.indexWhere((r) => r.id == myId);
    if (i < 0 || i + 1 >= order.length) return null;
    final me = order[i], behind = order[i + 1];
    final n = table[behind.id];
    if (n == null || nowMs - n.lastSeenMs > table.staleMs || n.rssiEwma == null) return null; // not my link (or already gone)
    final gap = meshDistanceM(me.lat, me.lng, behind.lat, behind.lng);
    final gapRate = _gapRate(behind.id, nowMs, gap);
    final slope = table.rssiSlope(behind.id, nowMs);
    if (emergency) return null;
    final trending = (slope != null && slope <= config.minRssiSlope) || (gapRate != null && gapRate >= config.minGapRateMps);
    if (!trending) return null;
    final t = secondsToBreak(
      rssi: n.rssiEwma!,
      rssiSlope: slope,
      breakRssi: coded ? config.codedBreakRssi : config.oneMBreakRssi,
      gapM: gap,
      gapRateMps: gapRate,
      rangeM: coded ? config.codedRangeM : config.oneMRangeM,
    );
    if (t == null || t > config.horizonSec) return null;
    final key = 'CHAIN_${myId.toRadixString(16)}_${behind.id.toRadixString(16)}';
    if (nowMs - (_lastPerGap[key] ?? -1 << 40) < config.perGapMs || nowMs - _lastAny < config.minGapMs) return null;
    _lastPerGap[key] = nowMs;
    _lastAny = nowMs;
    return ChainAdvice(
      key: key,
      speech: 'Signal chain stretching, ease off a little.',
      title: 'Offline link stretching',
      leadSubject: me.lead ? null : myId,
      secondsToBreak: t,
    );
  }

  /// The lead heard (over the mesh) that the chain is stretching behind [name].
  ChainAdvice? leadNote({required int nowMs, required int subject, required String name, required bool emergency}) {
    if (emergency) return null;
    if (nowMs - (_lastLead[subject] ?? -1 << 40) < config.leadPerSubjectMs) return null;
    _lastLead[subject] = nowMs;
    final who = name.trim().isEmpty ? 'a rider' : name.trim();
    return ChainAdvice(
      key: 'CHAIN_LEAD_${subject.toRadixString(16)}',
      speech: 'Group link stretched behind $who, slow down.',
      title: 'Group link stretched',
    );
  }

  void reset() {
    _gaps.clear();
    _lastPerGap.clear();
    _lastLead.clear();
    _lastAny = -1 << 40;
  }
}
