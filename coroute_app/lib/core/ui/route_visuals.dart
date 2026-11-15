import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'coroute_logo.dart';
import 'ui_tokens.dart';

/// v3.59 CoRoute's own visual language (so the app no longer looks like other ride apps):
/// a road with amber lane marks. Used as the edge of "route ticket" rows, in section headers and on the bottom bar.
class RoadStripe extends StatelessWidget {
  final double width;
  final double? height;
  final Color? road;
  final Color dash;
  final Axis axis;
  const RoadStripe({super.key, this.width = 6, this.height, this.road, this.dash = CoRouteBrand.amber, this.axis = Axis.vertical});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox(
          width: axis == Axis.vertical ? width : height,
          height: axis == Axis.vertical ? height : width,
          child: CustomPaint(painter: _RoadPainter(road ?? AppTheme.primaryFill, dash, axis)),
        ),
      );
}

class _RoadPainter extends CustomPainter {
  final Color road;
  final Color dash;
  final Axis axis;
  _RoadPainter(this.road, this.dash, this.axis);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular((axis == Axis.vertical ? size.width : size.height) / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, r), Paint()..color = road);
    final p = Paint()
      ..color = dash
      ..strokeWidth = (axis == Axis.vertical ? size.width : size.height) * 0.28
      ..strokeCap = StrokeCap.round;
    const seg = 7.0, gap = 7.0;
    if (axis == Axis.vertical) {
      final x = size.width / 2;
      for (var y = 5.0; y + seg <= size.height - 4; y += seg + gap) {
        canvas.drawLine(Offset(x, y), Offset(x, y + seg), p);
      }
    } else {
      final y = size.height / 2;
      for (var x = 5.0; x + seg <= size.width - 4; x += seg + gap) {
        canvas.drawLine(Offset(x, y), Offset(x + seg, y), p);
      }
    }
  }

  @override
  bool shouldRepaint(_RoadPainter o) => o.road != road || o.dash != dash || o.axis != axis;
}

/// Section header: a short road piece, the title (never more than 2 lines) and an optional text action.
class RoadSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? action;
  final VoidCallback? onAction;
  const RoadSectionHeader(this.title, {super.key, this.subtitle, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    final a = action;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(padding: EdgeInsets.only(top: 4), child: RoadStripe(width: 22, height: 6, axis: Axis.horizontal)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(header: true, child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 18))),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label),
              ],
            ],
          ),
        ),
        if (a != null && onAction != null)
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(minimumSize: const Size(48, 40), padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: Text(a, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
    );
  }
}

/// A route drawn in a small box (no map): used on rider route cards. [points] are (lat, lng).
class RouteSparkline extends StatelessWidget {
  final List<(double, double)> points;
  final double height;
  final Color? color;
  const RouteSparkline({super.key, required this.points, this.height = 44, this.color});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox(height: height, child: CustomPaint(painter: _SparkPainter(points, color ?? AppTheme.primary), size: Size.infinite)),
      );
}

class _SparkPainter extends CustomPainter {
  final List<(double, double)> pts;
  final Color color;
  _SparkPainter(this.pts, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (pts.length < 2 || size.width <= 0 || size.height <= 0) return;
    var s = 90.0, n = -90.0, w = 180.0, e = -180.0;
    for (final p in pts) {
      if (p.$1 < s) s = p.$1;
      if (p.$1 > n) n = p.$1;
      if (p.$2 < w) w = p.$2;
      if (p.$2 > e) e = p.$2;
    }
    const pad = 6.0;
    final dx = (e - w).abs() < 1e-9 ? 1e-9 : e - w, dy = (n - s).abs() < 1e-9 ? 1e-9 : n - s;
    final k = ((size.width - 2 * pad) / dx) < ((size.height - 2 * pad) / dy) ? (size.width - 2 * pad) / dx : (size.height - 2 * pad) / dy;
    final ox = (size.width - dx * k) / 2, oy = (size.height - dy * k) / 2;
    Offset at((double, double) p) => Offset(ox + (p.$2 - w) * k, size.height - (oy + (p.$1 - s) * k));
    final path = Path()..moveTo(at(pts.first).dx, at(pts.first).dy);
    final step = pts.length > 200 ? (pts.length / 200).ceil() : 1;
    for (var i = step; i < pts.length; i += step) {
      final o = at(pts[i]);
      path.lineTo(o.dx, o.dy);
    }
    path.lineTo(at(pts.last).dx, at(pts.last).dy);
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round);
    canvas.drawCircle(at(pts.last), 4.5, Paint()..color = CoRouteBrand.amber);
  }

  @override
  bool shouldRepaint(_SparkPainter o) => o.pts != pts || o.color != color;
}
