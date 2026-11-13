import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/mesh/crypto/aes_gcm.dart';

// Round 10 offline link: pure-Dart AES / AES-GCM against FIPS-197 and the NIST GCM test vectors
// (pure Dart: tool/pure_dart_test/run.sh test/mesh_crypto_test.dart).
Uint8List hx(String s) {
  final c = s.replaceAll(' ', '');
  return Uint8List.fromList([for (var i = 0; i < c.length; i += 2) int.parse(c.substring(i, i + 2), radix: 16)]);
}

String toHex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('FIPS-197 C.1 / C.3: AES-128 and AES-256 known answers', () {
    final pt = hx('00112233445566778899aabbccddeeff');
    expect(toHex(AesBlockCipher(hx('000102030405060708090a0b0c0d0e0f')).encrypt16(pt)), '69c4e0d86a7b0430d8cdb78070b4c55a');
    expect(toHex(AesBlockCipher(hx('000102030405060708090a0b0c0d0e0f1011121314151617')).encrypt16(pt)), 'dda97ca4864cdfe06eaf70a0ec0d7191');
    expect(toHex(AesBlockCipher(hx('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f')).encrypt16(pt)),
        '8ea2b7ca516745bfeafc49904b496089');
  });

  test('GCM test case 2 (AES-128, zero key, one zero block)', () {
    final g = AesGcm(Uint8List(16));
    final out = g.encrypt(Uint8List(12), Uint8List(16));
    expect(toHex(Uint8List.sublistView(out, 0, 16)), '0388dace60b6a392f328c2b971b2fe78');
    expect(toHex(Uint8List.sublistView(out, 16)), 'ab6e47d42cec13bdf53a67b21257bddf');
  });

  test('GCM test case 16 (AES-256 with AAD, 60-byte plaintext)', () {
    final key = hx('feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308');
    final iv = hx('cafebabefacedbaddecaf888');
    final pt = hx('d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39');
    final aad = hx('feedfacedeadbeeffeedfacedeadbeefabaddad2');
    final g = AesGcm(key);
    final out = g.encrypt(iv, pt, aad: aad);
    expect(toHex(Uint8List.sublistView(out, 0, pt.length)),
        '522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662');
    expect(toHex(Uint8List.sublistView(out, pt.length)), '76fc6ece0f4e1768cddf8853bb2d551b');
    expect(g.decrypt(iv, out, aad: aad), pt);
  });

  test('GCM test case 14 (AES-256, zero key, one zero block)', () {
    final out = AesGcm(Uint8List(32)).encrypt(Uint8List(12), Uint8List(16));
    expect(toHex(out), 'cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919');
  });

  test('tampering anywhere (ciphertext, tag, AAD, nonce, key) fails authentication', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final g = AesGcm(key);
    final nonce = Uint8List.fromList(List.generate(12, (i) => 100 + i));
    final aad = Uint8List.fromList([1, 2, 3]);
    final pt = Uint8List.fromList(List.generate(37, (i) => i * 7));
    final sealed = g.encrypt(nonce, pt, aad: aad);
    expect(g.decrypt(nonce, sealed, aad: aad), pt);
    for (final i in [0, 20, 36, 37, 52]) {
      final bad = Uint8List.fromList(sealed)..[i] ^= 1;
      expect(g.decrypt(nonce, bad, aad: aad), isNull, reason: 'byte $i');
    }
    expect(g.decrypt(nonce, sealed, aad: Uint8List.fromList([1, 2, 4])), isNull);
    expect(g.decrypt(Uint8List.fromList(List.generate(12, (i) => 101 + i)), sealed, aad: aad), isNull);
    expect(AesGcm(Uint8List(32)).decrypt(nonce, sealed, aad: aad), isNull);
    expect(g.decrypt(nonce, Uint8List.sublistView(sealed, 0, 10), aad: aad), isNull);
  });
}
