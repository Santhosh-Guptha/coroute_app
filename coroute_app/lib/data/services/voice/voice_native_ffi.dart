// Round 8: dart:ffi binding of libcoroute_voice.so (android/app/src/main/cpp/coroute_voice.{h,c}).
// Synchronous calls on the caller's isolate: one 20 ms frame costs about 0.35 ms on a desktop core
// (tool/voice_lab), no platform-channel hop and no copy beyond the 640-byte in/out buffer.
// Any failure (library not packaged for this ABI, symbol missing, ABI version mismatch) returns null and the
// intercom falls back to the 3.55 pure-Dart chain.
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'voice_native_api.dart';

final class _CvState extends Opaque {}

typedef _CreateN = Pointer<_CvState> Function();
typedef _StN = Void Function(Pointer<_CvState>);
typedef _StD = void Function(Pointer<_CvState>);
typedef _StIntN = Void Function(Pointer<_CvState>, Int32);
typedef _StIntD = void Function(Pointer<_CvState>, int);
typedef _IoN = Pointer<Int16> Function(Pointer<_CvState>);
typedef _ProcN = Int32 Function(Pointer<_CvState>, Int32);
typedef _ProcD = int Function(Pointer<_CvState>, int);
typedef _FloatN = Float Function(Pointer<_CvState>);
typedef _FloatD = double Function(Pointer<_CvState>);
typedef _IntN = Int32 Function();
typedef _IntD = int Function();

/// ABI version this binding was written for (CV_VERSION in coroute_voice.c).
const int _abiVersion = 1;
const int _maxBlock = 960;

class _CvLib {
  _CvLib(DynamicLibrary l)
      : create = l.lookupFunction<_CreateN, _CreateN>('cv_create'),
        destroy = l.lookupFunction<_StN, _StD>('cv_destroy'),
        reset = l.lookupFunction<_StN, _StD>('cv_reset'),
        setMode = l.lookupFunction<_StIntN, _StIntD>('cv_set_mode'),
        setWindDuck = l.lookupFunction<_StIntN, _StIntD>('cv_set_wind_duck'),
        io = l.lookupFunction<_IoN, _IoN>('cv_io'),
        process = l.lookupFunction<_ProcN, _ProcD>('cv_process'),
        lastVad = l.lookupFunction<_FloatN, _FloatD>('cv_last_vad'),
        windGainDb = l.lookupFunction<_FloatN, _FloatD>('cv_wind_gain_db'),
        version = l.lookupFunction<_IntN, _IntD>('cv_version');

  final Pointer<_CvState> Function() create;
  final void Function(Pointer<_CvState>) destroy, reset;
  final void Function(Pointer<_CvState>, int) setMode, setWindDuck;
  final Pointer<Int16> Function(Pointer<_CvState>) io;
  final int Function(Pointer<_CvState>, int) process;
  final double Function(Pointer<_CvState>) lastVad, windGainDb;
  final int Function() version;

  static _CvLib? _instance;
  static bool _tried = false;

  static _CvLib? load(String path) {
    if (_tried) return _instance;
    _tried = true;
    try {
      final lib = _CvLib(DynamicLibrary.open(path));
      if (lib.version() != _abiVersion) return null;
      _instance = lib;
    } catch (_) {
      _instance = null;
    }
    return _instance;
  }
}

class _FfiVoiceDenoiser implements VoiceDenoiser {
  _FfiVoiceDenoiser(this._lib, this._st) : _buf = _lib.io(_st).asTypedList(_maxBlock);

  final _CvLib _lib;
  Pointer<_CvState> _st;
  final Int16List _buf;

  @override
  void configure({required int mode, required bool windDuck}) {
    if (_st == nullptr) return;
    _lib.setMode(_st, mode);
    _lib.setWindDuck(_st, windDuck ? 1 : 0);
  }

  @override
  Int16List process(Int16List block) {
    final n = block.length;
    if (_st == nullptr || n == 0 || n > _maxBlock || n % 160 != 0) return Int16List.fromList(block);
    _buf.setRange(0, n, block);
    if (_lib.process(_st, n) != n) return Int16List.fromList(block);
    return Int16List.fromList(Int16List.sublistView(_buf, 0, n));
  }

  @override
  double get lastVad => _st == nullptr ? 0 : _lib.lastVad(_st);

  @override
  double get windGainDb => _st == nullptr ? 0 : _lib.windGainDb(_st);

  @override
  void reset() {
    if (_st != nullptr) _lib.reset(_st);
  }

  @override
  void dispose() {
    if (_st == nullptr) return;
    _lib.destroy(_st);
    _st = nullptr;
  }
}

/// The native stage, or null (not Android, library missing, ABI mismatch, out of memory).
/// [libraryPath] is for the host check in tool/voice_lab (a host build of the same C sources).
VoiceDenoiser? createNativeVoiceDenoiser({String? libraryPath}) {
  if (libraryPath == null) {
    try {
      if (!Platform.isAndroid) return null;
    } catch (_) {
      return null;
    }
  }
  final lib = _CvLib.load(libraryPath ?? 'libcoroute_voice.so');
  if (lib == null) return null;
  try {
    final st = lib.create();
    if (st == nullptr) return null;
    return _FfiVoiceDenoiser(lib, st);
  } catch (_) {
    return null;
  }
}
