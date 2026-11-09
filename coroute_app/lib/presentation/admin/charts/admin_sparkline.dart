import 'package:flutter/material.dart';

import '../../../domain/analytics/chart_math.dart';
import 'admin_line_chart.dart';
import 'chart_style.dart';

/// A tiny trend line for a KPI tile: no axes, a very light fill, a dot on
/// the latest value. Draws in over 300 ms. Decorative (the tile says the
/// numbers), so it is hidden from screen readers.
class AdminSparkline extends StatefulWidget {
  final List<num> values;
  final double height;
  final Color? color;

  const AdminSparkline({super.key, required this.values, this.height = 28, this.color});

  @override
  State<AdminSparkline> createState() => _AdminSparklineState();
}

class _AdminSparklineState extends State<AdminSparkline> with SingleTickerProviderStateMixin, ChartAnimation {
  @override
  void didUpdateWidget(AdminSparkline old) {
    super.didUpdateWidget(old);
    if (sumOf(old.values) != sumOf(widget.values) || old.values.length != widget.values.length) replayChart();
  }

  @override
  Widget build(BuildContext context) {
    final s = ChartStyle.of(context);
    return ExcludeSemantics(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: AnimatedBuilder(
          animation: chartProgress,
          builder: (context, _) => CustomPaint(painter: _SparkPainter(widget.values, widget.color ?? s.main, s.other, chartProgress.value)),
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<num> values;
  final Color color;
  final Color flat;
  final double progress;

  _SparkPainter(this.values, this.color, this.flat, this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final n = values.length;
    if (n < 2) return;
    final hi = values.reduce((a, b) => a > b ? a : b);
    const pad = 3.0;
    final h = size.height - pad * 2;
    final w = size.width - pad * 2;
    if (hi <= 0) {
      // Nothing yet: one quiet baseline.
      canvas.drawLine(Offset(pad, size.height - pad), Offset(pad + w * progress, size.height - pad), Paint()
        ..color = flat
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round);
      return;
    }
    final pts = [for (var i = 0; i < n; i++) Offset(pad + w * i / (n - 1), pad + h - (values[i] / hi) * h)];
    final line = smoothPath(pts);
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, pad + (w + pad) * progress, size.height));
    final area = Path.from(line)
      ..lineTo(pts.last.dx, size.height)
      ..lineTo(pts.first.dx, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.10));
    canvas.drawPath(line, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);
    canvas.restore();
    if (progress >= 1) canvas.drawCircle(pts.last, 2.6, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.progress != progress || old.color != color || sumOf(old.values) != sumOf(values) || old.values.length != values.length;
}
