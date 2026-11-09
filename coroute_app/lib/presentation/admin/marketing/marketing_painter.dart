import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../domain/marketing/marketing_layout.dart';
import '../../../domain/marketing/marketing_placeholders.dart';
import '../../../domain/marketing/marketing_template.dart';
import '../../../domain/marketing/qr_encoder.dart';

/// 3.55 Marketing studio: draws a template in its own pixel space (width x height). The editor
/// preview scales the canvas down and calls the same code, and the export records it at full
/// size, so what the admin sees is exactly what is shared.
class MarketingRenderer {
  final MarketingTemplate t;
  final Map<String, String> values;
  final Map<String, ui.Image> images;

  MarketingRenderer(this.t, this.values, {this.images = const {}});

  double get _w => t.size.width.toDouble();
  double get _h => t.size.height.toDouble();
  late final double u = mkUnitScale(t.size.width, t.size.height);

  String _sub(String s) => MkPlaceholders.substitute(s, values);

  void paint(Canvas canvas) {
    final full = Rect.fromLTWH(0, 0, _w, _h);
    canvas.save();
    canvas.clipRect(full);
    _background(canvas, full);
    for (final l in t.layers) {
      if (l.hidden || l.opacity <= 0) continue;
      final b = mkBoxOf(l, t.size.width, t.size.height);
      canvas.save();
      canvas.translate(b.cx, b.cy);
      if (b.angle != 0) canvas.rotate(b.angle);
      final box = Rect.fromCenter(center: Offset.zero, width: b.w, height: b.h);
      final faded = l.opacity < 1;
      if (faded) canvas.saveLayer(box.inflate(math.max(b.w, b.h)), Paint()..color = Color(MkColor.withAlpha(0xFF000000, l.opacity)));
      switch (l.type) {
        case MkLayerType.text:
          _text(canvas, l, box);
        case MkLayerType.coupon:
          _coupon(canvas, l, box);
        case MkLayerType.logo:
          _logo(canvas, l, box);
        case MkLayerType.shape:
          _shape(canvas, l, box);
        case MkLayerType.image:
          _image(canvas, l.imageId, box, l.imageFit, l.radius * u);
        case MkLayerType.qr:
          _qr(canvas, l, box);
      }
      if (faded) canvas.restore();
      canvas.restore();
    }
    canvas.restore();
  }

  // ------------------------------------------------------------------ background
  void _background(Canvas c, Rect full) {
    final bg = t.background;
    c.drawRect(full, Paint()..color = Color(bg.color));
    if (bg.kind == 'gradient' && bg.colors.length >= 2) {
      final a = bg.angle * math.pi / 180;
      final dx = math.cos(a), dy = math.sin(a);
      final half = (dx.abs() * _w + dy.abs() * _h) / 2;
      final centre = full.center;
      final shader = ui.Gradient.linear(
        centre - Offset(dx, dy) * half,
        centre + Offset(dx, dy) * half,
        [for (final x in bg.colors) Color(x)],
        [for (var i = 0; i < bg.colors.length; i++) i / (bg.colors.length - 1)],
      );
      c.drawRect(full, Paint()..shader = shader);
    } else if (bg.kind == 'image') {
      _image(c, bg.imageId, full, bg.imageFit, 0);
    }
    _pattern(c, bg);
    if (bg.overlay != null) c.drawRect(full, Paint()..color = Color(bg.overlay!));
  }

  void _pattern(Canvas c, MkBackground bg) {
    if (bg.pattern == 'none' || bg.patternOpacity <= 0) return;
    final col = Color(MkColor.withAlpha(bg.patternColor, bg.patternOpacity * ((bg.patternColor >> 24 & 0xFF) / 255)));
    final stroke = Paint()
      ..color = col
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = col;
    final diag = math.sqrt(_w * _w + _h * _h);
    switch (bg.pattern) {
      case 'dots':
        final s = 48 * u;
        for (var y = s / 2; y < _h; y += s) {
          for (var x = s / 2; x < _w; x += s) {
            c.drawCircle(Offset(x, y), 4.5 * u, fill);
          }
        }
      case 'stripes':
        c.save();
        c.translate(_w / 2, _h / 2);
        c.rotate(-math.pi / 4);
        final s = 64 * u;
        for (var x = -diag; x < diag; x += s) {
          c.drawRect(Rect.fromLTWH(x, -diag, 18 * u, diag * 2), fill);
        }
        c.restore();
      case 'rings':
        stroke.strokeWidth = 6 * u;
        final o = Offset(_w * 0.88, _h * 0.12);
        for (var r = 70 * u; r < diag * 1.1; r += 64 * u) {
          c.drawCircle(o, r, stroke);
        }
      case 'chevrons':
        stroke.strokeWidth = 8 * u;
        stroke.strokeJoin = StrokeJoin.round;
        final s = 80 * u;
        for (var y = 0.0; y < _h + s; y += s) {
          final p = Path()..moveTo(-s, y);
          for (var x = -s; x < _w + s; x += s) {
            p.lineTo(x + s / 2, y - s * 0.35);
            p.lineTo(x + s, y);
          }
          c.drawPath(p, stroke);
        }
      case 'topo':
        stroke.strokeWidth = 3.2 * u;
        for (final (cx, cy, phase) in [(0.18, 0.82, 0.0), (0.92, 0.12, 1.7)]) {
          final o = Offset(_w * cx, _h * cy);
          for (var k = 1; k <= 14; k++) {
            final base = k * 46.0 * u;
            final p = Path();
            for (var i = 0; i <= 120; i++) {
              final th = i / 120 * 2 * math.pi;
              final r = base + 14 * u * math.sin(3 * th + k * 0.6 + phase) + 9 * u * math.sin(5 * th - k * 0.9);
              final pt = o + Offset(math.cos(th) * r, math.sin(th) * r);
              i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
            }
            p.close();
            c.drawPath(p, stroke);
          }
        }
      case 'road':
        final road = Path()
          ..moveTo(_w * 0.02, _h * 1.08)
          ..cubicTo(_w * 0.08, _h * 0.42, _w * 0.92, _h * 0.78, _w * 1.02, -_h * 0.06);
        c.drawPath(road, Paint()
          ..color = col
          ..style = PaintingStyle.stroke
          ..strokeWidth = 120 * u
          ..strokeCap = StrokeCap.butt);
        _dashed(c, road, 40 * u, 34 * u, Paint()
          ..color = Color(MkColor.withAlpha(bg.patternColor, math.min(1, bg.patternOpacity * 2.4)))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 9 * u);
    }
  }

  static void _dashed(Canvas c, Path p, double dash, double gap, Paint paint) {
    for (final m in p.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        c.drawPath(m.extractPath(d, math.min(d + dash, m.length)), paint);
        d += dash + gap;
      }
    }
  }

  // ------------------------------------------------------------------ text
  static String? fontFamilyOf(String f) => switch (f) {
        'Manrope' => 'Manrope',
        'serif' => 'serif',
        'monospace' => 'monospace',
        _ => null,
      };

  static FontWeight _weightOf(int w) => FontWeight.values[((w ~/ 100) - 1).clamp(0, 8)];

  TextStyle _style({required String font, required double size, required int weight, required int color, double letterSpacing = 0, double height = 1.15, bool italic = false, List<Shadow>? shadows}) => TextStyle(
        fontFamily: fontFamilyOf(font),
        fontSize: size,
        fontWeight: _weightOf(weight),
        fontVariations: [ui.FontVariation('wght', weight.toDouble())],
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        color: Color(color),
        letterSpacing: letterSpacing,
        height: height,
        shadows: shadows,
      );

  static TextAlign _alignOf(String a) => a == 'left' ? TextAlign.left : (a == 'right' ? TextAlign.right : TextAlign.center);

  /// A text painter for [text] laid out at the box width; with [shrink] the size drops until it
  /// fits [box] (and no single word is wider than the box).
  TextPainter _fitted(String text, Rect box, TextStyle Function(double size) styleAt, double size, {TextAlign align = TextAlign.center, bool shrink = true, int? maxLines}) {
    TextPainter build(double s) => TextPainter(
          text: TextSpan(text: text, style: styleAt(s)),
          textAlign: align,
          textDirection: TextDirection.ltr,
          maxLines: maxLines,
          ellipsis: maxLines == null ? null : '…',
        )..layout(minWidth: box.width, maxWidth: box.width);
    var s = size;
    var tp = build(s);
    if (!shrink) return tp;
    var guard = 0;
    while ((tp.height > box.height + 0.5 || tp.didExceedMaxLines || _widestWord(text, styleAt(s)) > box.width) && s > 4 && guard++ < 60) {
      s *= 0.93;
      tp.dispose();
      tp = build(s);
    }
    return tp;
  }

  static double _widestWord(String text, TextStyle style) {
    var widest = 0.0;
    for (final word in text.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      final tp = TextPainter(text: TextSpan(text: word, style: style), textDirection: TextDirection.ltr)..layout();
      widest = math.max(widest, tp.width);
      tp.dispose();
    }
    return widest;
  }

  void _paintCentred(Canvas c, TextPainter tp, Rect box) {
    tp.paint(c, Offset(box.left, box.top + (box.height - tp.height) / 2));
    tp.dispose();
  }

  void _text(Canvas c, MkLayer l, Rect box) {
    var s = _sub(l.text);
    if (l.uppercase) s = s.toUpperCase();
    if (s.trim().isEmpty) return;
    final shadows = l.shadow == null ? null : [Shadow(color: Color(l.shadow!.color), offset: Offset(l.shadow!.dx * u, l.shadow!.dy * u), blurRadius: l.shadow!.blur * u)];
    final tp = _fitted(
      s,
      box,
      (size) => _style(font: l.font, size: size, weight: l.weight, color: l.color, letterSpacing: l.letterSpacing * u * (size / (l.size * u)), height: l.lineHeight, italic: l.italic, shadows: shadows),
      l.size * u,
      align: _alignOf(l.align),
      shrink: l.textFit == 'shrink',
    );
    _paintCentred(c, tp, box);
  }

  // ------------------------------------------------------------------ coupon block
  void _coupon(Canvas c, MkLayer l, Rect box) {
    final fill = Paint()..color = Color(l.fill);
    final accent = Color(l.accent);
    final minSide = math.min(box.width, box.height);
    Path shape;
    switch (l.style) {
      case 'pill':
        shape = Path()..addRRect(RRect.fromRectAndRadius(box, Radius.circular(box.height / 2)));
      case 'stamp':
        // Perforated edge: half circles bitten out along every side.
        final r = minSide * 0.032;
        final holes = Path();
        final step = r * 3.2;
        for (var x = box.left + step / 2; x < box.right; x += step) {
          holes.addOval(Rect.fromCircle(center: Offset(x, box.top), radius: r));
          holes.addOval(Rect.fromCircle(center: Offset(x, box.bottom), radius: r));
        }
        for (var y = box.top + step / 2; y < box.bottom; y += step) {
          holes.addOval(Rect.fromCircle(center: Offset(box.left, y), radius: r));
          holes.addOval(Rect.fromCircle(center: Offset(box.right, y), radius: r));
        }
        shape = Path.combine(PathOperation.difference, Path()..addRect(box), holes);
      case 'card':
        shape = Path()..addRRect(RRect.fromRectAndRadius(box, Radius.circular(minSide * 0.1)));
      default: // ticket
        final body = Path()..addRRect(RRect.fromRectAndRadius(box, Radius.circular(minSide * 0.09)));
        final notchR = box.height * 0.1;
        final notches = Path()
          ..addOval(Rect.fromCircle(center: Offset(box.left, box.center.dy), radius: notchR))
          ..addOval(Rect.fromCircle(center: Offset(box.right, box.center.dy), radius: notchR));
        shape = Path.combine(PathOperation.difference, body, notches);
    }
    c.drawShadow(shape, const Color(0xFF000000), minSide * 0.04, false);
    c.drawPath(shape, fill);
    if (l.style == 'card') {
      c.save();
      c.clipPath(shape);
      c.drawRect(Rect.fromLTWH(box.left, box.top, box.width, box.height * 0.07), Paint()..color = accent);
      c.restore();
    }

    final pad = l.style == 'pill' ? box.height * 0.18 : minSide * 0.11;
    final inner = Rect.fromLTRB(box.left + pad * (l.style == 'pill' ? 2 : 1), box.top + pad, box.right - pad * (l.style == 'pill' ? 2 : 1), box.bottom - pad);
    final headline = _sub(l.headline);
    final code = _sub(l.codeLine);
    final footer = _sub(l.footer);

    TextStyle st(double s, int w, int col) => _style(font: l.font, size: s, weight: w, color: col, height: 1.05);
    final faded = MkColor.withAlpha(l.textColor, 0.72);

    if (l.style == 'pill') {
      // One row: headline | code chip | footer, each shrunk to its share of the width.
      final parts = [if (headline.trim().isNotEmpty) headline, if (code.trim().isNotEmpty) code, if (footer.trim().isNotEmpty) footer];
      if (parts.isEmpty) return;
      final shares = parts.length == 3 ? [0.3, 0.42, 0.28] : (parts.length == 2 ? [0.42, 0.58] : [1.0]);
      var x = inner.left;
      for (var i = 0; i < parts.length; i++) {
        final w = inner.width * shares[i];
        final cell = Rect.fromLTWH(x, inner.top, w, inner.height);
        final isCode = parts[i] == code;
        final isHead = parts[i] == headline;
        final size = inner.height * (isHead ? 0.8 : (isCode ? 0.5 : 0.4));
        final tp = _fitted(parts[i], cell.deflate(cell.height * 0.08), (s) => st(s, isHead || isCode ? 800 : 600, isHead || isCode ? l.textColor : faded), size, maxLines: 1);
        if (isCode) _chip(c, cell, tp, accent, minSide);
        _paintCentred(c, tp, cell.deflate(cell.height * 0.08));
        x += w;
      }
      return;
    }

    // Stacked: headline, a dashed rule, the code chip, the footer.
    final hasFoot = footer.trim().isNotEmpty;
    final hHead = inner.height * (hasFoot ? 0.42 : 0.5);
    final hCode = inner.height * 0.32;
    final gap = inner.height * 0.04;
    var y = inner.top;
    if (l.style == 'card') y += box.height * 0.04;
    if (headline.trim().isNotEmpty) {
      final r = Rect.fromLTWH(inner.left, y, inner.width, hHead);
      _paintCentred(c, _fitted(headline, r, (s) => st(s, 800, l.style == 'stamp' ? l.accent : l.textColor), hHead * 0.92, maxLines: 2), r);
    }
    y += hHead + gap;
    if (l.style == 'ticket') {
      _dashed(c, Path()..moveTo(inner.left, y - gap / 2)..lineTo(inner.right, y - gap / 2), minSide * 0.03, minSide * 0.022, Paint()
        ..color = Color(MkColor.withAlpha(l.accent, 0.8))
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, minSide * 0.008));
    }
    if (code.trim().isNotEmpty) {
      final r = Rect.fromLTWH(inner.left + inner.width * 0.06, y + gap, inner.width * 0.88, hCode - gap * 2);
      final tp = _fitted(code, r.deflate(r.height * 0.18), (s) => st(s, 800, l.textColor), r.height * 0.55, maxLines: 1);
      _chip(c, r, tp, accent, minSide);
      _paintCentred(c, tp, r.deflate(r.height * 0.18));
    }
    y += hCode;
    if (hasFoot) {
      final r = Rect.fromLTWH(inner.left, y, inner.width, inner.bottom - y);
      if (r.height > 2) _paintCentred(c, _fitted(footer, r, (s) => st(s, 600, faded), r.height * 0.62, maxLines: 2), r);
    }
  }

  /// A dashed rounded outline around [tp]'s text inside [cell].
  void _chip(Canvas c, Rect cell, TextPainter tp, Color accent, double minSide) {
    final w = math.min(cell.width, _lineWidth(tp) + cell.height * 0.7);
    final r = Rect.fromCenter(center: cell.center, width: w, height: cell.height * 0.92);
    final rr = RRect.fromRectAndRadius(r, Radius.circular(r.height * 0.28));
    c.drawRRect(rr, Paint()..color = accent.withAlpha(0x26));
    _dashed(c, Path()..addRRect(rr), minSide * 0.025, minSide * 0.016, Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, minSide * 0.01));
  }

  static double _lineWidth(TextPainter tp) {
    var w = 0.0;
    for (final m in tp.computeLineMetrics()) {
      w = math.max(w, m.width);
    }
    return w;
  }

  // ------------------------------------------------------------------ logo
  /// The CoRoute mark (the app icon, from gateway/public/favicon.svg) in a [side] square at [o].
  static void drawMark(Canvas c, Offset o, double side) {
    c.save();
    c.translate(o.dx, o.dy);
    c.scale(side / 100);
    const ink = Color(MkBrand.ink);
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 100, 100), const Radius.circular(22)), Paint()..color = ink);
    final road = Path()
      ..moveTo(20, 82)
      ..cubicTo(20, 36, 80, 64, 80, 18);
    c.drawPath(road, Paint()
      ..color = const Color(MkBrand.teal)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 15
      ..strokeCap = StrokeCap.round);
    _dashed(c, road, 4.5, 4.5, Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2);
    for (final (x, y, col) in [(21.1, 72.3, MkBrand.paper), (50.0, 50.0, MkBrand.paper), (78.9, 27.7, MkBrand.amber)]) {
      c.drawCircle(Offset(x, y), 9.4, Paint()..color = ink);
      c.drawCircle(Offset(x, y), 7.2, Paint()..color = Color(col));
    }
    c.restore();
  }

  void _logo(Canvas c, MkLayer l, Rect box) {
    if (l.variant == 'mark') {
      final side = math.min(box.width, box.height);
      drawMark(c, box.center - Offset(side / 2, side / 2), side);
      return;
    }
    var side = box.height;
    TextPainter word(double s) => TextPainter(
          text: TextSpan(text: 'CoRoute', style: _style(font: 'Manrope', size: s, weight: 800, color: l.color, letterSpacing: -0.02 * s, height: 1)),
          textDirection: TextDirection.ltr,
        )..layout();
    var tp = word(side * 0.66);
    var total = side * 1.25 + tp.width;
    if (total > box.width) {
      final k = box.width / total;
      side *= k;
      tp.dispose();
      tp = word(side * 0.66);
      total = side * 1.25 + tp.width;
    }
    final left = box.center.dx - total / 2;
    drawMark(c, Offset(left, box.center.dy - side / 2), side);
    tp.paint(c, Offset(left + side * 1.25, box.center.dy - tp.height / 2));
    tp.dispose();
  }

  // ------------------------------------------------------------------ shapes
  Path _shapePath(MkLayer l, Rect box) {
    switch (l.shape) {
      case 'pill':
        return Path()..addRRect(RRect.fromRectAndRadius(box, Radius.circular(box.shortestSide / 2)));
      case 'circle':
        return Path()..addOval(box);
      case 'ribbon':
        final d = box.height * 0.38;
        return Path()
          ..moveTo(box.left, box.top)
          ..lineTo(box.right, box.top)
          ..lineTo(box.right - d, box.center.dy)
          ..lineTo(box.right, box.bottom)
          ..lineTo(box.left, box.bottom)
          ..lineTo(box.left + d, box.center.dy)
          ..close();
      case 'star':
      case 'burst':
        final n = l.shape == 'star' ? 5 : 16;
        final inner = l.shape == 'star' ? 0.45 : 0.8;
        final p = Path();
        for (var i = 0; i < n * 2; i++) {
          final a = -math.pi / 2 + i * math.pi / n;
          final k = i.isEven ? 1.0 : inner;
          final pt = box.center + Offset(math.cos(a) * box.width / 2 * k, math.sin(a) * box.height / 2 * k);
          i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
        }
        return p..close();
      default:
        return Path()..addRRect(RRect.fromRectAndRadius(box, Radius.circular(math.min(l.radius * u, box.shortestSide / 2))));
    }
  }

  void _shape(Canvas c, MkLayer l, Rect box) {
    final p = _shapePath(l, box);
    c.drawPath(p, Paint()..color = Color(l.fill));
    if (l.stroke != null && l.strokeWidth > 0) {
      c.drawPath(p, Paint()
        ..color = Color(l.stroke!)
        ..style = PaintingStyle.stroke
        ..strokeWidth = l.strokeWidth * u
        ..strokeJoin = StrokeJoin.round);
    }
    final label = _sub(l.label);
    if (label.trim().isEmpty) return;
    final inset = switch (l.shape) {
      'star' => box.deflate(box.shortestSide * 0.3),
      'burst' || 'circle' => Rect.fromCenter(center: box.center, width: box.width * 0.7, height: box.height * 0.6),
      'ribbon' => Rect.fromLTRB(box.left + box.height * 0.5, box.top + box.height * 0.12, box.right - box.height * 0.5, box.bottom - box.height * 0.12),
      _ => box.deflate(box.shortestSide * 0.12),
    };
    _paintCentred(c, _fitted(label, inset, (s) => _style(font: l.font, size: s, weight: l.weight, color: l.labelColor, height: 1.0), l.labelSize * u), inset);
  }

  // ------------------------------------------------------------------ images
  void _image(Canvas c, String? id, Rect box, String fit, double radius) {
    final img = id == null ? null : images[id];
    c.save();
    if (radius > 0) c.clipRRect(RRect.fromRectAndRadius(box, Radius.circular(radius)));
    if (img == null) {
      c.drawRect(box, Paint()..color = const Color(0x33FFFFFF));
      final line = Paint()
        ..color = const Color(0x66FFFFFF)
        ..strokeWidth = math.max(1, box.shortestSide * 0.01);
      c.drawLine(box.topLeft, box.bottomRight, line);
      c.drawLine(box.topRight, box.bottomLeft, line);
      c.restore();
      return;
    }
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    final src = Rect.fromLTWH(0, 0, iw, ih);
    final out = applyBoxFit(fit == 'contain' ? BoxFit.contain : BoxFit.cover, src.size, box.size);
    final s = Alignment.center.inscribe(out.source, src);
    final d = Alignment.center.inscribe(out.destination, box);
    c.drawImageRect(img, s, d, Paint()..filterQuality = FilterQuality.high);
    c.restore();
  }

  // ------------------------------------------------------------------ QR
  void _qr(Canvas c, MkLayer l, Rect box) {
    final side = math.min(box.width, box.height);
    final sq = Rect.fromCenter(center: box.center, width: side, height: side);
    final data = _sub(l.data).trim();
    QrCode? q;
    try {
      if (data.isNotEmpty) q = QrCode.encode(data);
    } on QrTooLongException {
      q = null;
    }
    if (q == null) {
      c.drawRect(sq, Paint()..color = Color(l.bgColor));
      final tp = _fitted(data.isEmpty ? 'No link' : 'Link too long for a QR code', sq.deflate(side * 0.1), (s) => _style(font: 'Manrope', size: s, weight: 700, color: l.color), side * 0.12);
      _paintCentred(c, tp, sq.deflate(side * 0.1));
      return;
    }
    const quiet = 2;
    final n = q.size + quiet * 2;
    final cell = side / n;
    c.drawRRect(RRect.fromRectAndRadius(sq, Radius.circular(cell * 1.2)), Paint()..color = Color(l.bgColor));
    final dark = Paint()
      ..color = Color(l.color)
      ..isAntiAlias = false;
    for (var y = 0; y < q.size; y++) {
      for (var x = 0; x < q.size; x++) {
        if (q.isDark(x, y)) {
          // A hair of overlap so no seams show between modules at fractional cell sizes.
          c.drawRect(Rect.fromLTWH(sq.left + (x + quiet) * cell, sq.top + (y + quiet) * cell, cell + 0.6, cell + 0.6), dark);
        }
      }
    }
  }
}

/// The editor preview: the template scaled to the widget, plus the selection outline and the
/// centre guides (never in the export).
class MarketingPreviewPainter extends CustomPainter {
  final MarketingTemplate template;
  final Map<String, String> values;
  final Map<String, ui.Image> images;
  final String? selectedId;
  final bool guideV;
  final bool guideH;
  final int revision;

  MarketingPreviewPainter({
    required this.template,
    required this.values,
    required this.images,
    this.selectedId,
    this.guideV = false,
    this.guideH = false,
    this.revision = 0,
  });

  /// Size of the move / resize / rotate handles in screen pixels.
  static const double handle = 22;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / template.size.width;
    canvas.save();
    canvas.scale(k);
    MarketingRenderer(template, values, images: images).paint(canvas);
    canvas.restore();

    final guide = Paint()
      ..color = const Color(0xFFFF2D9B)
      ..strokeWidth = 1.5;
    if (guideV) canvas.drawLine(Offset(size.width / 2, 0), Offset(size.width / 2, size.height), guide);
    if (guideH) canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), guide);

    final l = template.layerById(selectedId);
    if (l == null || l.hidden) return;
    final b = mkBoxOf(l, template.size.width, template.size.height);
    canvas.save();
    canvas.translate(b.cx * k, b.cy * k);
    canvas.rotate(b.angle);
    final r = Rect.fromCenter(center: Offset.zero, width: b.w * k, height: b.h * k);
    canvas.drawRect(r, Paint()
      ..color = const Color(0xFF3EE0EC)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    if (!l.locked) {
      final hp = Paint()..color = const Color(0xFF3EE0EC);
      final white = Paint()..color = Colors.white;
      // resize (bottom right) and rotate (above the top centre)
      canvas.drawCircle(r.bottomRight, handle / 2, hp);
      canvas.drawCircle(r.bottomRight, handle / 2 - 4, white);
      final rot = Offset(0, r.top - handle * 1.4);
      canvas.drawLine(Offset(0, r.top), rot, Paint()
        ..color = const Color(0xFF3EE0EC)
        ..strokeWidth = 2);
      canvas.drawCircle(rot, handle / 2, hp);
      canvas.drawCircle(rot, handle / 2 - 4, white);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(MarketingPreviewPainter old) =>
      old.revision != revision || old.template != template || old.selectedId != selectedId || old.guideV != guideV || old.guideH != guideH || old.images.length != images.length || old.values != values;
}

/// Renders [t] at full size to PNG bytes (the same drawing as the preview).
Future<Uint8List> renderMarketingPng(MarketingTemplate t, Map<String, String> values, {Map<String, ui.Image> images = const {}}) async {
  final w = t.size.width, h = t.size.height;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
  MarketingRenderer(t, values, images: images).paint(canvas);
  final pic = rec.endRecording();
  final img = await pic.toImage(w, h);
  try {
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('PNG encoding failed');
    return data.buffer.asUint8List();
  } finally {
    img.dispose();
    pic.dispose();
  }
}
