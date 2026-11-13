// Round 10 offline link: AES (FIPS-197) and AES-GCM (NIST SP 800-38D) in pure Dart.
//
// Why pure Dart: the app has no crypto package (pubspec has neither `cryptography` nor `pointycastle`, and pub cannot be
// fetched for this build). The mesh needs authenticated encryption with the per-ride group key the gateway hands out
// (MESH_KEY), and the gateway checks bridged frames with Node's own aes-256-gcm, so both sides must be bit-exact.
// Verified against the NIST GCM test vectors in test/mesh_crypto_test.dart.
//
// Only 32-bit integer arithmetic is used (safe on every Dart platform). Throughput on a desktop JIT is a few MB/s,
// far more than the link carries (voice at 12 kbit/s is 1.5 KB/s).
library;

import 'dart:typed_data';

/// AES block cipher, encryption direction only (GCM never needs the inverse cipher). 128, 192 or 256-bit keys.
class AesBlockCipher {
  AesBlockCipher(Uint8List key) : _rounds = _roundsFor(key.length) {
    _w = _expand(key, _rounds);
  }

  final int _rounds;
  late final Uint32List _w;

  static int _roundsFor(int len) => switch (len) {
        16 => 10,
        24 => 12,
        32 => 14,
        _ => throw ArgumentError('AES key must be 16, 24 or 32 bytes (got $len)'),
      };

  static final Uint8List _sbox = _buildSbox();

  static Uint8List _buildSbox() {
    final s = Uint8List(256);
    var p = 1, q = 1;
    // Multiplicative inverse via generator 3, then the affine transform (FIPS-197 5.1.1).
    do {
      p = p ^ ((p << 1) & 0xff) ^ (((p & 0x80) != 0) ? 0x1b : 0);
      q ^= (q << 1) & 0xff;
      q ^= (q << 2) & 0xff;
      q ^= (q << 4) & 0xff;
      if ((q & 0x80) != 0) q ^= 0x09;
      final x = q ^ _rotl8(q, 1) ^ _rotl8(q, 2) ^ _rotl8(q, 3) ^ _rotl8(q, 4);
      s[p] = (x ^ 0x63) & 0xff;
    } while (p != 1);
    s[0] = 0x63;
    return s;
  }

  static int _rotl8(int x, int n) => ((x << n) | (x >> (8 - n))) & 0xff;

  static int _subWord(int w) =>
      (_sbox[(w >>> 24) & 0xff] << 24) | (_sbox[(w >>> 16) & 0xff] << 16) | (_sbox[(w >>> 8) & 0xff] << 8) | _sbox[w & 0xff];

  static Uint32List _expand(Uint8List key, int rounds) {
    final nk = key.length ~/ 4;
    final total = 4 * (rounds + 1);
    final w = Uint32List(total);
    for (var i = 0; i < nk; i++) {
      w[i] = (key[4 * i] << 24) | (key[4 * i + 1] << 16) | (key[4 * i + 2] << 8) | key[4 * i + 3];
    }
    var rcon = 1;
    for (var i = nk; i < total; i++) {
      var t = w[i - 1];
      if (i % nk == 0) {
        t = _subWord(((t << 8) | (t >>> 24)) & 0xffffffff) ^ (rcon << 24);
        rcon = ((rcon << 1) ^ (((rcon & 0x80) != 0) ? 0x1b : 0)) & 0xff;
      } else if (nk > 6 && i % nk == 4) {
        t = _subWord(t);
      }
      w[i] = (w[i - nk] ^ t) & 0xffffffff;
    }
    return w;
  }

  static int _xtime(int b) => ((b << 1) ^ (((b & 0x80) != 0) ? 0x1b : 0)) & 0xff;

  /// Encrypts one 16-byte block from [input] at [inOff] into [out] at [outOff].
  void encryptBlock(Uint8List input, int inOff, Uint8List out, int outOff) {
    final s = Uint8List(16);
    for (var c = 0; c < 4; c++) {
      final k = _w[c];
      s[4 * c] = input[inOff + 4 * c] ^ ((k >>> 24) & 0xff);
      s[4 * c + 1] = input[inOff + 4 * c + 1] ^ ((k >>> 16) & 0xff);
      s[4 * c + 2] = input[inOff + 4 * c + 2] ^ ((k >>> 8) & 0xff);
      s[4 * c + 3] = input[inOff + 4 * c + 3] ^ (k & 0xff);
    }
    final t = Uint8List(16);
    for (var round = 1; round <= _rounds; round++) {
      // SubBytes + ShiftRows (state is column-major: s[4*c + r]).
      for (var c = 0; c < 4; c++) {
        for (var r = 0; r < 4; r++) {
          t[4 * c + r] = _sbox[s[4 * ((c + r) % 4) + r]];
        }
      }
      if (round != _rounds) {
        // MixColumns.
        for (var c = 0; c < 4; c++) {
          final a0 = t[4 * c], a1 = t[4 * c + 1], a2 = t[4 * c + 2], a3 = t[4 * c + 3];
          final all = a0 ^ a1 ^ a2 ^ a3;
          s[4 * c] = a0 ^ all ^ _xtime(a0 ^ a1);
          s[4 * c + 1] = a1 ^ all ^ _xtime(a1 ^ a2);
          s[4 * c + 2] = a2 ^ all ^ _xtime(a2 ^ a3);
          s[4 * c + 3] = a3 ^ all ^ _xtime(a3 ^ a0);
        }
      } else {
        s.setAll(0, t);
      }
      for (var c = 0; c < 4; c++) {
        final k = _w[4 * round + c];
        s[4 * c] ^= (k >>> 24) & 0xff;
        s[4 * c + 1] ^= (k >>> 16) & 0xff;
        s[4 * c + 2] ^= (k >>> 8) & 0xff;
        s[4 * c + 3] ^= k & 0xff;
      }
    }
    out.setRange(outOff, outOff + 16, s);
  }

  Uint8List encrypt16(Uint8List block) {
    final out = Uint8List(16);
    encryptBlock(block, 0, out, 0);
    return out;
  }
}

/// AES-GCM with a 96-bit nonce and a 128-bit tag (the only parameters the mesh uses).
class AesGcm {
  AesGcm(Uint8List key) : _aes = AesBlockCipher(key) {
    final h = _aes.encrypt16(Uint8List(16));
    _h0 = _be32(h, 0);
    _h1 = _be32(h, 4);
    _h2 = _be32(h, 8);
    _h3 = _be32(h, 12);
  }

  static const int nonceLength = 12;
  static const int tagLength = 16;

  final AesBlockCipher _aes;
  late final int _h0, _h1, _h2, _h3;

  AesBlockCipher get blockCipher => _aes;

  static int _be32(Uint8List b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  /// ciphertext || tag.
  Uint8List encrypt(Uint8List nonce, Uint8List plaintext, {Uint8List? aad}) {
    _checkNonce(nonce);
    final out = Uint8List(plaintext.length + tagLength);
    _ctr(nonce, plaintext, out);
    final tag = _tag(nonce, aad ?? Uint8List(0), Uint8List.sublistView(out, 0, plaintext.length));
    out.setRange(plaintext.length, out.length, tag);
    return out;
  }

  /// The plaintext, or null when the tag does not match (wrong key, tampered or truncated).
  Uint8List? decrypt(Uint8List nonce, Uint8List sealed, {Uint8List? aad}) {
    _checkNonce(nonce);
    if (sealed.length < tagLength) return null;
    final ctLen = sealed.length - tagLength;
    final ct = Uint8List.sublistView(sealed, 0, ctLen);
    final want = _tag(nonce, aad ?? Uint8List(0), ct);
    var diff = 0;
    for (var i = 0; i < tagLength; i++) {
      diff |= want[i] ^ sealed[ctLen + i];
    }
    if (diff != 0) return null;
    final out = Uint8List(ctLen);
    _ctr(nonce, ct, out);
    return out;
  }

  void _checkNonce(Uint8List nonce) {
    if (nonce.length != nonceLength) throw ArgumentError('GCM nonce must be 12 bytes');
  }

  void _ctr(Uint8List nonce, Uint8List input, Uint8List out) {
    final counter = Uint8List(16)..setRange(0, 12, nonce);
    var ctr = 2; // J0 = nonce || 1 is reserved for the tag
    final ks = Uint8List(16);
    for (var off = 0; off < input.length; off += 16) {
      counter[12] = (ctr >>> 24) & 0xff;
      counter[13] = (ctr >>> 16) & 0xff;
      counter[14] = (ctr >>> 8) & 0xff;
      counter[15] = ctr & 0xff;
      _aes.encryptBlock(counter, 0, ks, 0);
      final n = (input.length - off) < 16 ? input.length - off : 16;
      for (var i = 0; i < n; i++) {
        out[off + i] = input[off + i] ^ ks[i];
      }
      ctr = (ctr + 1) & 0xffffffff;
    }
  }

  Uint8List _tag(Uint8List nonce, Uint8List aad, Uint8List ct) {
    final g = _Ghash(_h0, _h1, _h2, _h3);
    g.update(aad);
    g.update(ct);
    g.lengths(aad.length, ct.length);
    final j0 = Uint8List(16)
      ..setRange(0, 12, nonce)
      ..[15] = 1;
    final ek = _aes.encrypt16(j0);
    final s = g.digest();
    for (var i = 0; i < 16; i++) {
      ek[i] ^= s[i];
    }
    return ek;
  }
}

/// GHASH over GF(2^128), bitwise (SP 800-38D algorithm 1), 4 x 32-bit words, most significant first.
class _Ghash {
  _Ghash(this.h0, this.h1, this.h2, this.h3);
  final int h0, h1, h2, h3;
  int y0 = 0, y1 = 0, y2 = 0, y3 = 0;

  void update(Uint8List data) {
    for (var off = 0; off < data.length; off += 16) {
      final blk = Uint8List(16);
      final n = (data.length - off) < 16 ? data.length - off : 16;
      blk.setRange(0, n, data, off);
      _absorb(AesGcm._be32(blk, 0), AesGcm._be32(blk, 4), AesGcm._be32(blk, 8), AesGcm._be32(blk, 12));
    }
  }

  void lengths(int aadBytes, int ctBytes) {
    final a = aadBytes * 8, c = ctBytes * 8;
    // Lengths below 2^32 bits are all the mesh ever carries.
    _absorb(0, a & 0xffffffff, 0, c & 0xffffffff);
  }

  void _absorb(int x0, int x1, int x2, int x3) {
    x0 ^= y0;
    x1 ^= y1;
    x2 ^= y2;
    x3 ^= y3;
    var z0 = 0, z1 = 0, z2 = 0, z3 = 0;
    var v0 = h0, v1 = h1, v2 = h2, v3 = h3;
    for (var i = 0; i < 128; i++) {
      final word = i < 32 ? x0 : (i < 64 ? x1 : (i < 96 ? x2 : x3));
      if (((word >>> (31 - (i & 31))) & 1) != 0) {
        z0 ^= v0;
        z1 ^= v1;
        z2 ^= v2;
        z3 ^= v3;
      }
      final lsb = v3 & 1;
      v3 = ((v3 >>> 1) | ((v2 & 1) << 31)) & 0xffffffff;
      v2 = ((v2 >>> 1) | ((v1 & 1) << 31)) & 0xffffffff;
      v1 = ((v1 >>> 1) | ((v0 & 1) << 31)) & 0xffffffff;
      v0 = (v0 >>> 1) & 0xffffffff;
      if (lsb != 0) v0 ^= 0xe1000000;
    }
    y0 = z0;
    y1 = z1;
    y2 = z2;
    y3 = z3;
  }

  Uint8List digest() {
    final out = Uint8List(16);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, y0);
    bd.setUint32(4, y1);
    bd.setUint32(8, y2);
    bd.setUint32(12, y3);
    return out;
  }
}
