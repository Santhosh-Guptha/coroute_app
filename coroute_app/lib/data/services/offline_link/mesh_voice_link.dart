// Round 10 offline link: intercom <-> mesh voice. The intercom hands its START / FRAME / END (already through the RNNoise
// chain, Opus-encoded when the phone has the encoder) to [MeshVoiceLink.fromIntercom]; this decides live or clip per
// talk ([MeshVoicePolicy]), keeps the one-speaker floor ([MeshFloor]) and puts frames on the mesh. Received live frames
// and finished clips come back as the same VoicePacket the gateway would deliver, so the intercom's jitter buffer,
// Opus decoder, ducking and limiter are reused unchanged. Clips play at real-time pace when the floor is free, with a
// "Voice message from Ravi" notice.
library;

import 'dart:async';
import 'dart:typed_data';

import '../../../domain/mesh/mesh_adpcm.dart';
import '../../../domain/mesh/mesh_frame.dart';
import '../../../domain/mesh/mesh_messages.dart';
import '../../../domain/mesh/mesh_node.dart';
import '../../../domain/mesh/mesh_voice.dart';
import '../realtime_service.dart' show VoiceKind, VoicePacket;

class MeshVoiceEnv {
  const MeshVoiceEnv({required this.neighbours, required this.maxHops, required this.loss, required this.linkBytesPerSec, required this.coded, required this.strongNearLink});
  final int neighbours;
  final int maxHops;
  final double loss;
  final int linkBytesPerSec;
  final bool coded;
  final bool strongNearLink;
}

class _TxTalk {
  _TxTalk(this.plan, this.streamId, this.lead);
  MeshTalkPlan plan;
  final int streamId;
  final bool lead;
  int seq = 0;
  bool sentStart = false;
  final List<Uint8List> pendingFrames = <Uint8List>[];
  ClipRecorder? clip;
  int pcmRate = 16000;
}

class MeshVoiceLink {
  MeshVoiceLink({required this.engine, required this.clockMs, required this.env, required this.userIdOf, required this.nameOf, required this.deliver});

  final MeshNodeEngine engine;
  final int Function() clockMs;
  final MeshVoiceEnv Function() env;
  final String? Function(int shortId) userIdOf;
  final String Function(int shortId) nameOf;

  /// To the intercom (IntercomService.deliverOfflineVoice).
  final void Function(VoicePacket p) deliver;

  /// "Voice message from Ravi" while a clip plays (null otherwise).
  void Function(String? notice)? onClipNotice;

  final MeshFloor floor = MeshFloor();
  _TxTalk? _tx;
  bool opusEncoder = false;
  final List<MeshClip> _clipQueue = <MeshClip>[];
  Timer? _clipTimer;
  final Map<int, int> _rxSeq = <int, int>{};
  final Map<int, int> _rxStream = <int, int>{};

  /// Plan for the next talk (what the intercom should encode).
  MeshTalkPlan currentPlan({bool priority = false}) {
    final e = env();
    return MeshVoicePolicy.plan(
      neighbours: e.neighbours,
      maxHops: e.maxHops,
      loss: e.loss,
      linkBytesPerSec: e.linkBytesPerSec,
      coded: e.coded,
      opusEncoder: opusEncoder,
      strongNearLink: e.strongNearLink,
      floorFree: floor.canTalk(clockMs(), priority: priority),
    );
  }

  // ------------------------------------------------------------------------------------------------ transmit
  void fromIntercom(int kind, Map<String, dynamic> header, Uint8List? payload) {
    final lead = header['priority'] == true || header['role'] == 'LEAD';
    switch (kind) {
      case VoiceKind.start:
        final plan = currentPlan(priority: lead);
        final t = _TxTalk(plan, engine.newStreamId(), lead);
        t.pcmRate = (header['sampleRate'] as num?)?.toInt() ?? 16000;
        if (plan.mode == MeshTalkMode.live) {
          floor.myId = engine.myId;
          floor.localStart(clockMs(), priority: lead);
        } else {
          t.clip = ClipRecorder(codec: plan.codec, sampleRate: plan.sampleRate, frameMs: 40);
        }
        _tx = t;
      case VoiceKind.frame:
        final t = _tx;
        if (t == null || payload == null || payload.isEmpty) return;
        final frame = _encodeForAir(t, header, payload);
        if (frame == null) return;
        final clip = t.clip;
        if (clip != null) {
          clip.add(frame); // a full clip (15 s) ignores the rest of the talk
          return;
        }
        t.pendingFrames.add(frame);
        if (t.pendingFrames.length * 40 >= MeshVoicePolicy.liveFrameMs) _flushLive(t, end: false);
      case VoiceKind.end:
        final t = _tx;
        _tx = null;
        if (t == null) return;
        if (t.clip != null) {
          if (!t.clip!.isEmpty) engine.sendClip(t.clip!, streamId: t.streamId, lead: t.lead);
        } else {
          _flushLive(t, end: true);
          floor.localEnd();
        }
    }
  }

  /// Opus frames go as they are; PCM16 becomes IMA ADPCM at 8 kHz (4:1).
  Uint8List? _encodeForAir(_TxTalk t, Map<String, dynamic> header, Uint8List payload) {
    if (t.plan.codec == MeshVoiceCodec.opus) {
      final codec = header['codec']?.toString();
      if (codec != null && codec != 'opus1') return null; // the intercom fell back to PCM mid-talk: drop (rare)
      return payload;
    }
    final even = payload.length & ~1;
    final pcm = Int16List.view(Uint8List.fromList(Uint8List.sublistView(payload, 0, even)).buffer, 0, even ~/ 2);
    final at8 = t.pcmRate == 8000 ? pcm : ImaAdpcm.downsample16to8(pcm);
    return ImaAdpcm.encodeBlock(at8);
  }

  void _flushLive(_TxTalk t, {required bool end}) {
    if (t.pendingFrames.isEmpty && !end) return;
    final b = BytesBuilder(copy: false);
    for (final f in t.pendingFrames) {
      b.add([(f.length >> 8) & 0xff, f.length & 0xff]);
      b.add(f);
    }
    t.pendingFrames.clear();
    engine.sendLiveVoice(MeshVoice(
      streamId: t.streamId,
      frameSeq: t.seq++,
      codec: t.plan.codec,
      sampleRate: t.plan.sampleRate,
      payload: b.takeBytes(),
      start: !t.sentStart,
      end: end,
      lead: t.lead,
      name: t.sentStart ? '' : engine.myName,
    ));
    t.sentStart = true;
  }

  // ------------------------------------------------------------------------------------------------- receive
  void onLiveVoice(int origin, MeshVoice v, MeshFrame f) {
    final now = clockMs();
    final mustYield = floor.remoteActivity(origin, now, priority: v.lead, start: v.start);
    final t = _tx;
    if (mustYield && t != null && t.clip == null) {
      // We lost the floor: the rest of this talk becomes a clip (nothing is lost).
      _flushLive(t, end: true);
      floor.localEnd();
      t.clip = ClipRecorder(codec: t.plan.codec, sampleRate: t.plan.sampleRate, frameMs: 40);
      t.plan = MeshTalkPlan(mode: MeshTalkMode.clip, codec: t.plan.codec, sampleRate: t.plan.sampleRate, bitrate: t.plan.bitrate, reason: 'yielded the floor');
    }
    final uid = userIdOf(origin);
    if (uid == null) return;
    final sid = 'mesh:${origin.toRadixString(16)}:${v.streamId}';
    final known = _rxStream[origin] == v.streamId;
    if (v.start || !known) {
      _rxStream[origin] = v.streamId;
      _rxSeq[origin] = 0;
      deliver(VoicePacket(VoiceKind.start, _header(uid, origin, sid, v, v.name), Uint8List(0)));
    }
    _deliverFrames(uid, origin, sid, v, ClipRecorder.framesOf(v.payload));
    if (v.end) {
      deliver(VoicePacket(VoiceKind.end, _header(uid, origin, sid, v, ''), Uint8List(0)));
      floor.remoteEnd(origin);
      _rxStream.remove(origin);
      _pumpClips();
    }
  }

  Map<String, dynamic> _header(String uid, int origin, String sid, MeshVoice v, String name) => <String, dynamic>{
        'streamId': sid,
        'from': uid,
        'fromName': name.isNotEmpty ? name : nameOf(origin),
        'codec': v.codec == MeshVoiceCodec.opus ? 'opus1' : 'pcm16',
        'sampleRate': v.codec == MeshVoiceCodec.opus ? 16000 : 8000,
        'channel': 'ALL',
        'mesh': true,
        if (v.clip) 'clip': true,
        if (v.lead) 'role': 'LEAD',
      };

  void _deliverFrames(String uid, int origin, String sid, MeshVoice v, List<Uint8List> frames) {
    for (final fr in frames) {
      final seq = _rxSeq[origin] = (_rxSeq[origin] ?? 0) + 1;
      final payload = v.codec == MeshVoiceCodec.adpcm ? _adpcmToPcm(fr) : Uint8List.fromList(fr);
      deliver(VoicePacket(VoiceKind.frame, <String, dynamic>{'streamId': sid, 'from': uid, 'seq': seq, 'codec': v.codec == MeshVoiceCodec.opus ? 'opus1' : 'pcm16'}, payload));
    }
  }

  static Uint8List _adpcmToPcm(Uint8List block) {
    final samples = (block.length - 3) * 2;
    final pcm = ImaAdpcm.decodeBlock(block, samples < 0 ? 0 : samples);
    return Uint8List.view(pcm.buffer, 0, pcm.lengthInBytes);
  }

  // ---------------------------------------------------------------------------------------------------- clips
  void onClip(MeshClip clip) {
    if (_clipQueue.length >= 8) _clipQueue.removeAt(0);
    _clipQueue.add(clip);
    _pumpClips();
  }

  void _pumpClips() {
    if (_clipTimer != null || _clipQueue.isEmpty) return;
    final now = clockMs();
    if (floor.holderAt(now) != null || _tx != null) {
      // Someone is talking live (or this rider is): try again shortly.
      _clipTimer = Timer(const Duration(milliseconds: 800), () {
        _clipTimer = null;
        _pumpClips();
      });
      return;
    }
    final clip = _clipQueue.removeAt(0);
    final uid = userIdOf(clip.origin);
    if (uid == null) return _pumpClips();
    final name = clip.name.isNotEmpty ? clip.name : nameOf(clip.origin);
    onClipNotice?.call('Voice message from $name');
    final v = MeshVoice(streamId: clip.streamId, frameSeq: 0, codec: clip.codec, sampleRate: clip.sampleRate, payload: Uint8List(0), clip: true, lead: clip.lead);
    final sid = 'clip:${clip.origin.toRadixString(16)}:${clip.streamId}';
    _rxSeq[clip.origin] = 0;
    deliver(VoicePacket(VoiceKind.start, _header(uid, clip.origin, sid, v, name), Uint8List(0)));
    var i = 0;
    // Real-time pace (40 ms per frame): the intercom's jitter buffer expects a live stream.
    _clipTimer = Timer.periodic(const Duration(milliseconds: 40), (timer) {
      if (i < clip.frames.length) {
        _deliverFrames(uid, clip.origin, sid, v, [clip.frames[i++]]);
        return;
      }
      timer.cancel();
      deliver(VoicePacket(VoiceKind.end, _header(uid, clip.origin, sid, v, ''), Uint8List(0)));
      _clipTimer = Timer(const Duration(milliseconds: 600), () {
        _clipTimer = null;
        onClipNotice?.call(null);
        _pumpClips();
      });
    });
  }

  void reset() {
    _clipTimer?.cancel();
    _clipTimer = null;
    _clipQueue.clear();
    _tx = null;
    floor.reset();
    onClipNotice?.call(null);
  }
}
