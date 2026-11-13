// Round 8: codec negotiation and the Opus frame payload (pure Dart; tool/pure_dart_test/run.sh).
import 'dart:typed_data';

import 'package:coroute_app/domain/audio/voice_clarity.dart';
import 'package:coroute_app/domain/audio/voice_codec_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('negotiation', () {
    test('a phone announces opus1 only with the Opus decoder', () {
      expect(VoiceCodecs.receivable(opusDecoder: true), ['opus1', 'pcm16']);
      expect(VoiceCodecs.receivable(opusDecoder: false), ['pcm16']);
    });

    test('Opus is sent only when the group allows it AND this phone can encode', () {
      expect(VoiceCodecs.sendCodec(groupCodec: 'opus1', opusEncoder: true), 'opus1');
      expect(VoiceCodecs.sendCodec(groupCodec: 'opus1', opusEncoder: false), 'pcm16', reason: 'Android 5-9: decoder only');
      expect(VoiceCodecs.sendCodec(groupCodec: 'pcm16', opusEncoder: true), 'pcm16', reason: 'an old build is in the group');
      expect(VoiceCodecs.sendCodec(groupCodec: null, opusEncoder: true), 'pcm16', reason: 'old gateway: never asked');
    });

    test('bitrate: 24 kbit/s, 16 kbit/s in data saver', () {
      expect(VoiceCodecs.opusBitrate(lowData: false), 24000);
      expect(VoiceCodecs.opusBitrate(lowData: true), 16000);
    });
  });

  group('Opus payload', () {
    test('pack / unpack round trip, two 20 ms packets per frame', () {
      final a = Uint8List.fromList(List.generate(57, (i) => i));
      final b = Uint8List.fromList(List.generate(301, (i) => 255 - (i & 0xff)));
      final p = VoiceCodecs.packOpus([a, b]);
      expect(p.length, 2 + 57 + 2 + 301);
      final u = VoiceCodecs.unpackOpus(p);
      expect(u.length, 2);
      expect(u[0], a);
      expect(u[1], b);
    });

    test('a truncated or garbage tail is ignored, never throws', () {
      final p = VoiceCodecs.packOpus([Uint8List.fromList([1, 2, 3])]);
      expect(VoiceCodecs.unpackOpus(Uint8List.fromList([...p, 0, 9, 1])).length, 1);
      expect(VoiceCodecs.unpackOpus(Uint8List(0)), isEmpty);
      expect(VoiceCodecs.unpackOpus(Uint8List.fromList([0, 0, 5])), isEmpty);
    });
  });

  group('noise reduction setting and chain plan', () {
    test('stored values; unknown = Strong (default)', () {
      expect(NoiseReduction.parse(null), NoiseReduction.strong);
      expect(NoiseReduction.parse('bogus'), NoiseReduction.strong);
      for (final m in NoiseReduction.values) {
        expect(NoiseReduction.parse(m.storage), m);
      }
      expect(NoiseReduction.values.map((m) => m.label).toList(), ['Strong', 'Normal', 'Off']);
    });

    test('Strong with the native library: RNNoise strong, Dart post-stage without Wiener and wind class', () {
      final p = VoiceChainPlan.forChoice(NoiseReduction.strong, windNoiseMode: true, adminOn: true, nativeAvailable: true);
      expect(p.nativeMode, NativeCleanupMode.strong);
      expect(p.nativeWindDuck, isTrue);
      expect(p.dartSuppressNoise, isTrue);
      expect(p.dartSpectral, isFalse);
      expect(p.dartWind, isFalse);
      expect(p.latencySamples, 392);
    });

    test('Normal maps to the capped native mode; Wind-noise mode off turns the ducker off', () {
      final p = VoiceChainPlan.forChoice(NoiseReduction.normal, windNoiseMode: false, adminOn: true, nativeAvailable: true);
      expect(p.nativeMode, NativeCleanupMode.normal);
      expect(p.nativeWindDuck, isFalse);
    });

    test('no native library: the 3.55 pure-Dart chain (Wiener on), wind class follows Wind-noise mode', () {
      final p = VoiceChainPlan.forChoice(NoiseReduction.strong, windNoiseMode: true, adminOn: true, nativeAvailable: false);
      expect(p.nativeMode, isNull);
      expect(p.dartSpectral, isTrue);
      expect(p.dartWind, isTrue);
      expect(p.latencySamples, 192);
      expect(VoiceChainPlan.forChoice(NoiseReduction.strong, windNoiseMode: false, adminOn: true, nativeAvailable: false).dartWind, isFalse);
    });

    test('Off, or the admin switch off: no noise processing at all (gate / AGC / limiter only)', () {
      const none = VoiceChainPlan(nativeMode: null, nativeWindDuck: false, dartSuppressNoise: false, dartSpectral: false, dartWind: false);
      expect(VoiceChainPlan.forChoice(NoiseReduction.off, windNoiseMode: true, adminOn: true, nativeAvailable: true), none);
      expect(VoiceChainPlan.forChoice(NoiseReduction.strong, windNoiseMode: true, adminOn: false, nativeAvailable: true), none);
    });
  });
}
