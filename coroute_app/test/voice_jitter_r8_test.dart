// Round 8: adaptive jitter buffer, concealment and drift (pure Dart; tool/pure_dart_test/run.sh).
import 'dart:typed_data';

import 'package:coroute_app/domain/audio/voice_jitter.dart';
import 'package:flutter_test/flutter_test.dart';

Int16List frame(int v, [int n = 640]) => Int16List(n)..fillRange(0, n, v);

void main() {
  group('VoiceJitterBuffer', () {
    test('waits for the target (40 ms = one 40 ms frame) before playing, then plays in order', () {
      final jb = VoiceJitterBuffer(frameMs: 40);
      expect(jb.targetDelayMs, 40);
      expect(jb.pull(0).kind, JitterPullKind.wait);
      jb.push(0, frame(1), 0);
      final a = jb.pull(0);
      expect(a.kind, JitterPullKind.frame);
      expect(a.seq, 0);
      jb.push(1, frame(2), 40);
      expect(jb.pull(40).seq, 1);
    });

    test('steady arrivals keep the target at the 40 ms minimum', () {
      final jb = VoiceJitterBuffer(frameMs: 40);
      for (var i = 0; i < 100; i++) {
        jb.push(i, frame(i), 1000 + i * 40);
        jb.pull(1000 + i * 40);
      }
      expect(jb.targetDelayMs, 40);
      expect(jb.jitterMs, lessThan(1));
    });

    test('bursty arrivals (4G head-of-line blocking) raise the target, capped at 120 ms', () {
      final jb = VoiceJitterBuffer(frameMs: 40);
      var t = 0;
      for (var i = 0; i < 200; i++) {
        // every 5th frame arrives 150 ms late, the next ones bunch up behind it
        t = 1000 + i * 40 + ((i % 5 == 0) ? 150 : 0);
        jb.push(i, frame(i), t);
      }
      expect(jb.targetDelayMs, greaterThan(40));
      expect(jb.targetDelayMs, lessThanOrEqualTo(120));
    });

    test('the target falls back slowly (one frame per 2 s) when the link calms down', () {
      final jb = VoiceJitterBuffer(frameMs: 40);
      for (var i = 0; i < 50; i++) {
        jb.push(i, frame(i), 1000 + i * 40 + ((i % 3 == 0) ? 120 : 0));
        jb.release(1000 + i * 40);
      }
      final high = jb.targetDelayMs;
      expect(high, greaterThan(40));
      for (var i = 50; i < 400; i++) {
        jb.push(i, frame(i), 1000 + i * 40);
        jb.release(1000 + i * 40);
      }
      expect(jb.targetDelayMs, lessThan(high));
    });

    test('a missing frame with later frames buffered is concealed; a late arrival is dropped', () {
      final jb = VoiceJitterBuffer(frameMs: 40);
      jb.push(0, frame(1), 0);
      expect(jb.pull(0).kind, JitterPullKind.frame);
      jb.push(2, frame(3), 80);
      final r = jb.pull(80);
      expect(r.kind, JitterPullKind.lost);
      expect(r.seq, 1);
      expect(jb.pull(80).seq, 2);
      jb.push(1, frame(2), 90);
      expect(jb.late, 1);
      expect(jb.concealed, 1);
    });

    test('a long gap (relay dropped 10 frames) is skipped after one concealed frame', () {
      final jb = VoiceJitterBuffer(frameMs: 40);
      jb.push(0, frame(1), 0);
      jb.pull(0);
      jb.push(11, frame(2), 440);
      final out = jb.release(440);
      expect(out.map((e) => e.kind).toList(), [JitterPullKind.lost, JitterPullKind.frame]);
      expect(out.last.seq, 11);
    });

    test('frames reordered before playout starts are played in order; duplicates ignored', () {
      final jb = VoiceJitterBuffer(frameMs: 40, minDelayMs: 80);
      jb.push(1, frame(2), 0);
      jb.push(0, frame(1), 1);
      jb.push(0, frame(9), 2);
      final out = jb.release(2);
      expect(out.map((e) => e.seq).toList(), [0, 1]);
      expect(out.first.pcm![0], 1);
    });

    test('release is arrival-driven: starved() re-buffers to a raised target', () {
      final jb = VoiceJitterBuffer(frameMs: 40);
      jb.push(0, frame(1), 0);
      expect(jb.release(0).length, 1);
      jb.starved(100);
      expect(jb.underruns, 1);
      expect(jb.targetDelayMs, 80);
      jb.push(1, frame(2), 120);
      expect(jb.release(120), isEmpty, reason: 'one frame < 80 ms target');
      jb.push(2, frame(3), 160);
      expect(jb.release(160).length, 2);
    });

    test('after END the tail plays out even below the target', () {
      final jb = VoiceJitterBuffer(frameMs: 40, minDelayMs: 120);
      jb.push(0, frame(1), 0);
      expect(jb.release(0), isEmpty);
      jb.markEnded();
      expect(jb.release(10).length, 1);
    });

    test('drift: a player queue 3 frames over the target for 1 s drops one frame', () {
      final jb = VoiceJitterBuffer(frameMs: 40);
      expect(jb.driftDrop(200, 0), isFalse);
      expect(jb.driftDrop(200, 500), isFalse);
      expect(jb.driftDrop(200, 1000), isTrue);
      expect(jb.driftDrop(80, 1100), isFalse);
    });

    test('hard cap: never more than 600 ms buffered', () {
      final jb = VoiceJitterBuffer(frameMs: 40, minDelayMs: 120);
      for (var i = 0; i < 40; i++) {
        jb.push(i, frame(i), 0);
      }
      expect(jb.bufferedMs, lessThanOrEqualTo(600));
      expect(jb.dropped, greaterThan(0));
    });
  });

  group('Concealer', () {
    test('fade-repeat -6 dB per lost frame, silence after 3, cross-fade back', () {
      final c = Concealer();
      c.good(frame(16000, 320));
      final l1 = c.lost(320);
      expect(l1.first, 16000);
      expect(l1.last, closeTo(8000, 60));
      final l2 = c.lost(320);
      expect(l2.last, closeTo(4000, 40));
      c.lost(320);
      final l4 = c.lost(320);
      expect(l4.every((v) => v == 0), isTrue);
      final back = c.good(frame(1000, 320));
      expect(back[0], 0, reason: 'starts from the faded (silent) tail');
      expect(back[200], 1000);
    });

    test('nothing to repeat yet: silence', () {
      expect(Concealer().lost(160).every((v) => v == 0), isTrue);
    });
  });
}
