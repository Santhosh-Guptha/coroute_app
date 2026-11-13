// Round 10 offline link: voice over the mesh. Pure Dart (tested in test/mesh_voice_test.dart):
//  * [MeshVoicePolicy] decides per talk: LIVE push-to-talk (Opus 8-12 kbit/s; IMA ADPCM 32 kbit/s only to a strong
//    near neighbour on a fast PHY) or a WALKIE-TALKIE CLIP (recorded, max 15 s, carried by store-and-forward, played on
//    arrival with a "Voice message from Ravi" chip) when there is no live path or the path is too slow / lossy;
//  * [MeshFloor] keeps one live speaker at a time with the existing rules (Lead / sweeper first, 20 s fair share,
//    a stale floor frees itself) - a press while the floor is busy records a clip instead, so nothing is lost;
//  * [ClipRecorder] / [ClipAssembler] cut a clip into chunks that fit a frame and put it back together.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'mesh_messages.dart';

enum MeshTalkMode { live, clip }

class MeshTalkPlan {
  const MeshTalkPlan({required this.mode, required this.codec, required this.sampleRate, required this.bitrate, required this.reason});
  final MeshTalkMode mode;
  final int codec;
  final int sampleRate;

  /// Opus target bitrate (bit/s); for ADPCM the fixed 32 kbit/s.
  final int bitrate;
  final String reason;

  @override
  String toString() => 'MeshTalkPlan($mode, codec $codec, $sampleRate Hz, $bitrate bit/s: $reason)';
}

class MeshVoicePolicy {
  /// Mouth-to-ear budget for live talk; beyond it a clip is clearer than broken live audio.
  static const int liveMaxLatencyMs = 450;
  static const double liveMaxLoss = 0.2;
  static const int clipMaxMs = 15000;

  /// Live voice packs 80 ms (two intercom frames) per mesh frame: the 54 bytes of frame + voice header per frame cost
  /// less airtime than at 40 ms.
  static const int liveFrameMs = 80;
  static const int frameOverheadBytes = 54;

  /// Airtime one live talk needs at [bitrate] (payload + per-frame overhead), bytes per second.
  static double airBytesPerSec(int bitrate) => bitrate / 8 + frameOverheadBytes * (1000 / liveFrameMs);

  /// Per-hop latency (queueing + airtime + relay back-off) measured in the simulation: Coded PHY ~70 ms, 1M ~25 ms.
  static int perHopMs({required bool coded}) => coded ? 70 : 25;

  static MeshTalkPlan plan({
    required int neighbours,
    required int maxHops,
    required double loss,
    required int linkBytesPerSec,
    required bool coded,
    required bool opusEncoder,
    required bool strongNearLink,
    required bool floorFree,
    double voiceShare = 0.5,
  }) {
    final clipCodec = opusEncoder ? MeshVoiceCodec.opus : MeshVoiceCodec.adpcm;
    final clipRate = opusEncoder ? 16000 : 8000;
    final clipBitrate = opusEncoder ? 12000 : 32000;
    MeshTalkPlan clip(String why) => MeshTalkPlan(mode: MeshTalkMode.clip, codec: clipCodec, sampleRate: clipRate, bitrate: clipBitrate, reason: why);
    if (neighbours == 0) return clip('no live path');
    if (!floorFree) return clip('floor busy');
    final latency = 60 + 40 + math.max(1, maxHops) * perHopMs(coded: coded); // jitter buffer + framing + hops
    if (latency > liveMaxLatencyMs) return clip('path too slow ($latency ms)');
    if (loss > liveMaxLoss) return clip('path too lossy');
    final budget = linkBytesPerSec * voiceShare;
    if (opusEncoder) {
      final bitrate = budget >= airBytesPerSec(12000) * 1.2 ? 12000 : 8000;
      if (budget < airBytesPerSec(bitrate) * 1.2) return clip('link too slow for live voice');
      return MeshTalkPlan(mode: MeshTalkMode.live, codec: MeshVoiceCodec.opus, sampleRate: 16000, bitrate: bitrate, reason: 'opus live');
    }
    if (strongNearLink && maxHops <= 1 && budget >= airBytesPerSec(32000) * 1.2) {
      return const MeshTalkPlan(mode: MeshTalkMode.live, codec: MeshVoiceCodec.adpcm, sampleRate: 8000, bitrate: 32000, reason: 'adpcm live, near neighbour');
    }
    return clip('no Opus encoder and no strong near link');
  }
}

/// One live speaker at a time over the mesh (the server floor is not reachable offline). Same rules as the gateway:
/// a talk does not cut into another one; the Lead / sweeper may (priority); after [fairHoldMs] of one rider holding
/// the floor the next rider who presses takes it (fair share); a floor with no frame for [staleMs] is free; two talks
/// starting at the same moment: the priority one, then the earlier one, then the lower rider id keeps it.
class MeshFloor {
  MeshFloor({this.fairHoldMs = 20000, this.staleMs = 1500, this.collisionMs = 300});

  final int fairHoldMs;
  final int staleMs;
  final int collisionMs;

  int? _holder;
  bool _holderPriority = false;
  int _since = 0;
  int _lastFrame = 0;

  int? _localSince;
  bool _localPriority = false;
  int myId = 0;

  int? holderAt(int nowMs) => _holder != null && nowMs - _lastFrame <= staleMs ? _holder : null;
  bool get localTalking => _localSince != null;

  /// May this rider start a LIVE talk now?
  bool canTalk(int nowMs, {required bool priority}) {
    final h = holderAt(nowMs);
    if (h == null) return true;
    if (priority && !_holderPriority) return true;
    if (!_holderPriority && nowMs - _since >= fairHoldMs) return true;
    return false;
  }

  void localStart(int nowMs, {required bool priority}) {
    _localSince = nowMs;
    _localPriority = priority;
  }

  void localEnd() => _localSince = null;

  /// A remote live START / frame. Returns true when THIS rider must yield its own live talk (it lost a collision, a
  /// priority rider started, or it held the floor past the fair share while someone else wants it).
  bool remoteActivity(int speaker, int nowMs, {required bool priority, bool start = false}) {
    if (_holder != speaker || holderAt(nowMs) == null) {
      _holder = speaker;
      _holderPriority = priority;
      _since = nowMs;
    }
    _lastFrame = nowMs;
    final mine = _localSince;
    if (mine == null || !start) return false;
    if (priority && !_localPriority) return true;
    if (_localPriority && !priority) return false;
    if (nowMs - mine <= collisionMs) return speaker < myId; // simultaneous: lower id keeps it
    return !_localPriority && nowMs - mine >= fairHoldMs;
  }

  void remoteEnd(int speaker) {
    if (_holder == speaker) _holder = null;
  }

  void reset() {
    _holder = null;
    _localSince = null;
  }
}

/// Collects encoded frames of one talk into a clip (at most [MeshVoicePolicy.clipMaxMs]) and cuts it into chunks.
class ClipRecorder {
  ClipRecorder({required this.codec, required this.sampleRate, required this.frameMs, this.maxChunkBytes = 420});

  final int codec;
  final int sampleRate;
  final int frameMs;
  final int maxChunkBytes;
  final List<Uint8List> _frames = <Uint8List>[];

  int get durationMs => _frames.length * frameMs;
  bool get full => durationMs >= MeshVoicePolicy.clipMaxMs;
  bool get isEmpty => _frames.isEmpty;

  /// Adds one encoded frame. Returns false (and drops it) once the clip is full.
  bool add(Uint8List frame) {
    if (full || frame.isEmpty || frame.length > 0xffff) return false;
    _frames.add(Uint8List.fromList(frame));
    return true;
  }

  /// Chunk payloads: each a run of [len u16][frame].
  List<Uint8List> chunks() {
    final out = <Uint8List>[];
    var cur = BytesBuilder(copy: false);
    for (final f in _frames) {
      if (cur.length > 0 && cur.length + 2 + f.length > maxChunkBytes) {
        out.add(cur.takeBytes());
        cur = BytesBuilder(copy: false);
      }
      cur.add([(f.length >> 8) & 0xff, f.length & 0xff]);
      cur.add(f);
    }
    if (cur.length > 0) out.add(cur.takeBytes());
    return out;
  }

  static List<Uint8List> framesOf(Uint8List chunk) {
    final out = <Uint8List>[];
    var o = 0;
    while (o + 2 <= chunk.length) {
      final n = (chunk[o] << 8) | chunk[o + 1];
      if (n == 0 || o + 2 + n > chunk.length) break;
      out.add(Uint8List.sublistView(chunk, o + 2, o + 2 + n));
      o += 2 + n;
    }
    return out;
  }
}

class MeshClip {
  const MeshClip({required this.origin, required this.streamId, required this.name, required this.codec, required this.sampleRate, required this.frames, required this.durationMs, required this.complete, this.lead = false});
  final int origin;
  final int streamId;
  final String name;
  final int codec;
  final int sampleRate;
  final List<Uint8List> frames;
  final int durationMs;
  final bool complete;
  final bool lead;
}

/// Receiver side: chunks of a clip (any order, duplicates ignored) -> one [MeshClip] when complete, or a partial clip
/// after [partialAfterMs] when at least half of it arrived (gaps are skipped).
class ClipAssembler {
  ClipAssembler({this.partialAfterMs = 45000, this.maxPending = 16});

  final int partialAfterMs;
  final int maxPending;
  final Map<String, _ClipParts> _parts = <String, _ClipParts>{};
  final Set<String> _done = <String>{};

  MeshClip? add(int origin, MeshVoice v, int nowMs) {
    if (!v.clip || v.clipChunks <= 0 || v.frameSeq >= v.clipChunks) return null;
    final key = '$origin:${v.streamId}';
    if (_done.contains(key)) return null;
    final p = _parts.putIfAbsent(key, () => _ClipParts(origin, v, nowMs));
    p.chunks[v.frameSeq] = v.payload;
    p.lastAt = nowMs;
    if (_parts.length > maxPending) {
      final oldest = _parts.entries.reduce((a, b) => a.value.firstAt <= b.value.firstAt ? a : b).key;
      if (oldest != key) _parts.remove(oldest);
    }
    if (p.chunks.length == v.clipChunks) return _finish(key, complete: true);
    return null;
  }

  /// Clips that stopped growing for [quietMs]: which chunks are still missing (at most one request per clip every
  /// [quietMs], at most [maxRequests] per clip).
  List<({int origin, int streamId, int total, List<int> missing})> missing(int nowMs, {int quietMs = 4000, int maxRequests = 6}) {
    final out = <({int origin, int streamId, int total, List<int> missing})>[];
    for (final p in _parts.values) {
      if (nowMs - p.lastAt < quietMs || nowMs - p.askedAt < quietMs || p.asked >= maxRequests) continue;
      p.askedAt = nowMs;
      p.asked++;
      out.add((origin: p.origin, streamId: p.streamId, total: p.total, missing: [for (var i = 0; i < p.total; i++) if (!p.chunks.containsKey(i)) i]));
    }
    return out;
  }

  /// Partial clips that waited long enough.
  List<MeshClip> sweep(int nowMs) {
    final out = <MeshClip>[];
    for (final k in _parts.keys.toList()) {
      final p = _parts[k]!;
      if (nowMs - p.firstAt >= partialAfterMs) {
        if (p.chunks.length * 2 >= p.total) {
          out.add(_finish(k, complete: false));
        } else {
          _parts.remove(k);
          _done.add(k);
        }
      }
    }
    return out;
  }

  MeshClip _finish(String key, {required bool complete}) {
    final p = _parts.remove(key)!;
    _done.add(key);
    if (_done.length > 256) _done.remove(_done.first);
    final frames = <Uint8List>[];
    for (var i = 0; i < p.total; i++) {
      final c = p.chunks[i];
      if (c != null) frames.addAll(ClipRecorder.framesOf(c));
    }
    return MeshClip(
      origin: p.origin,
      streamId: p.streamId,
      name: p.name,
      codec: p.codec,
      sampleRate: p.rate,
      frames: frames,
      durationMs: p.durationMs,
      complete: complete,
      lead: p.lead,
    );
  }
}

class _ClipParts {
  _ClipParts(this.origin, MeshVoice v, this.firstAt)
      : streamId = v.streamId,
        total = v.clipChunks,
        codec = v.codec,
        rate = v.sampleRate,
        name = v.name,
        durationMs = v.clipDurationMs,
        lead = v.lead;
  final int origin;
  final int streamId;
  final int total;
  final int codec;
  final int rate;
  final String name;
  final int durationMs;
  final bool lead;
  final int firstAt;
  int lastAt = 0;
  int askedAt = -1 << 40;
  int asked = 0;
  final Map<int, Uint8List> chunks = <int, Uint8List>{};
}
