// Round 10 offline link: IMA ADPCM (4 bits per sample), the PCM fallback for live talk over the mesh when the phone has
// no Opus encoder. 8 kHz -> 32 kbit/s: only for near neighbours on 1M/2M PHY (Coded PHY cannot carry it; clips then).
// Every block starts with its own predictor state (3 bytes), so a lost block never corrupts the next one.
// Public-domain algorithm (IMA / DVI ADPCM). Pure Dart, tested in test/mesh_voice_test.dart.
library;

import 'dart:typed_data';

class ImaAdpcm {
  static const List<int> _step = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
    130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060,
    1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484,
    7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
  ];
  static const List<int> _index = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8];

  /// One block: [predictor i16 BE][index u8][samples/2 bytes, low nibble first].
  static Uint8List encodeBlock(Int16List pcm) {
    final out = Uint8List(3 + (pcm.length + 1) ~/ 2);
    var pred = pcm.isEmpty ? 0 : pcm[0];
    var idx = 0;
    // Pick a starting step close to the block's first difference (faster convergence).
    if (pcm.length > 1) {
      final d = (pcm[1] - pcm[0]).abs();
      while (idx < 88 && _step[idx] < d) {
        idx++;
      }
    }
    out[0] = (pred >> 8) & 0xff;
    out[1] = pred & 0xff;
    out[2] = idx;
    for (var i = 0; i < pcm.length; i++) {
      final step = _step[idx];
      var diff = pcm[i] - pred;
      var code = 0;
      if (diff < 0) {
        code = 8;
        diff = -diff;
      }
      var delta = step >> 3;
      if (diff >= step) {
        code |= 4;
        diff -= step;
        delta += step;
      }
      if (diff >= step >> 1) {
        code |= 2;
        diff -= step >> 1;
        delta += step >> 1;
      }
      if (diff >= step >> 2) {
        code |= 1;
        delta += step >> 2;
      }
      pred = (code & 8) != 0 ? pred - delta : pred + delta;
      if (pred > 32767) pred = 32767;
      if (pred < -32768) pred = -32768;
      idx += _index[code];
      if (idx < 0) idx = 0;
      if (idx > 88) idx = 88;
      final o = 3 + (i >> 1);
      out[o] |= (i & 1) == 0 ? code : code << 4;
    }
    return out;
  }

  static Int16List decodeBlock(Uint8List b, int samples) {
    final out = Int16List(samples);
    if (b.length < 3) return out;
    var pred = (b[0] << 8) | b[1];
    if (pred >= 0x8000) pred -= 0x10000;
    var idx = b[2].clamp(0, 88);
    for (var i = 0; i < samples; i++) {
      final o = 3 + (i >> 1);
      if (o >= b.length) break;
      final code = (i & 1) == 0 ? b[o] & 0x0f : (b[o] >> 4) & 0x0f;
      final step = _step[idx];
      var delta = step >> 3;
      if ((code & 4) != 0) delta += step;
      if ((code & 2) != 0) delta += step >> 1;
      if ((code & 1) != 0) delta += step >> 2;
      pred = (code & 8) != 0 ? pred - delta : pred + delta;
      if (pred > 32767) pred = 32767;
      if (pred < -32768) pred = -32768;
      idx += _index[code];
      if (idx < 0) idx = 0;
      if (idx > 88) idx = 88;
      out[i] = pred;
    }
    return out;
  }

  /// 2:1 decimation 16 kHz -> 8 kHz with a short low-pass (voice band only).
  static Int16List downsample16to8(Int16List x) {
    final out = Int16List(x.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final a = x[2 * i];
      final b = 2 * i + 1 < x.length ? x[2 * i + 1] : a;
      final c = 2 * i - 1 >= 0 ? x[2 * i - 1] : a;
      out[i] = ((c + 2 * a + b) >> 2).clamp(-32768, 32767);
    }
    return out;
  }
}
