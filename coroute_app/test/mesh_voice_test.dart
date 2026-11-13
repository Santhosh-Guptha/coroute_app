import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/mesh/mesh_adpcm.dart';
import 'package:coroute_app/domain/mesh/mesh_messages.dart';
import 'package:coroute_app/domain/mesh/mesh_voice.dart';

// Round 10 offline link: live-or-clip policy, the mesh floor, clip chunking / reassembly and the ADPCM fallback
// (pure Dart: tool/pure_dart_test/run.sh test/mesh_voice_test.dart).
void main() {
  group('live or clip', () {
    MeshTalkPlan plan({int neighbours = 2, int hops = 2, double loss = 0.02, int link = 6000, bool coded = true, bool opus = true, bool strong = false, bool floorFree = true}) =>
        MeshVoicePolicy.plan(neighbours: neighbours, maxHops: hops, loss: loss, linkBytesPerSec: link, coded: coded, opusEncoder: opus, strongNearLink: strong, floorFree: floorFree);

    test('Opus live at 12 kbit/s over a few Coded PHY hops', () {
      final p = plan();
      expect(p.mode, MeshTalkMode.live);
      expect(p.codec, MeshVoiceCodec.opus);
      expect(p.bitrate, 12000);
    });
    test('8 kbit/s on a slow link, clip when even that does not fit', () {
      expect(plan(link: 4200).bitrate, 8000);
      expect(plan(link: 3000).mode, MeshTalkMode.clip);
    });
    test('no path, too many hops, too lossy, floor busy -> walkie-talkie clip', () {
      expect(plan(neighbours: 0).mode, MeshTalkMode.clip);
      expect(plan(hops: 6).mode, MeshTalkMode.clip);
      expect(plan(loss: 0.3).mode, MeshTalkMode.clip);
      expect(plan(floorFree: false).mode, MeshTalkMode.clip);
    });
    test('no Opus encoder: ADPCM live only to a strong near neighbour on a fast PHY, else an ADPCM clip', () {
      final near = plan(opus: false, strong: true, hops: 1, link: 25000, coded: false);
      expect([near.mode, near.codec, near.sampleRate], [MeshTalkMode.live, MeshVoiceCodec.adpcm, 8000]);
      final far = plan(opus: false, strong: false, hops: 2);
      expect([far.mode, far.codec], [MeshTalkMode.clip, MeshVoiceCodec.adpcm]);
    });
  });

  group('mesh floor', () {
    test('one speaker; Lead may cut in; fair share after 20 s; a stale floor frees itself', () {
      final f = MeshFloor()..myId = 50;
      expect(f.canTalk(0, priority: false), isTrue);
      f.remoteActivity(7, 0, priority: false, start: true);
      expect(f.canTalk(500, priority: false), isFalse);
      expect(f.canTalk(500, priority: true), isTrue, reason: 'the Lead may cut in');
      for (var t = 0; t <= 21000; t += 500) {
        f.remoteActivity(7, t, priority: false);
      }
      expect(f.canTalk(21000, priority: false), isTrue, reason: 'fair share after 20 s');
      expect(f.canTalk(23000, priority: false), isTrue, reason: 'no frame for 1.5 s: free');
    });
    test('collision: two starts within 300 ms - the lower rider id keeps it; a priority start wins', () {
      final f = MeshFloor()..myId = 50;
      f.localStart(1000, priority: false);
      expect(f.remoteActivity(70, 1100, priority: false, start: true), isFalse, reason: 'I (50) keep it against 70');
      expect(f.remoteActivity(20, 1150, priority: false, start: true), isTrue, reason: '20 keeps it against me');
      final g = MeshFloor()..myId = 50;
      g.localStart(0, priority: false);
      expect(g.remoteActivity(90, 5000, priority: true, start: true), isTrue, reason: 'the Lead starts: I yield');
    });
  });

  group('clips', () {
    test('a 15 s cap, chunks under the frame budget, reassembled in any order with duplicates', () {
      final rec = ClipRecorder(codec: MeshVoiceCodec.opus, sampleRate: 16000, frameMs: 40);
      final rnd = math.Random(3);
      var n = 0;
      while (rec.add(Uint8List.fromList(List.generate(60 + rnd.nextInt(10), (i) => (n + i) & 0xff)))) {
        n++;
      }
      expect(rec.durationMs, 15000);
      expect(n, 375);
      final chunks = rec.chunks();
      expect(chunks.every((c) => c.length <= 420), isTrue);
      final asm = ClipAssembler();
      final order = List.generate(chunks.length, (i) => i)..shuffle(rnd);
      MeshClip? clip;
      for (final i in [...order, order.first]) {
        final v = MeshVoice(streamId: 9, frameSeq: i, codec: MeshVoiceCodec.opus, sampleRate: 16000, payload: chunks[i], clip: true, clipChunks: chunks.length, clipDurationMs: 15000, name: 'Ravi');
        clip ??= asm.add(42, v, 0);
      }
      expect(clip, isNotNull);
      expect(clip!.complete, isTrue);
      expect(clip.frames.length, 375);
      expect(clip.name, 'Ravi');
      expect(clip.frames[10][0], 10);
      expect(asm.add(42, MeshVoice(streamId: 9, frameSeq: 0, codec: 1, sampleRate: 16000, payload: chunks[0], clip: true, clipChunks: chunks.length), 1), isNull, reason: 'played once');
    });
    test('missing chunks are requested, and a partial clip (half or more) plays after 45 s', () {
      final asm = ClipAssembler();
      for (final i in [0, 1, 2, 4, 5]) {
        asm.add(1, MeshVoice(streamId: 3, frameSeq: i, codec: 1, sampleRate: 16000, payload: Uint8List.fromList([0, 1, 9]), clip: true, clipChunks: 8), 0);
      }
      expect(asm.missing(1000), isEmpty, reason: 'wait for the clip to stop growing');
      final m = asm.missing(5000);
      expect(m.single.missing, [3, 6, 7]);
      expect(MeshClipNack.decode(MeshClipNack(origin: 1, streamId: 3, total: 8, missing: m.single.missing).encode())!.missing, [3, 6, 7]);
      final partial = asm.sweep(46000);
      expect(partial.single.complete, isFalse);
      expect(partial.single.frames.length, 5);
    });
  });

  test('IMA ADPCM: 4:1, independent blocks, speech-like signal survives (SNR > 15 dB)', () {
    final pcm = Int16List(320);
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] = (6000 * math.sin(2 * math.pi * 300 * i / 8000) + 3000 * math.sin(2 * math.pi * 1100 * i / 8000)).round();
    }
    final enc = ImaAdpcm.encodeBlock(pcm);
    expect(enc.length, 3 + 160);
    final dec = ImaAdpcm.decodeBlock(enc, pcm.length);
    var sig = 0.0, err = 0.0;
    for (var i = 20; i < pcm.length; i++) {
      sig += pcm[i] * pcm[i].toDouble();
      err += (pcm[i] - dec[i]) * (pcm[i] - dec[i]).toDouble();
    }
    final snr = 10 * math.log(sig / err) / math.ln10;
    expect(snr, greaterThan(15));
    expect(ImaAdpcm.downsample16to8(Int16List(640)).length, 320);
  });
}
