import 'package:flutter/material.dart';

import '../../../domain/analytics/chart_math.dart';
import 'chart_style.dart';

/// Formats a value for an axis or tooltip ("1.2k", "42").
typedef ChartValueFormat = String Function(num v);

/// A vertical bar chart (one series, primary teal): faint gridlines, 3-5 nice
/// ticks, the first / middle / last date under it, bars that grow in over
/// 300 ms. Tap, drag or hover a bar for its value and date. Shows a skeleton
/// while [loading] and [emptyText] when every value is 0. Screen readers get
/// one summary line ("Rides per day, last 30 days, peak 42 on 3 Nov").
class AdminBarChart extends StatefulWidget {
  final List<num> values;

  /// One per value: an ISO day ("2026-11-03", shown as "3 Nov") or any short text.
  final List<String> labels;
  final String title;

  /// The period in words for the summary ("last 30 days").
  final String period;

  /// Unit after the value in the tooltip ("rides").
  final String unit;
  final String emptyText;
  final bool loading;
  final double height;
  final ChartValueFormat format;

  const AdminBarChart({
    super.key,
    required this.values,
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
  State<AdminBarChart> createState() => _AdminBarChartState();
}

class _AdminBarChartState extends State<AdminBarChart> with SingleTickerProviderStateMixin, ChartAnimation {
  int? _selected;

  @override
  void didUpdateWidget(AdminBarChart old) {
    super.didUpdateWidget(old);
    if (old.values.length != widget.values.length || old.loading != widget.loading || !_same(old.values, widget.values)) {
      _selected = null;
      replayChart();
    }
  }

  void _pick(Offset p, Size size, {bool toggle = false}) {
    final plot = BarChartPainter.plotRect(size, widget.values, widget.format, ChartStyle.of(context));
    if (!plot.inflate(4).contains(p)) {
      setState(() => _selected = null);
      return;
    }
    final i = indexAt(p.dx - plot.left, plot.width, widget.values.length);
    setState(() => _selected = toggle && _selected == i ? null : i);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) return ChartSkeleton(height: widget.height, bars: 14);
    if (peakOf(widget.values) == null) return ChartEmpty(height: widget.height, text: widget.emptyText);
    final style = ChartStyle.of(context);
    final summary = chartSummary(title: widget.title, period: widget.period, values: widget.values, labels: widget.labels, unit: widget.unit);
    return Semantics(
      label: summary,
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
              onTapDown: (d) => _pick(d.localPosition, size, toggle: true),
              onHorizontalDragUpdate: (d) => _pick(d.localPosition, size),
              child: AnimatedBuilder(
                animation: chartProgress,
                builder: (context, _) => CustomPaint(
                  size: size,
                  painter: BarChartPainter(
                    values: widget.values,
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

bool _same(List<num> a, List<num> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Width of the y-axis labels for [scale].
double _axisWidth(NiceScale scale, ChartValueFormat format, ChartStyle s) {
  var w = 0.0;
  for (final t in scale.ticks) {
    final tp = TextPainter(text: TextSpan(text: format(t), style: s.axis()), textDirection: TextDirection.ltr)..layout();
    if (tp.width > w) w = tp.width;
  }
  return w + 8;
}

/// Draws the faint gridlines with their tick labels, and the first / middle / last x label.
void paintAxes(Canvas canvas, Rect plot, NiceScale scale, ChartStyle s, ChartValueFormat format, List<String> labels, List<double> xs) {
  final grid = Paint()
    ..color = s.grid
    ..strokeWidth = 1;
  for (final t in scale.ticks) {
    final y = plot.bottom - scale.fraction(t) * plot.height;
    canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
    final tp = TextPainter(text: TextSpan(text: format(t), style: s.axis()), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, Offset(plot.left - tp.width - 8, y - tp.height / 2));
  }
  if (labels.isEmpty || xs.isEmpty) return;
  final picks = <int>{0, if (xs.length > 2) (xs.length - 1) ~/ 2, xs.length - 1};
  for (final i in picks) {
    if (i >= labels.length) continue;
    final tp = TextPainter(text: TextSpan(text: shortDay(labels[i]), style: s.axis()), textDirection: TextDirection.ltr, maxLines: 1)..layout(maxWidth: 90);
    var x = xs[i] - tp.width / 2;
    if (i == 0) x = (plot.left).clamp(0, double.infinity).toDouble();
    if (i == xs.length - 1) x = plot.right - tp.width;
    tp.paint(canvas, Offset(x, plot.bottom + 6));
  }
}

class BarChartPainter extends CustomPainter {
  final List<num> values;
  final List<String> labels;
  final ChartStyle style;
  final double progress;
  final int? selected;
  final String unit;
  final ChartValueFormat format;

  BarChartPainter({
    required this.values,
    required this.labels,
    required this.style,
    required this.progress,
    required this.selected,
    required this.unit,
    required this.format,
  });

  static const double _top = 10, _bottom = 22;

  static NiceScale scaleFor(List<num> values) => niceScale(values.isEmpty ? 0 : values.reduce((a, b) => a > b ? a : b), integers: values.every((v) => v == v.roundToDouble()));

  /// The plot area inside [size] (room for the y labels at the left and the dates under it).
  static Rect plotRect(Size size, List<num> values, ChartValueFormat format, ChartStyle s) {
    final left = _axisWidth(scaleFor(values), format, s);
    return Rect.fromLTRB(left, _top, size.width, size.height - _bottom);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final scale = scaleFor(values);
    final plot = plotRect(size, values, format, style);
    final n = values.length;
    final slot = plot.width / n;
    final barW = (slot * (n > 40 ? 0.7 : 0.6)).clamp(1.5, 22.0).toDouble();
    final xs = [for (var i = 0; i < n; i++) plot.left + slot * (i + 0.5)];
    paintAxes(canvas, plot, scale, style, format, labels, xs);

    final hasSel = selected != null && selected! >= 0 && selected! < n;
    for (var i = 0; i < n; i++) {
      final v = values[i];
      if (v <= 0) continue;
      final h = scale.fraction(v) * plot.height * progress;
      final r = Rect.fromLTWH(xs[i] - barW / 2, plot.bottom - h, barW, h);
      final radius = Radius.circular((barW / 2).clamp(0, 4).toDouble());
      final c = !hasSel || i == selected ? style.main : style.main.withValues(alpha: 0.35);
      canvas.drawRRect(RRect.fromRectAndCorners(r, topLeft: radius, topRight: radius), Paint()..color = c);
    }
    if (hasSel && progress >= 1) {
      final i = selected!;
      final v = values[i];
      final y = plot.bottom - scale.fraction(v) * plot.height;
      final label = i < labels.length ? shortDay(labels[i]) : '';
      paintChartTooltip(canvas, Offset.zero & size, Offset(xs[i], y), style, '${format(v)}${unit.isEmpty ? '' : ' $unit'}', label);
    }
  }

  @override
  bool shouldRepaint(BarChartPainter old) =>
      old.progress != progress || old.selected != selected || old.style != style || !_same(old.values, values) || old.labels.length != labels.length;
}
