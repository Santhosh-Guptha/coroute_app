// 3.55 Marketing studio: a small QR code encoder (ISO/IEC 18004) in pure Dart, so the offer
// images can carry a scannable link without a new package.
//
// Scope: byte mode (UTF-8), error correction level M (15% recovery), versions 1 to 10
// (up to 213 bytes: plenty for a link), automatic mask choice by the standard penalty rules.
// Verified module-for-module against the Python `qrcode` reference encoder for several links and
// all eight masks (see test/marketing_template_355_test.dart for the fixed vectors).

import 'dart:convert';

class QrTooLongException implements Exception {
  final int bytes;
  const QrTooLongException(this.bytes);
  @override
  String toString() => 'QR data too long: $bytes bytes (at most ${QrCode.maxBytes}).';
}

/// A finished QR symbol: [size] x [size] modules, true = dark. No quiet zone included
/// (draw at least 2 light modules around it; 4 is the standard).
class QrCode {
  static const int maxBytes = 213;

  final int version;
  final int size;
  final int mask;
  final List<List<bool>> _modules;

  QrCode._(this.version, this.size, this.mask, this._modules);

  bool isDark(int x, int y) => _modules[y][x];

  /// Encodes [text] (UTF-8, byte mode, level M). [forceMask] (0-7) skips the automatic choice.
  static QrCode encode(String text, {int? forceMask, int minVersion = 1}) {
    final data = utf8.encode(text);
    int? version;
    for (var v = minVersion.clamp(1, 10); v <= 10; v++) {
      final countBits = v < 10 ? 8 : 16;
      final need = 4 + countBits + data.length * 8;
      if (need <= _dataCodewords(v) * 8) {
        version = v;
        break;
      }
    }
    if (version == null) throw QrTooLongException(data.length);
    final codewords = _addEcc(_dataBits(data, version), version);
    final b = _Builder(version);
    b.drawFunctionPatterns();
    b.drawCodewords(codewords);
    var mask = forceMask ?? -1;
    if (mask < 0) {
      var best = 1 << 30;
      for (var m = 0; m < 8; m++) {
        b.applyMask(m);
        b.drawFormatBits(m);
        final p = b.penalty();
        if (p < best) {
          best = p;
          mask = m;
        }
        b.applyMask(m); // undo (XOR)
      }
    }
    b.applyMask(mask);
    b.drawFormatBits(mask);
    return QrCode._(version, b.size, mask, b.modules);
  }

  // ---- tables (level M, versions 1..10) ----
  // [ec codewords per block, blocks in group 1, data codewords per group-1 block, blocks in group 2, data per group-2 block]
  static const List<List<int>> _blocksM = [
    [10, 1, 16, 0, 0],
    [16, 1, 28, 0, 0],
    [26, 1, 44, 0, 0],
    [18, 2, 32, 0, 0],
    [24, 2, 43, 0, 0],
    [16, 4, 27, 0, 0],
    [18, 4, 31, 0, 0],
    [22, 2, 38, 2, 39],
    [22, 3, 36, 2, 37],
    [26, 4, 43, 1, 44],
  ];

  static int _dataCodewords(int v) {
    final t = _blocksM[v - 1];
    return t[1] * t[2] + t[3] * t[4];
  }

  static List<int> _dataBits(List<int> data, int version) {
    final bits = <int>[];
    void put(int value, int n) {
      for (var i = n - 1; i >= 0; i--) {
        bits.add((value >> i) & 1);
      }
    }

    put(0x4, 4); // byte mode
    put(data.length, version < 10 ? 8 : 16);
    for (final b in data) {
      put(b, 8);
    }
    final capacity = _dataCodewords(version) * 8;
    put(0, (capacity - bits.length).clamp(0, 4)); // terminator
    while (bits.length % 8 != 0) {
      bits.add(0);
    }
    final bytes = <int>[];
    for (var i = 0; i < bits.length; i += 8) {
      var v = 0;
      for (var j = 0; j < 8; j++) {
        v = (v << 1) | bits[i + j];
      }
      bytes.add(v);
    }
    for (var pad = 0xEC; bytes.length < _dataCodewords(version); pad ^= 0xEC ^ 0x11) {
      bytes.add(pad);
    }
    return bytes;
  }

  static List<int> _addEcc(List<int> data, int version) {
    final t = _blocksM[version - 1];
    final ecLen = t[0];
    final gen = _rsGenerator(ecLen);
    final blocks = <List<int>>[];
    final eccs = <List<int>>[];
    var k = 0;
    for (var g = 0; g < 2; g++) {
      final count = t[1 + g * 2], len = t[2 + g * 2];
      for (var i = 0; i < count; i++) {
        final block = data.sublist(k, k + len);
        k += len;
        blocks.add(block);
        eccs.add(_rsRemainder(block, gen));
      }
    }
    final out = <int>[];
    final maxLen = blocks.fold<int>(0, (m, b) => b.length > m ? b.length : m);
    for (var i = 0; i < maxLen; i++) {
      for (final b in blocks) {
        if (i < b.length) out.add(b[i]);
      }
    }
    for (var i = 0; i < ecLen; i++) {
      for (final e in eccs) {
        out.add(e[i]);
      }
    }
    return out;
  }

  // ---- Reed-Solomon over GF(256), polynomial 0x11D ----
  static int _gfMul(int x, int y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) {
      z = (z << 1) ^ ((z >> 7) * 0x11D);
      z ^= ((y >> i) & 1) * x;
    }
    return z & 0xFF;
  }

  static List<int> _rsGenerator(int degree) {
    final result = List<int>.filled(degree, 0);
    result[degree - 1] = 1;
    var root = 1;
    for (var i = 0; i < degree; i++) {
      for (var j = 0; j < degree; j++) {
        result[j] = _gfMul(result[j], root);
        if (j + 1 < degree) result[j] ^= result[j + 1];
      }
      root = _gfMul(root, 0x02);
    }
    return result;
  }

  static List<int> _rsRemainder(List<int> data, List<int> gen) {
    final result = List<int>.filled(gen.length, 0, growable: true);
    for (final b in data) {
      final factor = b ^ result[0];
      result.removeAt(0);
      result.add(0);
      for (var i = 0; i < gen.length; i++) {
        result[i] ^= _gfMul(gen[i], factor);
      }
    }
    return result;
  }
}

class _Builder {
  final int version;
  final int size;
  final List<List<bool>> modules;
  final List<List<bool>> isFunction;

  _Builder(this.version)
      : size = version * 4 + 17,
        modules = List.generate(version * 4 + 17, (_) => List<bool>.filled(version * 4 + 17, false)),
        isFunction = List.generate(version * 4 + 17, (_) => List<bool>.filled(version * 4 + 17, false));

  void _set(int x, int y, bool dark) {
    modules[y][x] = dark;
    isFunction[y][x] = true;
  }

  static const List<List<int>> _alignment = [
    [],
    [6, 18],
    [6, 22],
    [6, 26],
    [6, 30],
    [6, 34],
    [6, 22, 38],
    [6, 24, 42],
    [6, 26, 46],
    [6, 28, 50],
  ];

  void drawFunctionPatterns() {
    for (var i = 0; i < size; i++) {
      _set(6, i, i % 2 == 0);
      _set(i, 6, i % 2 == 0);
    }
    _finder(3, 3);
    _finder(size - 4, 3);
    _finder(3, size - 4);
    final pos = _alignment[version - 1];
    final n = pos.length;
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        if ((i == 0 && j == 0) || (i == 0 && j == n - 1) || (i == n - 1 && j == 0)) continue;
        for (var dy = -2; dy <= 2; dy++) {
          for (var dx = -2; dx <= 2; dx++) {
            _set(pos[i] + dx, pos[j] + dy, _max(dx.abs(), dy.abs()) != 1);
          }
        }
      }
    }
    drawFormatBits(0); // reserves the format areas (redrawn after masking)
    if (version >= 7) {
      var rem = version;
      for (var i = 0; i < 12; i++) {
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
      }
      final bits = version << 12 | rem;
      for (var i = 0; i < 18; i++) {
        final bit = ((bits >> i) & 1) != 0;
        final a = size - 11 + i % 3, b = i ~/ 3;
        _set(a, b, bit);
        _set(b, a, bit);
      }
    }
  }

  void _finder(int x, int y) {
    for (var dy = -4; dy <= 4; dy++) {
      for (var dx = -4; dx <= 4; dx++) {
        final xx = x + dx, yy = y + dy;
        if (xx < 0 || xx >= size || yy < 0 || yy >= size) continue;
        final d = _max(dx.abs(), dy.abs());
        _set(xx, yy, d != 2 && d != 4);
      }
    }
  }

  void drawFormatBits(int mask) {
    final data = (0 << 3) | mask; // level M = 0b00
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    final bits = (data << 10 | rem) ^ 0x5412;
    bool bit(int i) => ((bits >> i) & 1) != 0;
    for (var i = 0; i <= 5; i++) {
      _set(8, i, bit(i));
    }
    _set(8, 7, bit(6));
    _set(8, 8, bit(7));
    _set(7, 8, bit(8));
    for (var i = 9; i < 15; i++) {
      _set(14 - i, 8, bit(i));
    }
    for (var i = 0; i < 8; i++) {
      _set(size - 1 - i, 8, bit(i));
    }
    for (var i = 8; i < 15; i++) {
      _set(8, size - 15 + i, bit(i));
    }
    _set(8, size - 8, true); // the dark module
  }

  void drawCodewords(List<int> data) {
    var i = 0;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      for (var vert = 0; vert < size; vert++) {
        for (var j = 0; j < 2; j++) {
          final x = right - j;
          final upward = ((right + 1) & 2) == 0;
          final y = upward ? size - 1 - vert : vert;
          if (!isFunction[y][x] && i < data.length * 8) {
            modules[y][x] = ((data[i >> 3] >> (7 - (i & 7))) & 1) != 0;
            i++;
          }
        }
      }
    }
  }

  void applyMask(int mask) {
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        if (isFunction[y][x]) continue;
        final bool invert;
        switch (mask) {
          case 0:
            invert = (x + y) % 2 == 0;
          case 1:
            invert = y % 2 == 0;
          case 2:
            invert = x % 3 == 0;
          case 3:
            invert = (x + y) % 3 == 0;
          case 4:
            invert = (x ~/ 3 + y ~/ 2) % 2 == 0;
          case 5:
            invert = x * y % 2 + x * y % 3 == 0;
          case 6:
            invert = (x * y % 2 + x * y % 3) % 2 == 0;
          default:
            invert = ((x + y) % 2 + x * y % 3) % 2 == 0;
        }
        if (invert) modules[y][x] = !modules[y][x];
      }
    }
  }

  /// The standard penalty score (lower is better).
  int penalty() {
    var result = 0;
    // N1: runs of 5+ in rows and columns. N3: finder-like 1:1:3:1:1 with 4 light on a side.
    for (var pass = 0; pass < 2; pass++) {
      for (var a = 0; a < size; a++) {
        var runColor = false;
        var run = 0;
        final line = List<bool>.generate(size, (b) => pass == 0 ? modules[a][b] : modules[b][a]);
        for (var b = 0; b < size; b++) {
          if (b == 0 || line[b] != runColor) {
            if (run >= 5) result += 3 + (run - 5);
            runColor = line[b];
            run = 1;
          } else {
            run++;
          }
        }
        if (run >= 5) result += 3 + (run - 5);
        for (var b = 0; b + 11 <= size; b++) {
          final p1 = line[b] && !line[b + 1] && line[b + 2] && line[b + 3] && line[b + 4] && !line[b + 5] && line[b + 6] &&
              !line[b + 7] && !line[b + 8] && !line[b + 9] && !line[b + 10];
          final p2 = !line[b] && !line[b + 1] && !line[b + 2] && !line[b + 3] && line[b + 4] && !line[b + 5] && line[b + 6] &&
              line[b + 7] && line[b + 8] && !line[b + 9] && line[b + 10];
          if (p1) result += 40;
          if (p2) result += 40;
        }
      }
    }
    // N2: 2x2 blocks of one colour.
    for (var y = 0; y < size - 1; y++) {
      for (var x = 0; x < size - 1; x++) {
        final c = modules[y][x];
        if (c == modules[y][x + 1] && c == modules[y + 1][x] && c == modules[y + 1][x + 1]) result += 3;
      }
    }
    // N4: balance of dark and light.
    var dark = 0;
    for (final row in modules) {
      for (final m in row) {
        if (m) dark++;
      }
    }
    final total = size * size;
    final k = ((dark * 20 - total * 10).abs() + total - 1) ~/ total - 1;
    result += (k < 0 ? 0 : k) * 10;
    return result;
  }

  static int _max(int a, int b) => a > b ? a : b;
}
