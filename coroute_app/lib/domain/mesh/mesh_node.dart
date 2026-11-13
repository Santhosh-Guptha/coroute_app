// Round 10 offline link: one rider's mesh node - router + store-and-forward + neighbour table + clip assembly + SOS
// acknowledgements, behind one small API. Pure Dart and radio-agnostic: the app's OfflineLinkService drives one of these
// with the real radios (lib/data/services/offline_link/), and test/mesh_simulation_test.dart drives ten of them over a
// simulated radio (lib/domain/mesh/mesh_sim.dart). Same code in both, so the simulated numbers are this code's numbers.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'mesh_frame.dart';
import 'mesh_messages.dart';
import 'mesh_neighbors.dart';
import 'mesh_router.dart';
import 'mesh_store_forward.dart';
import 'mesh_voice.dart';

class MeshNodeStats {
  int sosReceived = 0;
  int acksSent = 0;
  int acksSuppressed = 0;
  int storeOffers = 0;
}

class MeshNodeEngine {
  MeshNodeEngine({
    required MeshKeyring keyring,
    required this.myId,
    required int boot,
    required void Function(Uint8List bytes, MeshClass cls) transmit,
    required this.clockMs,
    math.Random? random,
    this.myName = '',
    MeshRouterConfig config = const MeshRouterConfig(),
    StoreForwardConfig storeConfig = const StoreForwardConfig(),
  })  : codec = MeshFrameCodec(keyring),
        _random = random ?? math.Random(),
        store = StoreForward(config: storeConfig) {
    router = MeshRouter(
      codec: codec,
      myId: myId,
      boot: boot,
      transmit: (b, c) {
        _transmit(b, c);
      },
      clockMs: clockMs,
      config: config,
      random: _random,
    );
    _transmit = transmit;
    router.onDeliver = _onDeliver;
    router.myPosition = () => myPosition;
    router.positionOf = (id) {
      final f = table.fixes[id];
      return f == null ? null : (lat: f.lat, lng: f.lng);
    };
  }

  final int myId;
  final int Function() clockMs;
  final math.Random _random;
  final MeshFrameCodec codec;
  late final MeshRouter router;
  final StoreForward store;
  final MeshNeighborTable table = MeshNeighborTable();
  final ClipAssembler clips = ClipAssembler();
  final MeshNodeStats stats = MeshNodeStats();
  late void Function(Uint8List bytes, MeshClass cls) _transmit;

  String myName;
  ({double lat, double lng})? myPosition;
  int caps = 0;

  /// Any rider that hears an SOS acknowledges it (a short SOS-class frame back to the origin). The origin stops
  /// resending once ANY acknowledgement arrives. Off only in tests.
  bool autoAckSos = true;

  void Function(int origin, MeshPos pos, MeshFrame f)? onPosition;
  void Function(int origin, MeshSos sos, MeshFrame f)? onSos;
  void Function(MeshSosAck ack, MeshFrame f)? onSosAck;
  void Function(int origin, MeshAlert alert, MeshFrame f)? onAlert;
  void Function(int origin, MeshVoice voice, MeshFrame f)? onLiveVoice;
  void Function(MeshClip clip)? onClip;
  void Function(int origin, MeshChat chat, MeshFrame f)? onChat;
  void Function(int origin, MeshHello hello)? onHello;

  /// A new direct link (first time or back after a gap).
  void Function(int id)? onNewNeighbour;

  /// Every fresh frame (the bridge forwards these to the gateway).
  void Function(MeshFrame f, Uint8List sealed)? onFreshFrame;

  final Map<String, ({int target, int fireAt, String clientId, bool byServer, String alertId})> _pendingAcks = {};
  final Set<String> _ackedSeen = <String>{};
  int _streamSeq = 0;
  int _lastPrune = 0;
  int _lastOffer = 0;
  int _lastNack = 0;

  Set<int> activeNeighbourIds() => {for (final n in table.active(clockMs())) n.id};

  // ------------------------------------------------------------------------------------------------- originate
  String _originate(Uint8List payload, MeshClass cls, {int? ttl, bool ackWanted = false, int? proxyOrigin, int? originTimeSec, bool live = false, String? storeKey, String? sosClientId}) {
    final id = router.originate(payload, cls, ttl: ttl, ackWanted: ackWanted, proxyOrigin: proxyOrigin, originTimeSec: originTimeSec, live: live);
    if (!live && cls != MeshClass.control) {
      final sealed = _lastSealed;
      if (sealed != null) {
        final now = clockMs();
        store.put(
            StoredFrame(
              id: id,
              cls: cls,
              sealed: sealed,
              storedAtMs: now,
              expiresAtMs: now + storeLifetimeMs(cls),
              origin: proxyOrigin ?? myId,
              key: storeKey,
              own: proxyOrigin == null,
              sosClientId: sosClientId,
            ),
            now);
        store.markSent(id, activeNeighbourIds(), now);
      }
    }
    return id;
  }

  Uint8List? get _lastSealed => router.lastSealed;

  String sendPosition(MeshPos p, {int? proxyOrigin, int? originTimeSec}) =>
      _originate(p.encode(), MeshClass.position, proxyOrigin: proxyOrigin, originTimeSec: originTimeSec, storeKey: 'pos:${proxyOrigin ?? myId}');

  String sendSos(MeshSos s, {int? proxyOrigin}) => _originate(s.encode(), MeshClass.sos, ackWanted: true, proxyOrigin: proxyOrigin, sosClientId: s.clientId, storeKey: 'sos:${proxyOrigin ?? myId}:${s.clientId}:${s.resolved ? 'r' : 'o'}');

  /// Acknowledges an SOS (this rider heard it, or the server confirmed it through this bridge phone).
  void sendSosAck(int target, String clientId, {bool byServer = false, String alertId = ''}) {
    final key = 'ack:$target:$clientId:${byServer ? 's' : 'r'}';
    if (_ackedSeen.contains(key)) return;
    _ackedSeen.add(key);
    stats.acksSent++;
    _originate(MeshSosAck(target: target, clientId: clientId, acker: myId, byServer: byServer, alertId: alertId).encode(), MeshClass.sos, storeKey: key);
  }

  String sendAlert(MeshAlert a) => _originate(a.encode(), MeshClass.alert);
  String sendChat(MeshChat c) => _originate(c.encode(), MeshClass.chat);

  void sendHello() => router.originate(MeshHello(caps: caps, name: myName).encode(), MeshClass.control, ttl: 1);

  int newStreamId() => _streamSeq = (_streamSeq + 1) & 0xffff;

  /// One live voice frame (never stored: late audio is useless).
  void sendLiveVoice(MeshVoice v) => _originate(v.encode(), MeshClass.voice, live: true);

  /// A finished walkie-talkie clip: every chunk is sealed, stored and offered to every new link until it expires.
  int sendClip(ClipRecorder rec, {required int streamId, bool lead = false}) {
    final chunks = rec.chunks();
    for (var i = 0; i < chunks.length; i++) {
      final v = MeshVoice(
        streamId: streamId,
        frameSeq: i,
        codec: rec.codec,
        sampleRate: rec.sampleRate,
        payload: chunks[i],
        start: i == 0,
        end: i == chunks.length - 1,
        clip: true,
        lead: lead,
        clipChunks: chunks.length,
        clipDurationMs: rec.durationMs,
        name: myName,
      );
      _originate(v.encode(), MeshClass.voice, storeKey: 'clip:$myId:$streamId:$i');
    }
    return chunks.length;
  }

  // --------------------------------------------------------------------------------------------------- receive
  void onRadioFrame(Uint8List bytes, {int rssi = -70, String link = ''}) {
    if (bytes.length >= MeshFrame.headerLength && codec.looksLikeOurs(bytes)) {
      final relay = ByteData.sublistView(bytes).getUint32(23);
      if (relay != 0 && relay != myId) {
        if (table.noteHeard(relay, rssi, clockMs())) _newLink(relay);
      }
    }
    router.receive(bytes, rssi: rssi, link: link);
  }

  void onBeacon(MeshBeacon b, int rssi) {
    if (b.rider == myId) return;
    if (table.noteHeard(b.rider, rssi, clockMs(), caps: b.caps, beaconSeq: b.seq, psm: b.psm)) _newLink(b.rider);
  }

  /// A link that was gone this long gets everything offered again (shorter flaps at the edge of range do not:
  /// re-sending the whole buffer on every flap would eat the airtime).
  static const int rejoinAfterMs = 30000;

  void _newLink(int id) {
    final away = table.lastAbsenceMs;
    if (away < 0 || away >= rejoinAfterMs) store.forgetOffers(id);
    onNewNeighbour?.call(id);
    _offerStored();
  }

  void _onDeliver(MeshFrame f, MeshRxMeta meta) {
    final now = clockMs();
    final kind = f.payload.isEmpty ? -1 : f.payload[0];
    final storable = f.cls != MeshClass.control && !(kind == MeshKind.voice && (f.payload.length < 2 || f.payload[1] & 0x04 == 0));
    String? storeKey;
    String? sosCid;
    switch (kind) {
      case MeshKind.pos:
        final p = MeshPos.decode(f.payload);
        if (p == null) return;
        storeKey = 'pos:${f.origin}';
        table.noteFix(
            f.origin,
            MeshRiderFix(
                lat: p.lat, lng: p.lng, speedKmh: p.speedKmh, heading: p.heading, atMs: f.originTimeSec * 1000 - p.fixAgeSec * 1000, hops: f.hops, role: p.role, hasInternet: p.hasInternet));
        onPosition?.call(f.origin, p, f);
      case MeshKind.sos:
        final s = MeshSos.decode(f.payload);
        if (s == null) return;
        sosCid = s.clientId;
        storeKey = 'sos:${f.origin}:${s.clientId}:${s.resolved ? 'r' : 'o'}';
        stats.sosReceived++;
        onSos?.call(f.origin, s, f);
        if (autoAckSos && !s.resolved && !f.proxied) _scheduleAck(f.origin, s.clientId, f.hops);
      case MeshKind.sosAck:
        final a = MeshSosAck.decode(f.payload);
        if (a == null) return;
        storeKey = 'ack:${a.target}:${a.clientId}:${a.byServer ? 's' : 'r'}';
        if (a.target == myId) store.ackSos(a.clientId);
        // Someone else already acknowledged: our own pending acknowledgement is not needed.
        if (_pendingAcks.remove('${a.target}:${a.clientId}') != null) stats.acksSuppressed++;
        onSosAck?.call(a, f);
      case MeshKind.alert:
        final a = MeshAlert.decode(f.payload);
        if (a == null) return;
        onAlert?.call(f.origin, a, f);
      case MeshKind.voice:
        final v = MeshVoice.decode(f.payload);
        if (v == null) return;
        if (v.clip) {
          storeKey = 'clip:${f.origin}:${v.streamId}:${v.frameSeq}';
          final clip = clips.add(f.origin, v, now);
          if (clip != null) onClip?.call(clip);
        } else {
          onLiveVoice?.call(f.origin, v, f);
        }
      case MeshKind.clipNack:
        final n = MeshClipNack.decode(f.payload);
        if (n == null) return;
        _repairClip(n);
        return;
      case MeshKind.chat:
        final c = MeshChat.decode(f.payload);
        if (c == null) return;
        onChat?.call(f.origin, c, f);
      case MeshKind.hello:
        final h = MeshHello.decode(f.payload);
        if (h == null) return;
        if (table.noteHeard(f.origin, meta.rssi, now, caps: h.caps, name: h.name)) _newLink(f.origin);
        onHello?.call(f.origin, h);
        return;
      default:
        return;
    }
    final sealed = router.lastReceived;
    if (sealed != null) {
      onFreshFrame?.call(f, sealed);
      if (storable) {
        store.put(
            StoredFrame(
              id: f.id,
              cls: f.cls,
              sealed: sealed,
              storedAtMs: f.originTimeSec * 1000,
              expiresAtMs: f.originTimeSec * 1000 + storeLifetimeMs(f.cls),
              origin: f.origin,
              key: storeKey,
              sosClientId: sosCid,
            ),
            now);
        // The router relays it now; the neighbours in range have it (they heard the same transmission or will hear
        // our relay), so it is only offered to links that appear later.
        store.markSent(f.id, activeNeighbourIds(), now);
      }
    }
  }

  void _scheduleAck(int target, String clientId, int hops) {
    final k = '$target:$clientId';
    if (_pendingAcks.containsKey(k) || _ackedSeen.contains('ack:$target:$clientId:r')) return;
    // Riders closest to the origin answer first; the others hear that answer and stay quiet.
    final delay = 40 + hops * 60 + _random.nextInt(120);
    _pendingAcks[k] = (target: target, fireAt: clockMs() + delay, clientId: clientId, byServer: false, alertId: '');
  }

  void _repairClip(MeshClipNack n) {
    final now = clockMs();
    for (final i in n.missing) {
      final f = store.items.where((e) => e.key == 'clip:${n.origin}:${n.streamId}:$i').firstOrNull;
      if (f == null || now - f.lastTxAtMs < 2000) continue;
      f.lastTxAtMs = now;
      stats.storeOffers++;
      router.retransmit(f.sealed, f.cls);
    }
  }

  void _askForMissingChunks() {
    for (final m in clips.missing(clockMs())) {
      _originate(MeshClipNack(origin: m.origin, streamId: m.streamId, total: m.total, missing: m.missing).encode(), MeshClass.voice, ttl: 3, live: true);
    }
  }

  void _offerStored() {
    final now = clockMs();
    _lastOffer = now;
    final due = store.due(now, activeNeighbourIds());
    for (final f in due) {
      stats.storeOffers++;
      router.retransmit(f.sealed, f.cls);
    }
  }

  /// Call every 10-20 ms while the link is active.
  void tick() {
    final now = clockMs();
    if (_pendingAcks.isNotEmpty) {
      for (final e in _pendingAcks.entries.where((e) => e.value.fireAt <= now).toList()) {
        _pendingAcks.remove(e.key);
        sendSosAck(e.value.target, e.value.clientId);
      }
    }
    if (now - _lastOffer >= 250) _offerStored();
    router.tick();
    if (now - _lastNack >= 1000) {
      _lastNack = now;
      _askForMissingChunks();
    }
    if (now - _lastPrune > 5000) {
      _lastPrune = now;
      table.prune(now);
      for (final c in clips.sweep(now)) {
        onClip?.call(c);
      }
    }
  }

  void reset() {
    router.reset();
    store.clear();
    table.clear();
    _pendingAcks.clear();
    _ackedSeen.clear();
  }
}
