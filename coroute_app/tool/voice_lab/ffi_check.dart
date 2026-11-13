// Round 8 voice lab: checks the app's dart:ffi binding (lib/data/services/voice/voice_native_ffi.dart)
// against a host build of libcoroute_voice (same C sources as the APK). Run by run_lab.sh:
//   dart run --packages=<app>/.dart_tool/package_config.json ffi_check.dart <libcoroute_voice.so> <in.wav> <cv_cli out.wav>
// Passes when the FFI output is sample-identical to the C harness output and the API answers sensibly.
import 'dart:io';
import 'dart:typed_data';

import 'package:coroute_app/data/services/voice/voice_native_ffi.dart';

Int16List readWav(String p) {
  final b = File(p).readAsBytesSync();
  final bd = ByteData.sublistView(b);
  var off = 12;
  while (off + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(off, off + 4));
    final l = bd.getUint32(off + 4, Endian.little);
    if (id == 'data') {
      final out = Int16List(l ~/ 2);
      for (var i = 0; i < out.length; i++) {
        out[i] = bd.getInt16(off + 8 + 2 * i, Endian.little);
      }
      return out;
    }
    off += 8 + l + (l & 1);
  }
  throw 'no data chunk in $p';
}

void main(List<String> a) {
  final d = createNativeVoiceDenoiser(libraryPath: a[0]);
  if (d == null) {
    stderr.writeln('FFI: library did not load');
    exit(1);
  }
  d.configure(mode: 2, windDuck: true);
  final x = readWav(a[1]);
  final ref = readWav(a[2]);
  var diff = 0, vadMax = 0.0;
  final sw = Stopwatch()..start();
  for (var i = 0; i + 320 <= x.length && i + 320 <= ref.length; i += 320) {
    final y = d.process(Int16List.sublistView(x, i, i + 320));
    if (d.lastVad > vadMax) vadMax = d.lastVad;
    for (var k = 0; k < 320; k++) {
      if (y[k] != ref[i + k]) diff++;
    }
  }
  sw.stop();
  final bad = d.process(Int16List(100)); // not a multiple of 160: passed through untouched
  d.dispose();
  d.dispose(); // idempotent
  final ok = diff == 0 && vadMax > 0.5 && bad.length == 100;
  stdout.writeln('{"ffiIdenticalToC":${diff == 0},"diffSamples":$diff,"maxVad":${vadMax.toStringAsFixed(2)},"usPer20msViaFfi":${(sw.elapsedMicroseconds / (x.length / 320)).toStringAsFixed(1)}}');
  exit(ok ? 0 : 1);
}
