import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';

/// Colours and text of the admin charts, read from the theme tokens so they follow
/// light and dark. At most three colours per chart: [main] (primary teal) for the
/// series, [compare] (warm amber) for a comparison, [other] (muted grey) for the rest.
@immutable
class ChartStyle {
  final Color main;
  final Color compare;
  final Color other;
  final Color grid;
  final Color axisText;
  final Color text;
  final Color surface;
  final Color border;
  final Color skeleton;
  final Color shadow;
  final String? fontFamily;

  const ChartStyle({
    required this.main,
    required this.compare,
    required this.other,
    required this.grid,
    required this.axisText,
    required this.text,
    required this.surface,
    required this.border,
    required this.skeleton,
    required this.shadow,
    this.fontFamily,
  });

  factory ChartStyle.of(BuildContext context) {
    final p = AppTheme.palette;
    return ChartStyle(
      main: p.primary,
      compare: p.accent,
      other: p.textFaint,
      // Gridlines very faint: a hairline of the border colour, half strength.
      grid: p.border.withValues(alpha: 0.7),
      axisText: p.textMuted,
      text: p.text,
      surface: p.surface,
      border: p.border,
      skeleton: p.surfaceAlt,
      shadow: p.shadow,
      fontFamily: AppTheme.fontFamily,
    );
  }

  TextStyle axis() => TextStyle(color: axisText, fontSize: 12, fontWeight: FontWeight.w500, height: 1.2, fontFamily: fontFamily, fontFeatures: const [FontFeature.tabularFigures()]);
  TextStyle tipValue() => TextStyle(color: text, fontSize: 13, fontWeight: FontWeight.w600, height: 1.25, fontFamily: fontFamily, fontFeatures: const [FontFeature.tabularFigures()]);
  TextStyle tipLabel() => TextStyle(color: axisText, fontSize: 12, fontWeight: FontWeight.w500, height: 1.25, fontFamily: fontFamily);

  @override
  bool operator ==(Object other) =>
      other is ChartStyle && other.main == main && other.compare == compare && other.grid == grid && other.text == text && other.surface == surface && other.other == this.other;

  @override
  int get hashCode => Object.hash(main, compare, other, grid, text, surface);
}

/// The one load-in animation of the charts: 300 ms, ease out.
const Duration chartAnimDuration = Duration(milliseconds: 300);
const Curve chartAnimCurve = Curves.easeOut;

/// Draws a small tooltip card (value on top, label under it) above [anchor], kept inside [bounds].
void paintChartTooltip(Canvas canvas, Rect bounds, Offset anchor, ChartStyle s, String value, String label) {
  final v = TextPainter(text: TextSpan(text: value, style: s.tipValue()), textDirection: TextDirection.ltr, maxLines: 1)..layout(maxWidth: 220);
  final l = TextPainter(text: TextSpan(text: label, style: s.tipLabel()), textDirection: TextDirection.ltr, maxLines: 1)..layout(maxWidth: 220);
  const padH = 10.0, padV = 7.0, gap = 2.0;
  final w = (v.width > l.width ? v.width : l.width) + padH * 2;
  final h = v.height + gap + l.height + padV * 2;
  var left = anchor.dx - w / 2;
  left = left.clamp(bounds.left, (bounds.right - w).clamp(bounds.left, double.infinity)).toDouble();
  var top = anchor.dy - h - 10;
  if (top < bounds.top) top = (anchor.dy + 12).clamp(bounds.top, (bounds.bottom - h).clamp(bounds.top, double.infinity)).toDouble();
  final r = RRect.fromRectAndRadius(Rect.fromLTWH(left, top, w, h), const Radius.circular(10));
  canvas.drawRRect(r.shift(const Offset(0, 2)), Paint()..color = s.shadow..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
  canvas.drawRRect(r, Paint()..color = s.surface);
  canvas.drawRRect(r, Paint()..color = s.border..style = PaintingStyle.stroke..strokeWidth = 1);
  v.paint(canvas, Offset(left + padH, top + padV));
  l.paint(canvas, Offset(left + padH, top + padV + v.height + gap));
}

/// A calm placeholder while a chart loads: soft blocks in the skeleton colour, no shimmer.
class ChartSkeleton extends StatelessWidget {
  final double height;
  final int bars;

  const ChartSkeleton({super.key, required this.height, this.bars = 12});

  @override
  Widget build(BuildContext context) {
    final s = ChartStyle.of(context);
    return Semantics(
      label: 'Loading chart',
      child: SizedBox(
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < bars; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: FractionallySizedBox(
                  heightFactor: 0.25 + 0.6 * (((i * 7) % 10) / 10),
                  child: DecoratedBox(decoration: BoxDecoration(color: s.skeleton, borderRadius: BorderRadius.circular(4))),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What a chart shows when there is nothing to draw: one quiet icon and a short line.
class ChartEmpty extends StatelessWidget {
  final double height;
  final String text;
  final IconData icon;

  const ChartEmpty({super.key, required this.height, required this.text, this.icon = Icons.bar_chart_rounded});

  @override
  Widget build(BuildContext context) {
    final s = ChartStyle.of(context);
    return SizedBox(
      height: height,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: s.other),
            const SizedBox(height: 6),
            Text(text, textAlign: TextAlign.center, style: AppText.label),
          ],
        ),
      ),
    );
  }
}

/// Runs the 300 ms load-in the first time the chart is drawn, and again on [replayChart]
/// (new data). The controller is made lazily, so a chart that only ever shows its
/// skeleton or empty state never starts a ticker.
mixin ChartAnimation<T extends StatefulWidget> on State<T>, SingleTickerProviderStateMixin<T> {
  AnimationController? _chartController;
  Animation<double>? _chartProgress;

  Animation<double> get chartProgress {
    var p = _chartProgress;
    if (p == null) {
      final c = _chartController = AnimationController(vsync: this, duration: chartAnimDuration)..forward();
      p = _chartProgress = CurvedAnimation(parent: c, curve: chartAnimCurve);
    }
    return p;
  }

  void replayChart() => _chartController?.forward(from: 0);

  @override
  void dispose() {
    _chartController?.dispose();
    super.dispose();
  }
}
