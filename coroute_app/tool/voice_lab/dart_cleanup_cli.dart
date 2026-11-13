// Round 8 voice lab: runs the 3.55 pure-Dart VoiceCleanup (the "Normal without native" path, and the
// post-stage of Strong) over a 16 kHz mono WAV, 20 ms blocks as in the app.
// Usage: dart run tool/voice_lab/dart_cleanup_cli.dart <spectral 0|1> <gate 0|1> <agc 0|1> in.wav out.wav
// (spectral 0 = the Strong post-stage: no Wiener and no wind class, as in the app with the native stage)
import 'dart:io';
import 'dart:typed_data';

import 'package:coroute_app/domain/audio/voice_cleanup.dart';

void main(List<String> a) {
  final spectral = a[0] == '1', gate = a[1] == '1', agc = a[2] == '1';
  final bytes = File(a[3]).readAsBytesSync();
  final bd = ByteData.sublistView(bytes);
  var off = 12, dataOff = -1, len = 0;
  while (off + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(off, off + 4));
    final l = bd.getUint32(off + 4, Endian.little);
    if (id == 'data') {
      dataOff = off + 8;
      len = l;
      break;
    }
    off += 8 + l + (l & 1);
  }
  final n = len ~/ 2;
  final x = Float64List(n);
  for (var i = 0; i < n; i++) {
    x[i] = bd.getInt16(dataOff + 2 * i, Endian.little) / 32768.0;
  }
  final vc = VoiceCleanup(handsFree: true, agc: agc, gate: gate, spectralSuppression: spectral, windSuppression: spectral);
  final out = Float64List(n);
  final sw = Stopwatch()..start();
  for (var i = 0; i + 320 <= n; i += 320) {
    final y = vc.process(Float64List.sublistView(x, i, i + 320));
    out.setRange(i, i + 320, y);
  }
  sw.stop();
  final o = BytesBuilder();
  final h = ByteData(44);
  void s4(int p, String t) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(p + i, t.codeUnitAt(i));
    }
  }
  s4(0, 'RIFF');
  h.setUint32(4, 36 + n * 2, Endian.little);
  s4(8, 'WAVE');
  s4(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, 1, Endian.little);
  h.setUint32(24, 16000, Endian.little);
  h.setUint32(28, 32000, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  s4(36, 'data');
  h.setUint32(40, n * 2, Endian.little);
  o.add(h.buffer.asUint8List());
  final pcm = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    pcm.setInt16(2 * i, (out[i] * 32768).round().clamp(-32768, 32767), Endian.little);
  }
  o.add(pcm.buffer.asUint8List());
  File(a[4]).writeAsBytesSync(o.takeBytes());
  stdout.writeln('{"latency16k":192,"usPer10ms":${(sw.elapsedMicroseconds / (n / 160)).toStringAsFixed(1)}}');
}
