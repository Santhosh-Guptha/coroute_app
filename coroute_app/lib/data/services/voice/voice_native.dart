// Round 8: picks the dart:ffi binding of libcoroute_voice where dart:ffi exists, else the stub.
export 'voice_native_api.dart';
export 'voice_native_stub.dart' if (dart.library.ffi) 'voice_native_ffi.dart';
