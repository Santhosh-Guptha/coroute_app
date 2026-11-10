/* CoRoute web admin: a small QR code encoder (ISO/IEC 18004), a port of the app's
   lib/domain/marketing/qr_encoder.dart so the web studio draws the same symbols.
   Byte mode (UTF-8), error correction level M, versions 1 to 10 (up to 213 bytes), automatic mask
   choice by the standard penalty rules. Verified module for module against the Python `qrcode`
   reference encoder (gateway/test/web_admin_355.test.js). Works in the browser (window.CRQR) and
   in Node (module.exports) for the test. */
(function (root) {
  'use strict';
  var MAX_BYTES = 213;
  // [ec codewords per block, blocks g1, data per g1 block, blocks g2, data per g2 block] (level M)
  var BLOCKS_M = [
    [10, 1, 16, 0, 0], [16, 1, 28, 0, 0], [26, 1, 44, 0, 0], [18, 2, 32, 0, 0], [24, 2, 43, 0, 0],
    [16, 4, 27, 0, 0], [18, 4, 31, 0, 0], [22, 2, 38, 2, 39], [22, 3, 36, 2, 37], [26, 4, 43, 1, 44],
  ];
  var ALIGN = [[], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50]];

  function utf8(text) {
    if (typeof TextEncoder !== 'undefined') return Array.from(new TextEncoder().encode(text));
    return Array.from(Buffer.from(text, 'utf8'));
  }
  function dataCodewords(v) { var t = BLOCKS_M[v - 1]; return t[1] * t[2] + t[3] * t[4]; }

  function dataBits(data, version) {
    var bits = [];
    function put(value, n) { for (var i = n - 1; i >= 0; i--) bits.push((value >>> i) & 1); }
    put(0x4, 4);
    put(data.length, version < 10 ? 8 : 16);
    data.forEach(function (b) { put(b, 8); });
    var capacity = dataCodewords(version) * 8;
    put(0, Math.max(0, Math.min(4, capacity - bits.length)));
    while (bits.length % 8) bits.push(0);
    var bytes = [];
    for (var i = 0; i < bits.length; i += 8) {
      var v = 0;
      for (var j = 0; j < 8; j++) v = (v << 1) | bits[i + j];
      bytes.push(v);
    }
    for (var pad = 0xEC; bytes.length < dataCodewords(version); pad ^= 0xEC ^ 0x11) bytes.push(pad);
    return bytes;
  }

  function gfMul(x, y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) {
      z = (z << 1) ^ ((z >>> 7) * 0x11D);
      z ^= ((y >>> i) & 1) * x;
    }
    return z & 0xFF;
  }
  function rsGenerator(degree) {
    var result = new Array(degree).fill(0);
    result[degree - 1] = 1;
    var root = 1;
    for (var i = 0; i < degree; i++) {
      for (var j = 0; j < degree; j++) {
        result[j] = gfMul(result[j], root);
        if (j + 1 < degree) result[j] ^= result[j + 1];
      }
      root = gfMul(root, 0x02);
    }
    return result;
  }
  function rsRemainder(data, gen) {
    var result = new Array(gen.length).fill(0);
    data.forEach(function (b) {
      var factor = b ^ result.shift();
      result.push(0);
      for (var i = 0; i < gen.length; i++) result[i] ^= gfMul(gen[i], factor);
    });
    return result;
  }
  function addEcc(data, version) {
    var t = BLOCKS_M[version - 1];
    var ecLen = t[0];
    var gen = rsGenerator(ecLen);
    var blocks = []; var eccs = []; var k = 0;
    for (var g = 0; g < 2; g++) {
      var count = t[1 + g * 2]; var len = t[2 + g * 2];
      for (var i = 0; i < count; i++) {
        var block = data.slice(k, k + len); k += len;
        blocks.push(block); eccs.push(rsRemainder(block, gen));
      }
    }
    var out = [];
    var maxLen = blocks.reduce(function (m, b) { return Math.max(m, b.length); }, 0);
    for (var a = 0; a < maxLen; a++) blocks.forEach(function (b) { if (a < b.length) out.push(b[a]); });
    for (var e = 0; e < ecLen; e++) eccs.forEach(function (x) { out.push(x[e]); });
    return out;
  }

  function Builder(version) {
    this.version = version;
    this.size = version * 4 + 17;
    this.modules = []; this.isFunction = [];
    for (var y = 0; y < this.size; y++) { this.modules.push(new Array(this.size).fill(false)); this.isFunction.push(new Array(this.size).fill(false)); }
  }
  Builder.prototype.set = function (x, y, dark) { this.modules[y][x] = dark; this.isFunction[y][x] = true; };
  Builder.prototype.finder = function (x, y) {
    for (var dy = -4; dy <= 4; dy++) {
      for (var dx = -4; dx <= 4; dx++) {
        var xx = x + dx; var yy = y + dy;
        if (xx < 0 || xx >= this.size || yy < 0 || yy >= this.size) continue;
        var d = Math.max(Math.abs(dx), Math.abs(dy));
        this.set(xx, yy, d !== 2 && d !== 4);
      }
    }
  };
  Builder.prototype.drawFunctionPatterns = function () {
    var size = this.size;
    for (var i = 0; i < size; i++) { this.set(6, i, i % 2 === 0); this.set(i, 6, i % 2 === 0); }
    this.finder(3, 3); this.finder(size - 4, 3); this.finder(3, size - 4);
    var pos = ALIGN[this.version - 1]; var n = pos.length;
    for (var a = 0; a < n; a++) {
      for (var b = 0; b < n; b++) {
        if ((a === 0 && b === 0) || (a === 0 && b === n - 1) || (a === n - 1 && b === 0)) continue;
        for (var dy = -2; dy <= 2; dy++) for (var dx = -2; dx <= 2; dx++) this.set(pos[a] + dx, pos[b] + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
      }
    }
    this.drawFormatBits(0);
    if (this.version >= 7) {
      var rem = this.version;
      for (var r = 0; r < 12; r++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1F25);
      var bits = (this.version << 12) | rem;
      for (var k = 0; k < 18; k++) {
        var bit = ((bits >>> k) & 1) !== 0;
        var p = size - 11 + (k % 3); var q = Math.floor(k / 3);
        this.set(p, q, bit); this.set(q, p, bit);
      }
    }
  };
  Builder.prototype.drawFormatBits = function (mask) {
    var data = (0 << 3) | mask; // level M = 0b00
    var rem = data;
    for (var i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
    var bits = ((data << 10) | rem) ^ 0x5412;
    function bit(n) { return ((bits >>> n) & 1) !== 0; }
    var size = this.size;
    for (var a = 0; a <= 5; a++) this.set(8, a, bit(a));
    this.set(8, 7, bit(6)); this.set(8, 8, bit(7)); this.set(7, 8, bit(8));
    for (var b = 9; b < 15; b++) this.set(14 - b, 8, bit(b));
    for (var c = 0; c < 8; c++) this.set(size - 1 - c, 8, bit(c));
    for (var d = 8; d < 15; d++) this.set(8, size - 15 + d, bit(d));
    this.set(8, size - 8, true);
  };
  Builder.prototype.drawCodewords = function (data) {
    var i = 0; var size = this.size;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right === 6) right = 5;
      for (var vert = 0; vert < size; vert++) {
        for (var j = 0; j < 2; j++) {
          var x = right - j;
          var upward = ((right + 1) & 2) === 0;
          var y = upward ? size - 1 - vert : vert;
          if (!this.isFunction[y][x] && i < data.length * 8) {
            this.modules[y][x] = ((data[i >>> 3] >>> (7 - (i & 7))) & 1) !== 0;
            i++;
          }
        }
      }
    }
  };
  function masked(mask, x, y) {
    switch (mask) {
      case 0: return (x + y) % 2 === 0;
      case 1: return y % 2 === 0;
      case 2: return x % 3 === 0;
      case 3: return (x + y) % 3 === 0;
      case 4: return (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0;
      case 5: return (x * y) % 2 + (x * y) % 3 === 0;
      case 6: return ((x * y) % 2 + (x * y) % 3) % 2 === 0;
      default: return ((x + y) % 2 + (x * y) % 3) % 2 === 0;
    }
  }
  Builder.prototype.applyMask = function (mask) {
    for (var y = 0; y < this.size; y++) for (var x = 0; x < this.size; x++) {
      if (!this.isFunction[y][x] && masked(mask, x, y)) this.modules[y][x] = !this.modules[y][x];
    }
  };
  Builder.prototype.penalty = function () {
    var size = this.size; var m = this.modules; var result = 0;
    for (var pass = 0; pass < 2; pass++) {
      for (var a = 0; a < size; a++) {
        var line = [];
        for (var b0 = 0; b0 < size; b0++) line.push(pass === 0 ? m[a][b0] : m[b0][a]);
        var runColor = false; var run = 0;
        for (var b = 0; b < size; b++) {
          if (b === 0 || line[b] !== runColor) {
            if (run >= 5) result += 3 + (run - 5);
            runColor = line[b]; run = 1;
          } else run++;
        }
        if (run >= 5) result += 3 + (run - 5);
        for (var c = 0; c + 11 <= size; c++) {
          var L = line;
          if (L[c] && !L[c + 1] && L[c + 2] && L[c + 3] && L[c + 4] && !L[c + 5] && L[c + 6] && !L[c + 7] && !L[c + 8] && !L[c + 9] && !L[c + 10]) result += 40;
          if (!L[c] && !L[c + 1] && !L[c + 2] && !L[c + 3] && L[c + 4] && !L[c + 5] && L[c + 6] && L[c + 7] && L[c + 8] && !L[c + 9] && L[c + 10]) result += 40;
        }
      }
    }
    for (var y = 0; y < size - 1; y++) for (var x = 0; x < size - 1; x++) {
      var v = m[y][x];
      if (v === m[y][x + 1] && v === m[y + 1][x] && v === m[y + 1][x + 1]) result += 3;
    }
    var dark = 0;
    m.forEach(function (row) { row.forEach(function (d) { if (d) dark++; }); });
    var total = size * size;
    var k = Math.floor((Math.abs(dark * 20 - total * 10) + total - 1) / total) - 1;
    return result + Math.max(0, k) * 10;
  };

  /** Encodes text: { version, size, mask, modules (rows of booleans), isDark(x, y) }. Throws on > 213 bytes. */
  function encode(text, opts) {
    opts = opts || {};
    var data = utf8(String(text));
    var version = null;
    for (var v = Math.max(1, Math.min(10, opts.minVersion || 1)); v <= 10; v++) {
      if (4 + (v < 10 ? 8 : 16) + data.length * 8 <= dataCodewords(v) * 8) { version = v; break; }
    }
    if (version === null) { var err = new Error('QR data too long: ' + data.length + ' bytes (at most ' + MAX_BYTES + ').'); err.code = 'QR_TOO_LONG'; throw err; }
    var codewords = addEcc(dataBits(data, version), version);
    var b = new Builder(version);
    b.drawFunctionPatterns();
    b.drawCodewords(codewords);
    var mask = typeof opts.forceMask === 'number' ? opts.forceMask : -1;
    if (mask < 0) {
      var best = Infinity;
      for (var mm = 0; mm < 8; mm++) {
        b.applyMask(mm); b.drawFormatBits(mm);
        var p = b.penalty();
        if (p < best) { best = p; mask = mm; }
        b.applyMask(mm);
      }
    }
    b.applyMask(mask); b.drawFormatBits(mask);
    var modules = b.modules;
    return { version: version, size: b.size, mask: mask, modules: modules, isDark: function (x, y) { return modules[y][x]; } };
  }

  var api = { encode: encode, MAX_BYTES: MAX_BYTES };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.CRQR = api;
})(typeof window !== 'undefined' ? window : this);
