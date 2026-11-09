import 'package:flutter/material.dart';

import '../../../domain/analytics/chart_math.dart';
import 'admin_bar_chart.dart';
import 'chart_style.dart';

/// A line chart: the series in primary teal over a very light area fill, and
/// optionally the previous period as a thin dashed amber line to compare. The
/// line draws in from the left over 300 ms. Tap, drag or hover for the value,
/// the date and the previous period's value. Skeleton while [loading],
/// [emptyText] when every value is 0, one summary line for screen readers.
class AdminLineChart extends StatefulWidget {
  final List<num> values;

  /// The same days one period earlier (same length as [values]), or null.
  final List<num>? previous;
  final List<String> labels;
  final String title;
  final String period;
  final String unit;
  final String emptyText;
  final bool loading;
  final double height;
  final ChartValueFormat format;

  const AdminLineChart({
    super.key,
    required this.values,
    this.previous,
    required this.labels,
    required this.title,
    required this.period,
    this.unit = '',
    this.emptyText = 'Nothing yet',
    this.loading = false,
    this.height = 180,
    this.format = compactNumber,
  });

  @override
  State<AdminLineChart> createState() => _AdminLineChartState();
}

class _AdminLineChartState extends State<AdminLineChart> with SingleTickerProviderStateMixin, ChartAnimation {
  int? _selected;

  List<num>? get _prev {
    final p = widget.previous;
    return p != null && p.length == widget.values.length && peakOf(p) != null ? p : null;
  }

  @override
  void didUpdateWidget(AdminLineChart old) {
    super.didUpdateWidget(old);
    if (old.values.length != widget.values.length || old.loading != widget.loading || !_listEq(old.values, widget.values)) {
      _selected = null;
      replayChart();
    }
  }

  void _pick(Offset p, Size size) {
    final plot = LineChartPainter.plotRect(size, widget.values, _prev, widget.format, ChartStyle.of(context));
    if (!plot.inflate(6).contains(p)) {
      setState(() => _selected = null);
      return;
    }
    setState(() => _selected = nearestPoint(p.dx - plot.left, plot.width, widget.values.length));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) return ChartSkeleton(height: widget.height, bars: 14);
    if (peakOf(widget.values) == null && _prev == null) return ChartEmpty(height: widget.height, text: widget.emptyText, icon: Icons.show_chart_rounded);
    final style = ChartStyle.of(context);
    final summary = chartSummary(title: widget.title, period: widget.period, values: widget.values, labels: widget.labels, unit: widget.unit);
    final prev = _prev;
    final prevText = prev == null ? '' : ', previous period ${compactNumber(sumOf(prev))} in total against ${compactNumber(sumOf(widget.values))}';
    return Semantics(
      label: '$summary$prevText',
      container: true,
      excludeSemantics: true,
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(builder: (context, c) {
          final size = Size(c.maxWidth, widget.height);
          return MouseRegion(
            onHover: (e) => _pick(e.localPosition, size),
            onExit: (_) => setState(() => _selected = null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _pick(d.localPosition, size),
              onHorizontalDragUpdate: (d) => _pick(d.localPosition, size),
              child: AnimatedBuilder(
                animation: chartProgress,
                builder: (context, _) => CustomPaint(
                  size: size,
                  painter: LineChartPainter(
                    values: widget.values,
                    previous: prev,
                    labels: widget.labels,
                    style: style,
                    progress: chartProgress.value,
                    selected: _selected,
                    unit: widget.unit,
                    format: widget.format,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

bool _listEq(List<num>? a, List<num>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Smooth-ish path through [pts] (monotone-friendly: control points at the horizontal midpoints).
Path smoothPath(List<Offset> pts) {
  final path = Path();
  if (pts.isEmpty) return path;
  path.moveTo(pts.first.dx, pts.first.dy);
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final mx = (a.dx + b.dx) / 2;
    path.cubicTo(mx, a.dy, mx, b.dy, b.dx, b.dy);
  }
  return path;
}

class LineChartPainter extends CustomPainter {
  final List<num> values;
  final List<num>? previous;
  final List<String> labels;
  final ChartStyle style;
  final double progress;
  final int? selected;
  final String unit;
  final ChartValueFormat format;

  LineChartPainter({
    required this.values,
    required this.previous,
    required this.labels,
    required this.style,
    required this.progress,
    required this.selected,
    required this.unit,
    required this.format,
  });

  static NiceScale scaleFor(List<num> values, List<num>? previous) {
    final all = [...values, ...?previous];
    final hi = all.isEmpty ? 0 : all.reduce((a, b) => a > b ? a : b);
    return niceScale(hi, integers: all.every((v) => v == v.roundToDouble()));
  }

  static Rect plotRect(Size size, List<num> values, List<num>? previous, ChartValueFormat format, ChartStyle s) {
    var w = 0.0;
    for (final t in scaleFor(values, previous).ticks) {
      final tp = TextPainter(text: TextSpan(text: format(t), style: s.axis()), textDirection: TextDirection.ltr)..layout();
      if (tp.width > w) w = tp.width;
    }
    return Rect.fromLTRB(w + 8, 10, size.width - 4, size.height - 22);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = values.length;
    if (n == 0) return;
    final scale = scaleFor(values, previous);
    final plot = plotRect(size, values, previous, format, style);
    double x(int i) => n == 1 ? plot.center.dx : plot.left + plot.width * i / (n - 1);
    double y(num v) => plot.bottom - scale.fraction(v) * plot.height;
    final xs = [for (var i = 0; i < n; i++) x(i)];
    paintAxes(canvas, plot, scale, style, format, labels, xs);

    // Reveal from the left as the animation runs.
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, plot.left + (plot.width + 6) * progress, size.height));

    final prev = previous;
    if (prev != null) {
      final pp = smoothPath([for (var i = 0; i < n; i++) Offset(xs[i], y(prev[i]))]);
      final dash = Paint()
        ..color = style.compare.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      for (final m in pp.computeMetrics()) {
        for (var d = 0.0; d < m.length; d += 9) {
          canvas.drawPath(m.extractPath(d, (d + 4.5).clamp(0, m.length).toDouble()), dash);
        }
      }
    }

    final pts = [for (var i = 0; i < n; i++) Offset(xs[i], y(values[i]))];
    final line = smoothPath(pts);
    final area = Path.from(line)
      ..lineTo(pts.last.dx, plot.bottom)
      ..lineTo(pts.first.dx, plot.bottom)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [style.main.withValues(alpha: 0.14), style.main.withValues(alpha: 0.0)],
        ).createShader(plot),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = style.main
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();

    final sel = selected;
    if (sel != null && sel >= 0 && sel < n && progress >= 1) {
      final p = pts[sel];
      canvas.drawLine(Offset(p.dx, plot.top), Offset(p.dx, plot.bottom), Paint()
        ..color = style.grid
        ..strokeWidth = 1);
      canvas.drawCircle(p, 5, Paint()..color = style.surface);
      canvas.drawCircle(p, 5, Paint()
        ..color = style.main
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
      final u = unit.isEmpty ? '' : ' $unit';
      final day = sel < labels.length ? shortDay(labels[sel]) : '';
      final before = prev == null ? '' : ' · before ${format(prev[sel])}';
      paintChartTooltip(canvas, Offset.zero & size, p, style, '${format(values[sel])}$u', '$day$before');
    } else if (progress >= 1) {
      // The latest point, so "now" is easy to find.
      final p = pts.last;
      canvas.drawCircle(p, 3.5, Paint()..color = style.main);
    }
  }

  @override
  bool shouldRepaint(LineChartPainter old) =>
      old.progress != progress || old.selected != selected || old.style != style || !_listEq(old.values, values) || !_listEq(old.previous, previous);
}
