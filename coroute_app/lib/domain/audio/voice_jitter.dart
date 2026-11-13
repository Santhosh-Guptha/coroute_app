// Round 8 voice receive path (docs/features_355/voice_clarity.md): adaptive jitter buffer, packet loss
// concealment and clock-drift handling for intercom frames. Pure Dart (dart:math + dart:typed_data), unit
// tested with tool/pure_dart_test (test/voice_jitter_r8_test.dart).
//
// Frames are decoded PCM16 (Opus frames are decoded on arrival, PCM frames are already PCM), each with the
// sender's sequence number and the same duration ([frameMs], 40 ms on the wire today).
//
// * Adaptive delay: RFC 3550-style inter-arrival jitter J (exponential, 1/16) -> target = frame + 3 J, rounded
//   up to whole frames and clamped to [minDelayMs, maxDelayMs] (40-120 ms). It rises at once and falls
//   slowly (one frame per 2 s), so a bursty 4G link does not make the target saw-tooth.
// * Start / re-buffer: playout starts once the buffered audio reaches the target (or the stream's END came).
// * Loss: a missing sequence number is concealed when the buffer holds later frames ([pull] returns
//   [JitterPull.lost]); [Concealer] repeats the last frame with a fade (-6 dB per frame), at most 3 frames,
//   then silence. Late frames (already concealed) are dropped.
// * Drift: when the buffer stays more than 2 frames over the target for 1 s (sender clock faster than the
//   player, or a burst after a stall), the oldest frame is dropped; when the sender is slower the buffer
//   underruns and re-buffers, which raises the target.
// * Hard cap [maxQueueMs] (600 ms): the oldest frames go first, latency never grows past it.

import 'dart:math' as math;
import 'dart:typed_data';

enum JitterPullKind {
  /// A frame to play.
  frame,

  /// The next frame is missing and later ones are here: conceal one frame.
  lost,

  /// Nothing to play yet (buffering, or underrun): play nothing.
  wait,
}

class JitterPull {
  final JitterPullKind kind;
  final Int16List? pcm;
  final int seq;
  const JitterPull._(this.kind, this.pcm, this.seq);
  static const JitterPull waiting = JitterPull._(JitterPullKind.wait, null, -1);
  factory JitterPull.frame(int seq, Int16List pcm) => JitterPull._(JitterPullKind.frame, pcm, seq);
  factory JitterPull.lost(int seq) => JitterPull._(JitterPullKind.lost, null, seq);
}

class VoiceJitterBuffer {
  final int frameMs;
  final int minDelayMs;
  final int maxDelayMs;
  final int maxQueueMs;

  VoiceJitterBuffer({this.frameMs = 40, this.minDelayMs = 40, this.maxDelayMs = 120, this.maxQueueMs = 600})
      : assert(frameMs > 0 && minDelayMs <= maxDelayMs),
        _targetMs = minDelayMs;

  final Map<int, Int16List> _frames = {};
  int? _next; // next sequence number to play
  bool _playing = false;
  bool _ended = false;
  double _jitterMs = 0;
  double? _prevTransit;
  int _targetMs;
  int _lastLowerAt = 0;
  int _overSince = -1;

  // Stats (diagnostics and tests).
  int received = 0, played = 0, concealed = 0, late = 0, dropped = 0, underruns = 0;

  int get targetDelayMs => _targetMs;
  double get jitterMs => _jitterMs;
  bool get isPlaying => _playing;
  int get bufferedFrames => _frames.length;
  int get bufferedMs => _frames.length * frameMs;

  /// The sender's END arrived: whatever is buffered plays out without waiting for the target.
  void markEnded() => _ended = true;

  void reset() {
    _frames.clear();
    _next = null;
    _playing = false;
    _ended = false;
    _prevTransit = null;
    _overSince = -1;
  }

  /// A frame arrived at [nowMs] (monotonic ms).
  void push(int seq, Int16List pcm, int nowMs) {
    received++;
    // Jitter estimate from the transit-time variation (sender time = seq * frameMs).
    final transit = nowMs - seq * frameMs.toDouble();
    final prev = _prevTransit;
    if (prev != null) {
      final d = (transit - prev).abs();
      _jitterMs += (d - _jitterMs) / 16.0;
    }
    _prevTransit = transit;
    _adaptTarget(nowMs);

    final next = _next;
    if (next != null && _seqBefore(seq, next)) {
      if (played + concealed > 0) {
        late++; // already played or concealed
        return;
      }
      _next = seq; // reordered before playout started
    }
    if (_frames.containsKey(seq)) return; // duplicate
    _frames[seq] = pcm;
    _next ??= seq;
    // Hard cap: drop the oldest.
    while (_frames.length * frameMs > maxQueueMs) {
      final oldest = _oldest();
      if (oldest == null) break;
      _frames.remove(oldest);
      dropped++;
      _next = _oldest();
    }
  }

  /// Clock-driven playout: the player wants the next frame at [nowMs].
  JitterPull pull(int nowMs) {
    if (!_startIfReady()) return JitterPull.waiting;
    if (_next == null || _frames.isEmpty) {
      starved(nowMs);
      return JitterPull.waiting;
    }
    _dropForDrift(nowMs);
    return _take();
  }

  /// Arrival-driven playout (the intercom hands frames to a player queue as they come): every frame that
  /// can go now, in order, gaps concealed. Empty until the buffered audio first reaches the target, and
  /// again after [starved] (re-buffering).
  List<JitterPull> release(int nowMs) {
    final out = <JitterPull>[];
    if (!_startIfReady()) return out;
    while (_frames.isNotEmpty) {
      out.add(_take());
    }
    return out;
  }

  /// The player ran dry while the stream is live: re-buffer to a raised target before playing again.
  void starved(int nowMs) {
    if (!_playing) return;
    _playing = false;
    if (!_ended) {
      underruns++;
      _bumpTargetForUnderrun(nowMs);
    }
  }

  /// Drift control for a player queue that holds [queuedMs] of audio: true when one frame should be dropped
  /// now (the queue stayed more than 2 frames over the target for 1 s).
  bool driftDrop(int queuedMs, int nowMs) {
    if (queuedMs - _targetMs > 2 * frameMs) {
      if (_overSince < 0) _overSince = nowMs;
      if (nowMs - _overSince >= 1000) {
        _overSince = nowMs;
        dropped++;
        return true;
      }
    } else {
      _overSince = -1;
    }
    return false;
  }

  bool _startIfReady() {
    if (_playing) return true;
    final enough = _frames.length * frameMs >= _targetMs || (_ended && _frames.isNotEmpty);
    if (!enough) return false;
    _playing = true;
    _overSince = -1;
    return true;
  }

  JitterPull _take() {
    final seq = _next ?? _oldest()!;
    final f = _frames.remove(seq);
    if (f != null) {
      _next = seq + 1;
      played++;
      return JitterPull.frame(seq, f);
    }
    // Missing frame while later ones are buffered: conceal it. A long gap (more than the concealer can
    // cover) is skipped after one concealed frame, so it never adds its length to the delay.
    concealed++;
    final oldest = _oldest();
    _next = (oldest != null && oldest - seq > Concealer.maxRepeats) ? oldest : seq + 1;
    return JitterPull.lost(seq);
  }

  void _adaptTarget(int nowMs) {
    final want = _roundUpFrames(frameMs + 3 * _jitterMs).clamp(minDelayMs, maxDelayMs);
    if (want > _targetMs) {
      _targetMs = want;
      _lastLowerAt = nowMs;
    } else if (want < _targetMs && nowMs - _lastLowerAt >= 2000) {
      _targetMs = math.max(want, _targetMs - frameMs);
      _lastLowerAt = nowMs;
    }
  }

  void _bumpTargetForUnderrun(int nowMs) {
    if (_ended) return;
    _targetMs = math.min(maxDelayMs, _targetMs + frameMs);
    _lastLowerAt = nowMs;
  }

  void _dropForDrift(int nowMs) {
    final over = _frames.length * frameMs - _targetMs;
    if (over > 2 * frameMs) {
      if (_overSince < 0) _overSince = nowMs;
      if (nowMs - _overSince >= 1000) {
        final oldest = _oldest();
        if (oldest != null) {
          _frames.remove(oldest);
          dropped++;
          _next = _oldest() ?? (oldest + 1);
        }
        _overSince = nowMs;
      }
    } else {
      _overSince = -1;
    }
  }

  int _roundUpFrames(double ms) => (ms / frameMs).ceil() * frameMs;

  int? _oldest() {
    int? best;
    for (final k in _frames.keys) {
      if (best == null || _seqBefore(k, best)) best = k;
    }
    return best;
  }

  /// Sequence numbers are plain ints from the sender (31-bit counters in practice); no wrap handling needed
  /// within one 60 s stream at 25 frames/s.
  static bool _seqBefore(int a, int b) => a < b;
}

/// Packet loss concealment on PCM16: fade-repeat of the last good frame (-6 dB per lost frame, 3 frames at
/// most, then silence) and a short cross-fade back into the next good frame (no click).
class Concealer {
  static const int maxRepeats = 3;
  Int16List? _last;
  int _lost = 0;

  /// Feed every good frame; returns the frame to play (cross-faded after a loss).
  Int16List good(Int16List pcm) {
    var out = pcm;
    if (_lost > 0 && _last != null) {
      out = Int16List.fromList(pcm);
      final prev = _last!;
      final n = math.min(out.length, math.min(prev.length, 80)); // 5 ms at 16 kHz
      final g0 = _lost <= maxRepeats ? math.pow(0.5, _lost).toDouble() : 0.0;
      for (var i = 0; i < n; i++) {
        final a = i / n;
        out[i] = (out[i] * a + prev[i] * g0 * (1 - a)).round().clamp(-32768, 32767);
      }
    }
    _last = pcm;
    _lost = 0;
    return out;
  }

  /// One lost frame of [length] samples: the faded repeat, or silence after [maxRepeats].
  Int16List lost(int length) {
    _lost++;
    final out = Int16List(length);
    final prev = _last;
    if (prev == null || _lost > maxRepeats) return out;
    final gStart = math.pow(0.5, _lost - 1).toDouble();
    final gEnd = math.pow(0.5, _lost).toDouble();
    final n = math.min(length, prev.length);
    for (var i = 0; i < n; i++) {
      final g = gStart + (gEnd - gStart) * (i / n);
      out[i] = (prev[i] * g).round().clamp(-32768, 32767);
    }
    return out;
  }

  void reset() {
    _last = null;
    _lost = 0;
  }
}
