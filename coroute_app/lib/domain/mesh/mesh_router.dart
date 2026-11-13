// Round 10 offline link: group-scoped flooding with deduplication, hop limits, relay suppression and a priority
// scheduler with per-class budgets. Pure Dart (the caller owns the clock and the radio); unit tested in
// test/mesh_router_test.dart and exercised end to end by test/mesh_simulation_test.dart.
//
// Flooding: every rider relays a fresh frame once, after a short back-off, unless
//   * its TTL is used up (hop limit), or
//   * counter-based suppression: it heard the same frame relayed [MeshRouterConfig.suppressAfter] times while waiting
//     (dense groups: only a few relays go out), or
//   * progress suppression: the rider it heard it from is already at least [MeshRouterConfig.progressMarginM] farther
//     from the origin than this rider is (the flood has passed here; every frame carries its last transmitter's
//     position, the origin's position is its latest position message).
// The back-off is SHORTER when the frame was heard weakly (this rider is near the edge of the sender's range, so its
// relay covers the most new ground) and longer when heard strongly: edge riders relay first and the others hear them
// and stand down. An SOS is never suppressed (each rider relays it once, after the shortest back-off).
//
// Scheduling: strict priority SOS > alerts > positions > voice > chat, with a byte budget per class out of the link's
// airtime, so voice can never starve SOS (SOS is never budget-limited and always goes first; voice is capped at
// [MeshRouterConfig.voiceShare] of the airtime). Positions are latest-only per rider in the queue; live voice older
// than [MeshRouterConfig.liveVoiceMaxQueueMs] is dropped (late audio is useless; clips are not live and wait).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'mesh_frame.dart';

class MeshRouterConfig {
  const MeshRouterConfig({
    this.linkBytesPerSec = 6000,
    this.alertShare = 0.15,
    this.positionShare = 0.35,
    this.voiceShare = 0.5,
    this.chatShare = 0.1,
    this.suppressAfter = const {MeshClass.alert: 3, MeshClass.position: 2, MeshClass.voice: 1, MeshClass.chat: 2},
    this.liveVoiceMaxQueueMs = 300,
    this.maxQueuePerClass = 64,
    this.progressMarginM = 50,
  });

  /// Usable airtime of the radio in bytes per second (Coded PHY S8 with L2CAP: about 4-8 KB/s; 1M PHY ~25 KB/s;
  /// Wi-Fi far more). The service updates it from the active transports.
  final int linkBytesPerSec;
  final double alertShare;
  final double positionShare;
  final double voiceShare;
  final double chatShare;

  /// Duplicates heard while waiting that cancel this rider's relay (SOS: never).
  final Map<MeshClass, int> suppressAfter;
  final int liveVoiceMaxQueueMs;
  final int maxQueuePerClass;
  final double progressMarginM;

  MeshRouterConfig copyWith({int? linkBytesPerSec}) => MeshRouterConfig(
        linkBytesPerSec: linkBytesPerSec ?? this.linkBytesPerSec,
        alertShare: alertShare,
        positionShare: positionShare,
        voiceShare: voiceShare,
        chatShare: chatShare,
        suppressAfter: suppressAfter,
        liveVoiceMaxQueueMs: liveVoiceMaxQueueMs,
        maxQueuePerClass: maxQueuePerClass,
        progressMarginM: progressMarginM,
      );
}

/// Default hop limits per class (a 1 km line of riders 150-400 m apart needs 3-6 hops).
int meshDefaultTtl(MeshClass c) => switch (c) {
      MeshClass.sos => 8,
      MeshClass.alert => 6,
      MeshClass.position => 5,
      MeshClass.voice => 4,
      MeshClass.chat => 5,
      MeshClass.control => 1,
    };

class MeshRxMeta {
  const MeshRxMeta({required this.rssi, required this.atMs, this.link = ''});
  final int rssi;
  final int atMs;
  final String link;
}

class _Pending {
  _Pending(this.frame, this.sealed, this.fireAt);
  final MeshFrame frame;
  final Uint8List sealed;
  final int fireAt;
  int heard = 0;
  bool cancelled = false;
}

class _Queued {
  _Queued(this.bytes, this.cls, this.at, {this.originKey, this.live = false});
  final Uint8List bytes;
  final MeshClass cls;
  final int at;
  final int? originKey;
  final bool live;
}

class _Bucket {
  _Bucket(this.rate, this.burst, int t)
      : tokens = burst,
        at = t;
  double rate;
  double burst;
  double tokens;
  int at;
  void refill(int t) {
    if (t > at) {
      tokens = math.min(burst, tokens + (t - at) / 1000.0 * rate);
      at = t;
    }
  }
}

class MeshRouterStats {
  int originated = 0;
  int received = 0;
  int delivered = 0;
  int duplicates = 0;
  int rejected = 0;
  int relayed = 0;
  int suppressed = 0;
  int ttlExpired = 0;
  int droppedLate = 0;
  int droppedFull = 0;
  final Map<MeshClass, int> txByClass = {for (final c in MeshClass.values) c: 0};
  final Map<MeshClass, int> txBytesByClass = {for (final c in MeshClass.values) c: 0};
}

class MeshRouter {
  MeshRouter({
    required this.codec,
    required this.myId,
    required this.boot,
    required this.transmit,
    required this.clockMs,
    MeshRouterConfig config = const MeshRouterConfig(),
    math.Random? random,
    this.onDeliver,
    this.myPosition,
    this.positionOf,
  })  : _cfg = config,
        _random = random ?? math.Random() {
    _initBuckets(clockMs());
  }

  final MeshFrameCodec codec;
  final int myId;
  final int boot;

  /// Puts bytes on the air (all transports). The router calls it from [tick] only.
  final void Function(Uint8List bytes, MeshClass cls) transmit;
  final int Function() clockMs;
  final math.Random _random;

  /// A fresh, authenticated frame for this phone (also called for frames this phone relays).
  void Function(MeshFrame frame, MeshRxMeta meta)? onDeliver;

  /// This rider's position, when known.
  ({double lat, double lng})? Function()? myPosition;

  /// A rider's last known position (for progress suppression), when known.
  ({double lat, double lng})? Function(int shortId)? positionOf;

  MeshRouterConfig _cfg;
  MeshRouterConfig get config => _cfg;
  final ReplayGuard replay = ReplayGuard();
  final MeshRouterStats stats = MeshRouterStats();

  /// The sealed bytes of the last frame [originate] produced, and of the frame being delivered right now.
  Uint8List? lastSealed;
  Uint8List? lastReceived;

  int _seq = 0;
  final Map<int, int> _proxySeq = <int, int>{};
  final Map<String, _Pending> _pending = <String, _Pending>{};
  final Map<MeshClass, List<_Queued>> _queues = {for (final c in MeshClass.values) c: <_Queued>[]};
  late _Bucket _air;
  late Map<MeshClass, _Bucket> _classBuckets;

  void setLinkBytesPerSec(int bps) {
    if (bps == _cfg.linkBytesPerSec) return;
    _cfg = _cfg.copyWith(linkBytesPerSec: bps);
    _initBuckets(clockMs());
  }

  void _initBuckets(int t) {
    final c = _cfg;
    final cap = c.linkBytesPerSec.toDouble();
    _air = _Bucket(cap, cap * 0.5, t);
    _classBuckets = {
      MeshClass.alert: _Bucket(cap * c.alertShare, math.max(600, cap * c.alertShare), t),
      MeshClass.position: _Bucket(cap * c.positionShare, math.max(600, cap * c.positionShare), t),
      MeshClass.voice: _Bucket(cap * c.voiceShare, math.max(600, cap * c.voiceShare * 0.5), t),
      MeshClass.chat: _Bucket(cap * c.chatShare, math.max(600, cap * c.chatShare), t),
      MeshClass.control: _Bucket(math.max(200, cap * 0.05), 600, t),
    };
  }

  int queued(MeshClass c) => _queues[c]!.length;
  int get pendingRelays => _pending.values.where((p) => !p.cancelled).length;

  int _nextSeq() => _seq = (_seq + 1) & 0xffffffff;

  /// Seals and queues a new message from this phone. [proxyOrigin]: a bridge phone injecting a message on behalf of a
  /// rider it heard from the server (marked proxied). Returns the message id.
  String originate(Uint8List payload, MeshClass cls, {int? ttl, bool ackWanted = false, int? proxyOrigin, int? originTimeSec, bool live = false}) {
    final now = clockMs();
    final origin = proxyOrigin ?? myId;
    final seq = proxyOrigin == null ? _nextSeq() : (_proxySeq[proxyOrigin] = ((_proxySeq[proxyOrigin] ?? 0) + 1) & 0xffffffff);
    final t = (ttl ?? meshDefaultTtl(cls)).clamp(1, MeshFrame.maxTtl);
    final f = MeshFrame(
      cls: cls,
      origin: origin,
      boot: boot,
      seq: seq,
      originTimeSec: originTimeSec ?? now ~/ 1000,
      initialTtl: t,
      ttl: t,
      payload: payload,
      proxied: proxyOrigin != null,
      ackWanted: ackWanted,
      relay: myId,
      relayLat: myPosition?.call()?.lat,
      relayLng: myPosition?.call()?.lng,
    );
    final sealed = codec.seal(f);
    lastSealed = sealed;
    replay.check(f, now ~/ 1000); // never deliver our own frame back to ourselves
    stats.originated++;
    _enqueue(_Queued(sealed, cls, now, originKey: cls == MeshClass.position ? origin : null, live: live));
    return f.id;
  }

  /// Puts an already sealed frame (from the store-and-forward buffer) on the air again, with this rider as relay.
  void retransmit(Uint8List sealed, MeshClass cls, {int minTtl = 2}) {
    if (sealed.length < MeshFrame.headerLength) return;
    final ttl = math.max<int>(sealed[22], minTtl).clamp(1, math.max<int>(1, sealed[21]));
    final me = myPosition?.call();
    _enqueue(_Queued(MeshFrameCodec.rewriteRelay(sealed, ttl: ttl, relay: myId, relayLat: me?.lat, relayLng: me?.lng), cls, clockMs()));
  }

  void _enqueue(_Queued q) {
    final list = _queues[q.cls]!;
    if (q.originKey != null) list.removeWhere((e) => e.originKey == q.originKey); // positions: latest only
    if (list.length >= _cfg.maxQueuePerClass) {
      if (q.cls == MeshClass.sos) {
        list.removeAt(0);
      } else {
        stats.droppedFull++;
        return;
      }
    }
    list.add(q);
  }

  /// A frame from a radio. Returns the opened frame when it was fresh (also handed to [onDeliver]), else null.
  MeshFrame? receive(Uint8List bytes, {int rssi = -70, String link = ''}) {
    final now = clockMs();
    stats.received++;
    final f = codec.open(bytes);
    if (f == null) {
      stats.rejected++;
      return null;
    }
    if (f.origin == myId && !f.proxied) {
      _notePendingDuplicate(f);
      return null; // our own frame echoed back by a relay
    }
    final why = replay.check(f, now ~/ 1000);
    if (why == 'duplicate') {
      stats.duplicates++;
      _notePendingDuplicate(f);
      return null;
    }
    if (why.isNotEmpty) {
      stats.rejected++;
      return null;
    }
    stats.delivered++;
    final meta = MeshRxMeta(rssi: rssi, atMs: now, link: link);
    lastReceived = bytes;
    onDeliver?.call(f, meta);
    lastReceived = null;
    _scheduleRelay(f, bytes, rssi, now);
    return f;
  }

  void _notePendingDuplicate(MeshFrame f) {
    final p = _pending[f.id];
    if (p == null || p.cancelled) return;
    p.heard++;
    if (f.cls == MeshClass.sos) return;
    final limit = _cfg.suppressAfter[f.cls] ?? 2;
    if (p.heard >= limit || _passed(f)) {
      p.cancelled = true;
      stats.suppressed++;
    }
  }

  /// Progress suppression: the transmitter is already farther from the origin than this rider.
  bool _passed(MeshFrame f) {
    final me = myPosition?.call();
    final rLat = f.relayLat, rLng = f.relayLng;
    if (me == null || rLat == null || rLng == null || f.relay == f.origin) return false;
    final o = positionOf?.call(f.origin);
    if (o == null) return false;
    final dMe = meshDistanceM(me.lat, me.lng, o.lat, o.lng);
    final dRelay = meshDistanceM(rLat, rLng, o.lat, o.lng);
    return dRelay >= dMe + _cfg.progressMarginM;
  }

  void _scheduleRelay(MeshFrame f, Uint8List sealed, int rssi, int now) {
    if (f.ttl <= 1 || f.cls == MeshClass.control) {
      if (f.cls != MeshClass.control) stats.ttlExpired++;
      return;
    }
    // Back-off: weak reception (edge of range) -> relay soon; strong -> wait and probably stand down.
    final strength = ((rssi + 100) / 50).clamp(0.0, 1.0); // -100 dBm -> 0, -50 dBm -> 1
    final base = switch (f.cls) {
      MeshClass.sos => 5,
      MeshClass.alert => 15,
      MeshClass.voice => 10,
      _ => 20,
    };
    final span = f.cls == MeshClass.sos ? 20 : 120;
    final delay = base + (strength * span).round() + _random.nextInt(f.cls == MeshClass.sos ? 10 : 25);
    final p = _Pending(f, sealed, now + delay);
    if (f.cls != MeshClass.sos && _passed(f)) {
      p.cancelled = true;
      stats.suppressed++;
    }
    _pending[f.id] = p;
  }

  /// Fires due relays and sends what the budgets allow. Call every 10-20 ms while the link is active.
  void tick() {
    final now = clockMs();
    if (_pending.isNotEmpty) {
      final due = _pending.entries.where((e) => e.value.fireAt <= now).toList();
      for (final e in due) {
        _pending.remove(e.key);
        final p = e.value;
        if (p.cancelled) continue;
        stats.relayed++;
        final me = myPosition?.call();
        final relayed = MeshFrameCodec.rewriteRelay(p.sealed, ttl: p.frame.ttl - 1, relay: myId, relayLat: me?.lat, relayLng: me?.lng);
        _enqueue(_Queued(relayed, p.frame.cls, now,
            originKey: p.frame.cls == MeshClass.position ? p.frame.origin : null, live: p.frame.cls == MeshClass.voice && !_isClip(p.frame)));
      }
    }
    _drain(now);
  }

  static bool _isClip(MeshFrame f) => f.payload.length > 1 && (f.payload[1] & 0x04) != 0;

  void _drain(int now) {
    _air.refill(now);
    for (final b in _classBuckets.values) {
      b.refill(now);
    }
    var guard = 0;
    while (guard++ < 256) {
      _Queued? pick;
      for (final c in MeshClass.values) {
        final list = _queues[c]!;
        if (c == MeshClass.voice) {
          final before = list.length;
          list.removeWhere((q) => q.live && now - q.at > _cfg.liveVoiceMaxQueueMs);
          stats.droppedLate += before - list.length;
        }
        if (list.isEmpty) continue;
        // Live voice goes before stored clip chunks (a clip waits a moment; live audio cannot).
        final liveAt = c == MeshClass.voice ? list.indexWhere((q) => q.live) : -1;
        final head = liveAt > 0 ? list[liveAt] : list.first;
        if (c == MeshClass.sos) {
          pick = head; // never budget-limited
          break;
        }
        final cb = _classBuckets[c]!;
        if (cb.tokens >= head.bytes.length && _air.tokens >= head.bytes.length) {
          pick = head;
          break;
        }
        // A blocked higher class does not block a lower one that fits its own budget (budgets are per class).
      }
      if (pick == null) return;
      _queues[pick.cls]!.remove(pick);
      _air.tokens -= pick.bytes.length;
      if (pick.cls != MeshClass.sos) _classBuckets[pick.cls]!.tokens -= pick.bytes.length;
      stats.txByClass[pick.cls] = stats.txByClass[pick.cls]! + 1;
      stats.txBytesByClass[pick.cls] = stats.txBytesByClass[pick.cls]! + pick.bytes.length;
      transmit(pick.bytes, pick.cls);
    }
  }

  void reset() {
    _pending.clear();
    for (final q in _queues.values) {
      q.clear();
    }
    replay.clear();
  }
}

/// Great-circle distance in metres (haversine; plenty for the 0-2 km the mesh cares about).
double meshDistanceM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dp = p2 - p1, dl = (lng2 - lng1) * math.pi / 180;
  final a = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
}
