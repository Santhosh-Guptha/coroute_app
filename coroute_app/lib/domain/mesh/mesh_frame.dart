// Round 10 offline link: the secure mesh frame (v2). Pure Dart; tested in test/mesh_frame_test.dart. The gateway reads
// the same layout for bridged frames (gateway/src/mesh_bridge.js) - keep both in step.
//
//   offset size  field                          authenticated (AAD)
//   0      1     magic 0xC5                     yes
//   1      1     version 0x21 (v2, data)        yes
//   2      2     group tag (from the ride key)  yes   outsiders cannot even tell which ride a frame belongs to
//   4      1     class + flags                  yes   bits 0-2 class, bit 3 proxied (server via bridge), bit 4 ack wanted
//   5      4     origin short id                yes   } nonce = origin | boot | seq (unique per key:
//   9      4     boot (random per app start)    yes   }  boot is random, seq counts up)
//   13     4     seq                            yes   }
//   17     4     origin time (unix seconds)     yes   freshness / replay window
//   21     1     initial TTL                    yes   hops taken = initial TTL - TTL
//   22     1     TTL (hops left)                no    changed by every relay
//   23     4     relay short id                 no    last transmitter
//   27     3     relay latitude                 no    signed 1e-4 degrees (11 m); 0x800000 unknown
//   30     3     relay longitude                no    signed 1e-4 degrees
//   33     n+16  AES-256-GCM(payload) || tag
//
// The relay header is not authenticated on purpose (each hop rewrites it). A forged relay header can only change who
// relays next or shorten the flood; the initial TTL is authenticated and caps the hop count (receivers also cap it).
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'crypto/aes_gcm.dart';

/// Priority classes, most urgent first (the scheduler serves a lower index first).
enum MeshClass {
  sos, // 0: SOS raise / update / resolve / acknowledgement
  alert, // 1: group alerts (chain stretch, status, SOS response)
  position, // 2: positions (latest only)
  voice, // 3: live push-to-talk frames and walkie-talkie clips
  chat, // 4: text
  control; // 5: hello / capabilities

  static MeshClass of(int v) => (v >= 0 && v < values.length) ? values[v] : MeshClass.control;
}

/// Stable 32-bit short id of a rider (FNV-1a over the UTF-8 user id; 0 is never used). Same function in the gateway.
int meshShortId(String userId) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(userId)) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h == 0 ? 1 : h;
}

/// The ride's group key (32 bytes from the gateway's MESH_KEY at ride start) and what is derived from it.
class MeshKeyring {
  MeshKeyring(Uint8List key, {this.epoch = 0})
      : key = Uint8List.fromList(key),
        gcm = AesGcm(key) {
    if (key.length != 32) throw ArgumentError('mesh key must be 32 bytes');
    final t = gcm.blockCipher.encrypt16(Uint8List.fromList(utf8.encode('CoRouteMeshTag01')));
    groupTag = (t[0] << 8) | t[1];
    final b = gcm.blockCipher.encrypt16(Uint8List.fromList(utf8.encode('CoRouteBeaconK01')));
    beaconKey = AesBlockCipher(Uint8List.fromList([...b, ...t]));
  }

  final Uint8List key;
  final int epoch;
  final AesGcm gcm;
  late final int groupTag;

  /// Key for the 4-byte beacon MAC (advertising has no room for a full GCM tag).
  late final AesBlockCipher beaconKey;
}

class MeshFrame {
  MeshFrame({
    required this.cls,
    required this.origin,
    required this.boot,
    required this.seq,
    required this.originTimeSec,
    required this.initialTtl,
    required this.ttl,
    required this.payload,
    this.proxied = false,
    this.ackWanted = false,
    this.relay = 0,
    this.relayLat,
    this.relayLng,
  });

  static const int magic = 0xC5;
  static const int version = 0x21;
  static const int aadLength = 22;
  static const int headerLength = 33;
  static const int overhead = headerLength + AesGcm.tagLength;

  /// Hard cap on hops whatever a frame claims.
  static const int maxTtl = 8;

  final MeshClass cls;
  final int origin;
  final int boot;
  final int seq;
  final int originTimeSec;
  final int initialTtl;
  final int ttl;
  final bool proxied;
  final bool ackWanted;
  final int relay;

  /// Last transmitter's position (11 m resolution; null = unknown): progress suppression compares it with the origin.
  final double? relayLat;
  final double? relayLng;

  /// Decrypted payload (first byte = message kind, see mesh_messages.dart).
  final Uint8List payload;

  int get hops => (initialTtl - ttl).clamp(0, maxTtl);

  /// Unique message id within the ride (dedup key).
  String get id => '${origin.toRadixString(16)}.${boot.toRadixString(16)}.$seq';

  MeshFrame forRelay({required int relayId, double? relayLat, double? relayLng}) => MeshFrame(
        cls: cls,
        origin: origin,
        boot: boot,
        seq: seq,
        originTimeSec: originTimeSec,
        initialTtl: initialTtl,
        ttl: ttl - 1,
        payload: payload,
        proxied: proxied,
        ackWanted: ackWanted,
        relay: relayId,
        relayLat: relayLat,
        relayLng: relayLng,
      );
}

/// Seals / opens frames with the ride key.
class MeshFrameCodec {
  MeshFrameCodec(this.keyring);
  final MeshKeyring keyring;

  static Uint8List nonceOf(int origin, int boot, int seq) {
    final n = Uint8List(12);
    final bd = ByteData.sublistView(n);
    bd.setUint32(0, origin & 0xffffffff);
    bd.setUint32(4, boot & 0xffffffff);
    bd.setUint32(8, seq & 0xffffffff);
    return n;
  }

  Uint8List seal(MeshFrame f) {
    final head = Uint8List(MeshFrame.headerLength);
    final bd = ByteData.sublistView(head);
    head[0] = MeshFrame.magic;
    head[1] = MeshFrame.version;
    bd.setUint16(2, keyring.groupTag);
    head[4] = (f.cls.index & 0x07) | (f.proxied ? 0x08 : 0) | (f.ackWanted ? 0x10 : 0);
    bd.setUint32(5, f.origin & 0xffffffff);
    bd.setUint32(9, f.boot & 0xffffffff);
    bd.setUint32(13, f.seq & 0xffffffff);
    bd.setUint32(17, f.originTimeSec & 0xffffffff);
    head[21] = f.initialTtl.clamp(0, MeshFrame.maxTtl);
    _writeRelay(head, f.ttl, f.relay, f.relayLat, f.relayLng);
    final sealed = keyring.gcm.encrypt(nonceOf(f.origin, f.boot, f.seq), f.payload, aad: Uint8List.sublistView(head, 0, MeshFrame.aadLength));
    return Uint8List(head.length + sealed.length)
      ..setRange(0, head.length, head)
      ..setRange(head.length, head.length + sealed.length, sealed);
  }

  static const int _unknown24 = 0x800000;

  static void _put24(Uint8List b, int o, double? deg) {
    final v = deg == null || !deg.isFinite ? _unknown24 : ((deg * 1e4).round().clamp(-0x7fffff, 0x7fffff) & 0xffffff);
    b[o] = (v >> 16) & 0xff;
    b[o + 1] = (v >> 8) & 0xff;
    b[o + 2] = v & 0xff;
  }

  static double? _get24(Uint8List b, int o) {
    final v = (b[o] << 16) | (b[o + 1] << 8) | b[o + 2];
    if (v == _unknown24) return null;
    return (v >= 0x800000 ? v - 0x1000000 : v) / 1e4;
  }

  static void _writeRelay(Uint8List head, int ttl, int relay, double? lat, double? lng) {
    final bd = ByteData.sublistView(head);
    head[22] = ttl.clamp(0, MeshFrame.maxTtl);
    bd.setUint32(23, relay & 0xffffffff);
    _put24(head, 27, lat == null || lng == null ? null : lat);
    _put24(head, 30, lat == null || lng == null ? null : lng);
  }

  /// Re-relays an already sealed frame without decrypting again: only the relay header changes.
  static Uint8List rewriteRelay(Uint8List sealed, {required int ttl, required int relay, double? relayLat, double? relayLng}) {
    final out = Uint8List.fromList(sealed);
    _writeRelay(out, ttl, relay, relayLat, relayLng);
    return out;
  }

  /// Cheap pre-check before any crypto: right magic, version and ride.
  bool looksLikeOurs(Uint8List b) =>
      b.length >= MeshFrame.overhead + 1 && b[0] == MeshFrame.magic && b[1] == MeshFrame.version && ((b[2] << 8) | b[3]) == keyring.groupTag;

  /// The frame, or null: not ours, malformed, or failed authentication (outsider, tampered, wrong ride key).
  MeshFrame? open(Uint8List b) {
    if (!looksLikeOurs(b)) return null;
    final bd = ByteData.sublistView(b);
    final origin = bd.getUint32(5), boot = bd.getUint32(9), seq = bd.getUint32(13);
    final plain = keyring.gcm.decrypt(nonceOf(origin, boot, seq), Uint8List.sublistView(b, MeshFrame.headerLength),
        aad: Uint8List.sublistView(b, 0, MeshFrame.aadLength));
    if (plain == null || plain.isEmpty) return null;
    final initial = math.min(b[21], MeshFrame.maxTtl);
    final rLat = _get24(b, 27), rLng = _get24(b, 30);
    return MeshFrame(
      cls: MeshClass.of(b[4] & 0x07),
      proxied: (b[4] & 0x08) != 0,
      ackWanted: (b[4] & 0x10) != 0,
      origin: origin,
      boot: boot,
      seq: seq,
      originTimeSec: bd.getUint32(17),
      initialTtl: initial,
      ttl: math.min(b[22], initial),
      relay: bd.getUint32(23),
      relayLat: rLat == null || rLng == null ? null : rLat,
      relayLng: rLat == null || rLng == null ? null : rLng,
      payload: plain,
    );
  }
}

/// Replay protection: a frame is accepted once, and only while it is fresh for its class. The id cache keeps every id
/// for as long as its class may still be accepted (bounded; an evicted entry raises that origin's low-water mark, so
/// an evicted id can never be replayed either).
class ReplayGuard {
  ReplayGuard({this.maxEntries = 8192, this.futureSkewSec = 300});

  final int maxEntries;
  final int futureSkewSec;

  /// How old (seconds) a frame of each class may be when it arrives. SOS lives long: store-and-forward may carry it
  /// for hours across a dead zone.
  static int maxAgeSec(MeshClass c) => switch (c) {
        MeshClass.sos => 6 * 3600,
        MeshClass.alert => 15 * 60,
        MeshClass.position => 5 * 60,
        MeshClass.voice => 15 * 60,
        MeshClass.chat => 30 * 60,
        MeshClass.control => 60,
      };

  final Map<String, (int, int)> _seen = <String, (int, int)>{}; // id -> (origin time, class), insertion ordered
  final Map<int, int> _lowWater = <int, int>{}; // origin * 8 + class -> oldest origin time still acceptable

  int get size => _seen.length;

  /// Why a frame is refused ('' = accept and remember it).
  String check(MeshFrame f, int nowSec) {
    if (f.originTimeSec > nowSec + futureSkewSec) return 'future';
    if (nowSec - f.originTimeSec > maxAgeSec(f.cls)) return 'stale';
    final lw = _lowWater[f.origin * 8 + f.cls.index];
    if (lw != null && f.originTimeSec < lw) return 'evicted';
    final id = f.id;
    if (_seen.containsKey(id)) return 'duplicate';
    _seen[id] = (f.originTimeSec, f.cls.index);
    if (_seen.length > maxEntries) _evict(nowSec);
    return '';
  }

  bool seen(String id) => _seen.containsKey(id);

  void _evict(int nowSec) {
    // First everything that can no longer be accepted anyway, then the oldest of the bulk classes (positions, voice),
    // and an SOS id only when nothing else is left.
    _seen.removeWhere((_, v) => nowSec - v.$1 > maxAgeSec(MeshClass.of(v.$2)));
    // Oldest origin time first (not insertion order: a late store-and-forward frame must not push the mark past
    // fresher ids), a tenth of the cache at a time so this runs rarely.
    for (final keepSos in [true, false]) {
      if (_seen.length <= maxEntries) return;
      final cands = _seen.entries.where((e) => !keepSos || e.value.$2 != MeshClass.sos.index).toList()
        ..sort((x, y) => x.value.$1.compareTo(y.value.$1));
      final need = math.min(cands.length, _seen.length - maxEntries + maxEntries ~/ 10);
      for (final e in cands.take(need)) {
        _seen.remove(e.key);
        final origin = int.parse(e.key.substring(0, e.key.indexOf('.')), radix: 16);
        final lk = origin * 8 + e.value.$2;
        final cur = _lowWater[lk];
        if (cur == null || e.value.$1 + 1 > cur) _lowWater[lk] = e.value.$1 + 1;
      }
    }
  }

  void clear() {
    _seen.clear();
    _lowWater.clear();
  }
}
