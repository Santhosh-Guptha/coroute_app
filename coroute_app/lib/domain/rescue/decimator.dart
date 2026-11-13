// Round 10 rescue beacon: 48 kHz -> 16 kHz for the ride mic hub (pure Dart).
//
// While a rescue listener needs the near-ultrasonic band, the one ride capture runs at 48 kHz.
// The siren detector and the intercom keep getting the 16 kHz frames they always got, through
// this low-pass + keep-every-third-sample filter: a 63-tap windowed-sinc FIR (Blackman window,
// cut-off 7.2 kHz), computed only for the samples kept (polyphase), so about 63 multiply-adds
// per output sample. Pass band (voice, sirens up to 7 kHz) within a fraction of a dB; everything
// above 8.8 kHz (which would fold back as aliasing) is attenuated by more than 50 dB.
import 'dart:math' as math;
import 'dart:typed_data';

class Decimator3 {
  Decimator3() : _taps = _design();

  static const int factor = 3;
  static const int length = 63;

  final Float64List _taps;
  final Float64List _hist = Float64List(length);
  int _pos = 0; // next write index in the circular history
  int _phase = 0; // input samples since the last output

  static Float64List _design() {
    const fs = 48000.0, fc = 7200.0;
    final h = Float64List(length);
    const m = length - 1;
    var sum = 0.0;
    for (var n = 0; n < length; n++) {
      final x = n - m / 2;
      final sinc = x == 0 ? 2 * fc / fs : math.sin(2 * math.pi * fc / fs * x) / (math.pi * x);
      final w = 0.42 - 0.5 * math.cos(2 * math.pi * n / m) + 0.08 * math.cos(4 * math.pi * n / m);
      h[n] = sinc * w;
      sum += h[n];
    }
    for (var n = 0; n < length; n++) {
      h[n] /= sum; // unity gain at DC
    }
    return h;
  }

  void reset() {
    _hist.fillRange(0, length, 0);
    _pos = 0;
    _phase = 0;
  }

  /// Feeds 48 kHz PCM16 samples; returns the 16 kHz PCM16 samples they complete.
  Int16List process(Int16List input) {
    final out = Int16List((input.length + _phase) ~/ factor + 1);
    var o = 0;
    for (var i = 0; i < input.length; i++) {
      _hist[_pos] = input[i].toDouble();
      _pos = (_pos + 1) % length;
      _phase++;
      if (_phase == factor) {
        _phase = 0;
        var acc = 0.0;
        var idx = _pos; // oldest sample
        for (var k = length - 1; k >= 0; k--) {
          acc += _taps[k] * _hist[idx];
          idx++;
          if (idx == length) idx = 0;
        }
        out[o++] = acc.round().clamp(-32768, 32767);
      }
    }
    return Int16List.sublistView(out, 0, o);
  }
}
