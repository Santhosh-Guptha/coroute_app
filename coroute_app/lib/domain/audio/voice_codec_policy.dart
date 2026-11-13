// Round 8 intercom codec negotiation (docs/features_355/voice_clarity.md, gateway/src/voice_relay.js).
// Pure Dart: unit tested with tool/pure_dart_test (test/voice_codec_r8_test.dart).
//
// * The app announces what it can RECEIVE in VOICE_CAPS {codecs: [...]} after every JOIN (SNAPSHOT), to a
//   gateway whose HELLO lists 'voice2'. 'opus1' needs only the Opus DECODER (MediaCodec, Android 5+).
// * The relay answers VOICE_CODEC {codec}: 'opus1' while every rider in the group can receive Opus, else
//   'pcm16' (an old app build, or a phone without the decoder, is in the group). It sends it again on every
//   change. Simplest rule, no transcoding on the server (CPU stays off the live node).
// * The app SENDS Opus only when the group codec is 'opus1' AND it has the Opus ENCODER (Android 10+);
//   otherwise PCM16 exactly as 3.55 (16 kHz, 8 kHz in data saver).
// * Opus frame payload on the wire: one or more packets, each [length u16 big-endian][packet bytes], every
//   packet 20 ms; the frame's seq numbers frames (not packets). Two packets (40 ms) per frame by default:
//   per-message overhead (WebSocket + TLS + TCP/IP, ~70-100 bytes) is as big as one 20 ms packet at 20 kbit/s.

import 'dart:typed_data';

class VoiceCodecs {
  static const String opus = 'opus1';
  static const String pcm = 'pcm16';

  /// Server feature (HELLO.features) of a gateway with the Round 8 relay.
  static const String serverFeature = 'voice2';

  /// Opus packets per WebSocket frame.
  static const int opusPacketsPerFrame = 2;

  /// Opus packet duration.
  static const int opusPacketMs = 20;

  /// Opus encoder bitrate (VBR target): 16 kbit/s in data saver, else 24 kbit/s (wideband speech).
  static int opusBitrate({required bool lowData}) => lowData ? 16000 : 24000;

  /// Codecs this phone can receive, in preference order.
  static List<String> receivable({required bool opusDecoder}) => opusDecoder ? const [opus, pcm] : const [pcm];

  /// Codec for the next talk: Opus only when the group allows it and this phone can encode it.
  static String sendCodec({required String? groupCodec, required bool opusEncoder}) =>
      groupCodec == opus && opusEncoder ? opus : pcm;

  /// Packs Opus packets into one frame payload.
  static Uint8List packOpus(List<Uint8List> packets) {
    var n = 0;
    for (final p in packets) {
      n += 2 + p.length;
    }
    final out = Uint8List(n);
    var o = 0;
    for (final p in packets) {
      out[o] = (p.length >> 8) & 0xff;
      out[o + 1] = p.length & 0xff;
      out.setRange(o + 2, o + 2 + p.length, p);
      o += 2 + p.length;
    }
    return out;
  }

  /// Unpacks a frame payload; a truncated tail is ignored.
  static List<Uint8List> unpackOpus(Uint8List payload) {
    final out = <Uint8List>[];
    var o = 0;
    while (o + 2 <= payload.length) {
      final len = (payload[o] << 8) | payload[o + 1];
      if (len == 0 || o + 2 + len > payload.length) break;
      out.add(Uint8List.sublistView(payload, o + 2, o + 2 + len));
      o += 2 + len;
    }
    return out;
  }
}
