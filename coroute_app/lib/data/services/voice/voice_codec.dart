// Round 8 intercom Opus codec (docs/features_355/voice_clarity.md): Dart side of the "coroute/voice_codec"
// channel (android/.../VoiceCodecChannel.kt, MediaCodec). Encoder Android 10+, decoder Android 5+.
// Every failure turns into "no Opus": the intercom then sends / plays PCM16 exactly as 3.55.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../domain/audio/voice_codec_policy.dart';

class OpusCaps {
  final bool encoder;
  final bool decoder;
  const OpusCaps({required this.encoder, required this.decoder});
  static const OpusCaps none = OpusCaps(encoder: false, decoder: false);
}

/// The platform codec. Tests replace [instance] with a fake.
class VoiceCodecPlatform {
  VoiceCodecPlatform();

  static VoiceCodecPlatform instance = VoiceCodecPlatform();
  static const MethodChannel _ch = MethodChannel('coroute/voice_codec');

  Future<OpusCaps>? _caps;

  /// Cached for the app's life (the codec list does not change).
  Future<OpusCaps> caps() => _caps ??= _loadCaps();

  Future<OpusCaps> _loadCaps() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return OpusCaps.none;
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('caps');
      return OpusCaps(encoder: m?['encoder'] == true, decoder: m?['decoder'] == true);
    } catch (_) {
      return OpusCaps.none;
    }
  }

  Future<int?> openEncoder({required int sampleRate, required int bitrate}) async {
    try {
      return await _ch.invokeMethod<int>('encOpen', {'sampleRate': sampleRate, 'bitrate': bitrate});
    } catch (_) {
      return null;
    }
  }

  Future<List<Uint8List>> encode(int id, Uint8List pcm) async {
    try {
      final r = await _ch.invokeListMethod<Uint8List>('encode', {'id': id, 'pcm': pcm});
      return r ?? const [];
    } catch (_) {
      return const [];
    }
  }

  Future<void> closeEncoder(int id) async {
    try {
      await _ch.invokeMethod<void>('encClose', {'id': id});
    } catch (_) {}
  }

  Future<int?> openDecoder({required int sampleRate}) async {
    try {
      return await _ch.invokeMethod<int>('decOpen', {'sampleRate': sampleRate});
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> decode(int id, List<Uint8List> packets) async {
    try {
      return await _ch.invokeMethod<Uint8List>('decode', {'id': id, 'packets': packets});
    } catch (_) {
      return null;
    }
  }

  Future<void> resetDecoder(int id) async {
    try {
      await _ch.invokeMethod<void>('decReset', {'id': id});
    } catch (_) {}
  }

  Future<void> closeDecoder(int id) async {
    try {
      await _ch.invokeMethod<void>('decClose', {'id': id});
    } catch (_) {}
  }
}

/// Runs voice sends strictly in order: synchronous work runs at once while nothing is pending; while an Opus
/// encode is in flight, later sends (frames, END, the next START) wait behind it, so the relay never sees an
/// END before the last frame or a new START before the old END.
class SerialVoiceSender {
  Future<void> _tail = Future.value();
  int _pending = 0;

  bool get idle => _pending == 0;

  void run(void Function() action) {
    if (_pending == 0) {
      action();
      return;
    }
    runAsync(() async => action());
  }

  void runAsync(Future<void> Function() action) {
    _pending++;
    _tail = _tail.then((_) => action()).catchError((Object _) {}).whenComplete(() => _pending--);
  }

  Future<void> get drained => _tail;
}

/// One talk session's Opus encoder: 20 ms PCM16 frames (16 kHz) in, packed frames of
/// [VoiceCodecs.opusPacketsPerFrame] packets out through [onFrame] (in order, on [sender]).
class OpusTx {
  OpusTx({required this.sender, required this.onFrame, required int bitrate, VoiceCodecPlatform? platform})
      : _platform = platform ?? VoiceCodecPlatform.instance {
    _id = _platform.openEncoder(sampleRate: 16000, bitrate: bitrate);
  }

  final SerialVoiceSender sender;
  final void Function(Uint8List payload) onFrame;
  final VoiceCodecPlatform _platform;
  late final Future<int?> _id;
  final List<Uint8List> _packets = [];
  final BytesBuilder _pcm = BytesBuilder(copy: true);
  int _emptyRuns = 0;
  bool failed = false;
  bool _closed = false;

  /// Called when the encoder failed (did not open, or produced nothing for 10 frames): use PCM.
  VoidCallback? onFailure;

  static const int _frameBytes = 640; // 20 ms at 16 kHz

  /// Adds PCM16 bytes (any length; cut into 20 ms frames here).
  void add(Uint8List pcm16) {
    if (failed || _closed) return;
    _pcm.add(pcm16);
    while (_pcm.length >= _frameBytes) {
      final all = _pcm.takeBytes();
      final frame = Uint8List.sublistView(all, 0, _frameBytes);
      if (all.length > _frameBytes) _pcm.add(Uint8List.sublistView(all, _frameBytes));
      final copy = Uint8List.fromList(frame);
      sender.runAsync(() => _encode(copy));
    }
  }

  Future<void> _encode(Uint8List frame) async {
    if (failed || _closed) return;
    final id = await _id;
    if (id == null) {
      _fail();
      return;
    }
    final out = await _platform.encode(id, frame);
    if (out.isEmpty) {
      if (++_emptyRuns >= 10) _fail();
      return;
    }
    _emptyRuns = 0;
    _packets.addAll(out);
    while (_packets.length >= VoiceCodecs.opusPacketsPerFrame) {
      final p = _packets.sublist(0, VoiceCodecs.opusPacketsPerFrame);
      _packets.removeRange(0, VoiceCodecs.opusPacketsPerFrame);
      onFrame(VoiceCodecs.packOpus(p));
    }
  }

  void _fail() {
    if (failed) return;
    failed = true;
    onFailure?.call();
  }

  /// Sends what is left (a last single packet) and closes the encoder; [then] runs after it, in order.
  void finish(void Function() then) {
    sender.runAsync(() async {
      if (!failed && _packets.isNotEmpty) {
        onFrame(VoiceCodecs.packOpus(List.of(_packets)));
        _packets.clear();
      }
      _closed = true;
      then();
      final id = await _id;
      if (id != null) await _platform.closeEncoder(id);
    });
  }

  /// Drops everything (the stream was refused or switched to PCM).
  void abandon() {
    _closed = true;
    _packets.clear();
    _pcm.clear();
    _id.then((id) {
      if (id != null) _platform.closeEncoder(id);
    }).ignore();
  }
}

/// Receive side: one platform decoder, reset for every new stream, calls in arrival order.
class OpusRx {
  OpusRx({VoiceCodecPlatform? platform}) : _platform = platform ?? VoiceCodecPlatform.instance;

  final VoiceCodecPlatform _platform;
  Future<int?>? _id;
  Future<void> _tail = Future.value();
  String? _stream;

  /// Decodes one frame payload of [streamId]; [onPcm] gets 16 kHz PCM16 (or nothing on failure), in order.
  void decode(String streamId, Uint8List payload, void Function(Int16List pcm) onPcm) {
    final packets = VoiceCodecs.unpackOpus(payload);
    if (packets.isEmpty) return;
    final id = _id ??= _platform.openDecoder(sampleRate: 16000);
    final newStream = _stream != streamId;
    _stream = streamId;
    _tail = _tail.then((_) async {
      final h = await id;
      if (h == null) return;
      if (newStream) await _platform.resetDecoder(h);
      final pcm = await _platform.decode(h, packets);
      if (pcm == null || pcm.length < 2) return;
      final even = pcm.length & ~1;
      final aligned = Uint8List.fromList(Uint8List.sublistView(pcm, 0, even));
      onPcm(Int16List.view(aligned.buffer, 0, even ~/ 2));
    }).catchError((Object _) {});
  }

  void dispose() {
    final id = _id;
    _id = null;
    id?.then((h) {
      if (h != null) _platform.closeDecoder(h);
    }).ignore();
  }
}
