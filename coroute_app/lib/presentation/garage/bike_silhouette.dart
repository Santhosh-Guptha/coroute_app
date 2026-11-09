import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../domain/garage/bike_type.dart';
import '../../domain/ride/bike_markers.dart';

/// 3.55 bike shapes: one original, simple side-view silhouette per [BikeType] (no brand designs),
/// drawn with vector paths. The garage shows it instead of a round avatar and the ride map uses
/// the same shapes for the bike markers. Design box: 64 × 44 units (x 0..64, y -4..40, ground at
/// y 38), facing right. The data is also rendered to SVG for a visual check (docs).
@immutable
class BikeShape {
  const BikeShape({
    required this.wheels,
    required this.lines,
    required this.body,
    required this.dark,
    this.light = const [],
    this.rings = const [],
    required this.rider,
    required this.grip,
    required this.pillion,
  });

  /// (cx, cy, r): tyres.
  final List<(double, double, double)> wheels;

  /// (x1, y1, x2, y2, width): forks, bars, swingarm, exhaust.
  final List<(double, double, double, double, double)> lines;

  /// SVG path data (absolute M, L, Q, C, Z) filled with the bike's colour.
  final List<String> body;

  /// Seat, engine, screen: filled with the outline colour.
  final List<String> dark;

  /// Contrast marks (the electric bolt).
  final List<String> light;

  /// (cx, cy, r): a round headlight.
  final List<(double, double, double)> rings;

  /// Rider's hip, hand grip and the pillion's hip.
  final (double, double) rider;
  final (double, double) grip;
  final (double, double) pillion;
}

class BikeShapes {
  BikeShapes._();

  static const double designWidth = 64;
  static const double designHeight = 44;
  static const double top = -4;

  static const Map<BikeType, BikeShape> _shapes = {
    BikeType.commuter: BikeShape(
      wheels: [(13.0, 30.0, 7.5), (51.0, 30.0, 7.5)],
      lines: [(51.0, 30.0, 44.5, 12.0, 2.6), (41.5, 11.0, 47.5, 9.5, 2.2), (13.0, 30.0, 31.0, 27.0, 2.6), (22.0, 31.5, 8.0, 29.5, 2.2)],
      body: ['M27 17 Q35 12.5 43.5 15 L44.5 20.5 Q36 21.5 29 22.5 Z', 'M18 20 L29.5 20 L31 25.5 L20 25.5 Z', 'M43 24.5 Q51 18.5 59 24 L57 25.5 Q51 21.5 45 26 Z', 'M4.5 25.5 Q9.5 18.5 18 20.5 L18 23 Q11 22 6.5 26.5 Z'],
      dark: ['M13 18.5 Q20 15.5 29 18 L29 20.5 L15 21.5 Z', 'M28.5 23 L39.5 22 L40.5 29.5 L30 31 Z', 'M45 13.5 L49.5 14 L49 17.5 L45.5 17 Z'],
      light: [],
      rings: [],
      rider: (22.0, 17.0),
      grip: (44.0, 11.0),
      pillion: (15.0, 16.5),
    ),
    BikeType.scooter: BikeShape(
      wheels: [(12.0, 32.0, 6.0), (50.0, 32.0, 6.0)],
      lines: [(48.0, 31.0, 44.5, 12.0, 2.4), (40.5, 8.5, 48.5, 7.5, 2.4)],
      body: ['M5 25 Q6.5 16.5 20 16.5 L33 17.5 L33.5 22 Q31 27 26 28 L10 28 Q5 28 5 25 Z', 'M24 26.5 L41 26.5 L41 30 L22 30 Z', 'M38 30 L41.5 10.5 Q44.5 8.5 47 10.5 L48 22 Q47 28.5 42 30 Z', 'M43 27 Q50 22.5 57 27 L55.5 28.5 Q50 25.5 45 28.5 Z'],
      dark: ['M8.5 17 Q18 12.5 32.5 15.5 L32.5 17.5 L10 18 Z', 'M44 10 L47.5 10 L47.5 13 L44.5 13 Z'],
      light: [],
      rings: [],
      rider: (21.0, 15.5),
      grip: (43.0, 8.0),
      pillion: (12.0, 15.0),
    ),
    BikeType.sport: BikeShape(
      wheels: [(13.0, 30.0, 7.5), (51.0, 30.0, 7.5)],
      lines: [(51.0, 30.0, 46.0, 13.0, 2.6), (13.0, 30.0, 30.0, 26.5, 2.8), (24.0, 27.0, 14.0, 23.0, 2.2)],
      body: ['M20 21 L30 14.5 Q38 11 46 12 L54 16.5 L50.5 24 L41 28.5 L28 28.5 Z', 'M4 15 L22 17 L27 21 L13 22.5 Z', 'M44 24 Q51 19 58 23.5 L56.5 25 Q51 21.5 46 25.5 Z'],
      dark: ['M11 14.5 L24 15 L27.5 18.5 L15 19.5 Z', 'M44.5 12 L50.5 8.5 L54 16 Z', 'M30 22 L38 21 L37 27.5 L31 28 Z'],
      light: [],
      rings: [],
      rider: (21.0, 15.0),
      grip: (45.0, 13.5),
      pillion: (9.0, 13.5),
    ),
    BikeType.cruiser: BikeShape(
      wheels: [(12.0, 30.0, 7.5), (55.0, 30.0, 8.0)],
      lines: [(55.0, 30.0, 45.0, 11.0, 2.6), (45.0, 11.0, 43.0, 5.5, 2.2), (43.0, 5.5, 48.0, 6.5, 2.2), (12.0, 30.0, 27.0, 28.0, 2.6), (16.0, 33.0, 38.0, 31.5, 2.4), (40.0, 29.0, 46.0, 28.5, 2.0)],
      body: ['M25.5 18.5 Q34 13 43 16.5 Q41 20.5 30 21.5 Z', 'M2.5 26.5 Q7 17.5 19 22 L18 24.5 Q10 22 5.5 27.5 Z', 'M48 25.5 Q55 20 62 25 L60.5 26.5 Q55 23 50 27 Z'],
      dark: ['M12.5 21.5 Q21 18 26.5 20.5 L26.5 23.5 L15 23.5 Z', 'M26 22.5 L34.5 21 L38.5 30 L28 31.5 Z', 'M45.5 12.5 L49.5 13 L49 16.5 L46 16 Z'],
      light: [],
      rings: [],
      rider: (20.0, 20.0),
      grip: (44.0, 6.5),
      pillion: (13.0, 19.0),
    ),
    BikeType.adventure: BikeShape(
      wheels: [(12.0, 30.0, 7.5), (53.0, 29.0, 8.5)],
      lines: [(53.0, 29.0, 46.0, 10.0, 2.8), (42.0, 8.5, 48.0, 8.0, 2.4), (12.0, 30.0, 30.0, 25.0, 2.8)],
      body: ['M22 17 L32 11 Q40 8.5 46 10.5 L48 18 L36 21.5 L26 22 Z', 'M45 13.5 L57 16 L50 19 Z', 'M30 23 L42 21.5 L44 27 L32 28.5 Z'],
      dark: ['M8 12.5 L24 13.5 L26.5 17 L10 17.5 Z', 'M43 9.5 L46.5 2.5 L49 11 Z', 'M2.5 16.5 L14 16.5 L14 25.5 L2.5 25.5 Z', 'M27 22.5 L36 22 L37 27 L29 28 Z'],
      light: [],
      rings: [],
      rider: (18.0, 13.0),
      grip: (44.0, 8.5),
      pillion: (10.0, 11.5),
    ),
    BikeType.offroad: BikeShape(
      wheels: [(12.0, 29.5, 8.0), (52.0, 29.5, 8.0)],
      lines: [(52.0, 29.5, 45.0, 9.0, 2.4), (41.0, 8.0, 48.0, 8.5, 2.6), (12.0, 29.5, 30.0, 24.0, 2.4), (30.0, 18.0, 24.0, 26.0, 2.0)],
      body: ['M45.5 12 L59 12.5 L55 15 L47 14.5 Z', 'M30 12 L44.5 10 L46.5 16.5 L34 19.5 Z', 'M3 11.5 L14.5 12 L16.5 16 L6 16.5 Z'],
      dark: ['M12 13 L37 11.5 L37 14.5 L14 16 Z', 'M28.5 20 L37 19 L37 26 L30.5 27 Z'],
      light: [],
      rings: [],
      rider: (22.0, 12.0),
      grip: (44.0, 8.5),
      pillion: (14.0, 11.5),
    ),
    BikeType.electric: BikeShape(
      wheels: [(12.0, 32.0, 6.0), (50.0, 32.0, 6.0)],
      lines: [(48.0, 31.0, 45.0, 11.5, 2.4), (41.5, 8.5, 49.0, 8.0, 2.4)],
      body: ['M5 24.5 Q7 15.5 22 15.5 L34.5 16.5 Q34.5 24.5 28.5 27.5 L9 27.5 Q5 27 5 24.5 Z', 'M26 27 L41 27 L41 30 L24 30 Z', 'M38.5 29.5 L42.5 9.5 L47.5 11 L47.5 24 Z'],
      dark: ['M8 15.5 Q20 11.5 34 14.5 L34 16.5 L10 17 Z'],
      light: ['M21.5 17.5 L15.5 23 L19.5 23 L16.5 27 L24 20.5 L20 20.5 L22.5 17.5 Z'],
      rings: [],
      rider: (22.0, 14.5),
      grip: (44.0, 8.5),
      pillion: (12.5, 14.0),
    ),
    BikeType.retro: BikeShape(
      wheels: [(13.0, 30.0, 7.5), (51.0, 30.0, 7.5)],
      lines: [(51.0, 30.0, 45.0, 13.0, 2.6), (42.0, 13.5, 47.5, 13.0, 2.2), (13.0, 30.0, 29.0, 27.5, 2.6), (30.0, 31.0, 12.0, 28.0, 2.2)],
      body: ['M26 16.5 Q35 10.5 43.5 15 Q42.5 20.5 28 20.5 Z', 'M8.5 12.5 Q12.5 11.5 15 17 L10 17.5 Z', 'M45 24.5 Q51 20 57 24 L55.5 25.5 Q51 22.5 46.5 26 Z'],
      dark: ['M11 17 L26.5 17 L26.5 19.5 L13.5 20.5 Z', 'M27 21 L38.5 20 L39.5 29 L29.5 30.5 Z'],
      light: [],
      rings: [(47.5, 14.5, 2.6)],
      rider: (20.0, 16.5),
      grip: (44.0, 13.5),
      pillion: (12.0, 15.5),
    ),
  };

  static BikeShape of(BikeType t) => _shapes[t]!;

  static final Map<String, Path> _paths = <String, Path>{};

  /// The path for SVG path data (absolute M, L, H, V, Q, C, Z), parsed once and kept.
  static Path path(String d) => _paths.putIfAbsent(d, () => parseSvgPath(d));

  /// Outline colour for a bike colour (a very dark bike gets a grey outline so its parts show).
  static Color outlineFor(Color c) => _lum(c) < 60 ? const Color(0xFF6B7280) : const Color(0xFF1F2328);

  static double _lum(Color c) {
    final v = c.toARGB32();
    return 0.299 * ((v >> 16) & 0xFF) + 0.587 * ((v >> 8) & 0xFF) + 0.114 * (v & 0xFF);
  }

  /// Draws [type] in [colour] into [size] (aspect kept, centred), with [people] riders (0, 1 or 2).
  static void paint(Canvas canvas, Size size, BikeType type, Color colour, {int people = 0, bool faceLeft = false}) {
    final s = of(type);
    final scale = (size.width / designWidth) < (size.height / designHeight) ? size.width / designWidth : size.height / designHeight;
    final dx = (size.width - designWidth * scale) / 2, dy = (size.height - designHeight * scale) / 2;
    canvas.save();
    canvas.translate(dx, dy);
    if (faceLeft) {
      canvas.translate(designWidth * scale, 0);
      canvas.scale(-1, 1);
    }
    canvas.scale(scale);
    canvas.translate(0, -top);
    final dark = outlineFor(colour);
    final light = _lum(colour) > 170 ? const Color(0xFF1F2328) : const Color(0xFFFFFFFF);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = dark;
    final fill = Paint()..style = PaintingStyle.fill;
    for (final (cx, cy, r) in s.wheels) {
      canvas.drawCircle(Offset(cx, cy), r - r * 0.21, stroke..strokeWidth = r * 0.42);
      canvas.drawCircle(Offset(cx, cy), r * 0.22, fill..color = dark);
    }
    for (final (x1, y1, x2, y2, w) in s.lines) {
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), stroke..strokeWidth = w);
    }
    for (final d in s.body) {
      final p = path(d);
      canvas.drawPath(p, fill..color = colour);
      canvas.drawPath(p, stroke..strokeWidth = 1.2);
    }
    for (final d in s.dark) {
      canvas.drawPath(path(d), fill..color = dark);
    }
    for (final d in s.light) {
      canvas.drawPath(path(d), fill..color = light);
    }
    for (final (cx, cy, r) in s.rings) {
      canvas.drawCircle(Offset(cx, cy), r, fill..color = const Color(0xFFFFF3C4));
      canvas.drawCircle(Offset(cx, cy), r, stroke..strokeWidth = 1.4);
    }
    if (people > 0) _people(canvas, s, people);
    canvas.restore();
  }

  static void _people(Canvas canvas, BikeShape s, int people) {
    const body = Color(0xFF263238), helmet = Color(0xFFFFFFFF);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = body;
    void figure(double hx, double hy, double sx, double sy, double ax, double ay, double kx, double ky, double fx, double fy) {
      canvas.drawPath(Path()
        ..moveTo(hx, hy)
        ..lineTo(kx, ky)
        ..lineTo(fx, fy), line..strokeWidth = 2.6);
      canvas.drawLine(Offset(hx, hy), Offset(sx, sy), line..strokeWidth = 4.2);
      canvas.drawLine(Offset(sx, sy), Offset(ax, ay), line..strokeWidth = 2.2);
      canvas.drawCircle(Offset(sx + 1, sy - 4.2), 3.3, Paint()..color = helmet);
      canvas.drawCircle(Offset(sx + 1, sy - 4.2), 3.3, line..strokeWidth = 1.3);
    }

    final (rx, ry) = s.rider;
    final (gx, gy) = s.grip;
    final rsx = rx + (gx - rx) * 0.22, rsy = ry - 9 + (gy - (ry - 9)) * 0.25;
    if (people >= 2) {
      final (px, py) = s.pillion;
      figure(px, py, px + 2.5, py - 9, rx + 1, ry - 4, px + 5, py + 5, px + 3.5, py + 10.5);
    }
    figure(rx, ry, rsx, rsy, gx, gy, rx + 6, ry + 5, rx + 5, ry + 11);
  }
}

/// Parses absolute SVG path data (M, L, H, V, Q, C, Z) into a [Path]. Only what the bike shapes use.
Path parseSvgPath(String d) {
  final tokens = RegExp(r'[MLHVQCZ]|-?[0-9]*\.?[0-9]+', caseSensitive: false).allMatches(d).map((m) => m.group(0)!).toList();
  final p = Path();
  var i = 0;
  var cmd = 'M';
  var x = 0.0, y = 0.0;
  double n() => double.parse(tokens[i++]);
  while (i < tokens.length) {
    final t = tokens[i];
    if (RegExp(r'^[A-Za-z]$').hasMatch(t)) {
      cmd = t.toUpperCase();
      i++;
      if (cmd == 'Z') {
        p.close();
        continue;
      }
    }
    switch (cmd) {
      case 'M':
        x = n();
        y = n();
        p.moveTo(x, y);
        cmd = 'L';
      case 'L':
        x = n();
        y = n();
        p.lineTo(x, y);
      case 'H':
        x = n();
        p.lineTo(x, y);
      case 'V':
        y = n();
        p.lineTo(x, y);
      case 'Q':
        final x1 = n(), y1 = n();
        x = n();
        y = n();
        p.quadraticBezierTo(x1, y1, x, y);
      case 'C':
        final x1 = n(), y1 = n(), x2 = n(), y2 = n();
        x = n();
        y = n();
        p.cubicTo(x1, y1, x2, y2, x, y);
      default:
        i++;
    }
  }
  return p;
}

/// Recorded bike glyphs, one per [BikeMarkerKey] (type, colour, people, cue, size): every marker
/// with the same look replays one picture instead of re-tessellating the paths each frame.
class BikeGlyphCache {
  BikeGlyphCache._();

  static final BikeGlyphLru<ui.Picture> _lru = BikeGlyphLru<ui.Picture>(max: 96, onEvict: (p) => p.dispose());

  static int get length => _lru.length;

  /// The picture for [key] drawn in a box [key.size] wide (aspect 64:44).
  static ui.Picture pictureFor(BikeMarkerKey key, {bool faceLeft = false}) {
    // Facing is a transform when drawn, not part of the picture.
    return _lru.putIfAbsent(key, () {
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      final w = key.size.toDouble();
      BikeShapes.paint(c, Size(w, w * BikeShapes.designHeight / BikeShapes.designWidth), key.type, Color(key.argb), people: key.twoUp ? 2 : 1);
      return rec.endRecording();
    });
  }

  static void clear() => _lru.clear();
}

/// The bike as a widget (garage cards, the type picker, the pillion seat list): 3.56 the rendered
/// 3D "hero" view of its type (3/4 front-right, assets/garage_bikes, [BikeSprites.hero]) with the
/// paint tinted in the bike's colour, the same look as the 3D map marker; two riders on it when
/// [people] is 2. Falls back to the vector side silhouette when the image is missing ([vector]
/// forces it). Box: [width] × [width] × 0.625 (hero) or × 44/64 (vector).
class BikeSilhouette extends StatelessWidget {
  const BikeSilhouette({super.key, required this.type, required this.colour, this.width = 64, this.people = 0, this.semanticLabel, this.vector = false});

  final BikeType type;
  final Color colour;
  final double width;
  final int people;
  final String? semanticLabel;
  final bool vector;

  Widget _vector() {
    final h = width * BikeShapes.designHeight / BikeShapes.designWidth;
    return SizedBox(width: width, height: h, child: CustomPaint(size: Size(width, h), painter: _BikePainter(type, colour, people)));
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (vector) {
      child = _vector();
    } else {
      final h = width * BikeSprites.heroHeight / BikeSprites.heroWidth;
      final tint = Color(BikeSprites.paintArgb(colour.toARGB32()));
      Widget layer(BikeLayer l, {Color? color, bool fallback = false}) => Image.asset(
            BikeSprites.hero(type, people, l),
            width: width,
            height: h,
            fit: BoxFit.contain,
            color: color,
            colorBlendMode: color == null ? null : BlendMode.modulate,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => fallback ? FittedBox(child: _vector()) : const SizedBox.shrink(),
          );
      child = SizedBox(
        width: width,
        height: h,
        child: Stack(
          fit: StackFit.expand,
          children: [
            layer(BikeLayer.base, fallback: true),
            layer(BikeLayer.paint, color: tint),
            layer(BikeLayer.gloss),
          ],
        ),
      );
    }
    return Semantics(
      label: semanticLabel ?? '${type.label} bike',
      image: true,
      excludeSemantics: true,
      child: child,
    );
  }
}

class _BikePainter extends CustomPainter {
  const _BikePainter(this.type, this.colour, this.people);
  final BikeType type;
  final Color colour;
  final int people;

  @override
  void paint(Canvas canvas, Size size) => BikeShapes.paint(canvas, size, type, colour, people: people);

  @override
  bool shouldRepaint(covariant _BikePainter old) => old.type != type || old.colour != colour || old.people != people;
}

/// The colour to draw for a garage colour name / #RRGGBB ([fallback] when unknown).
Color bikeColourOf(String raw, {Color fallback = const Color(0xFF7A7A7A)}) {
  final v = BikeColours.parse(raw);
  return v == null ? fallback : Color(v);
}
