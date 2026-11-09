import 'package:flutter/material.dart';

import '../../../core/ui/ui.dart';
import '../../../domain/analytics/chart_math.dart';
import 'chart_style.dart';

/// One row of [AdminHorizontalBars].
class HBarItem {
  final String label;
  final num value;

  /// Draw this row in the main colour (the rest are muted grey).
  final bool highlight;

  const HBarItem(this.label, this.value, {this.highlight = true});
}

/// Labelled horizontal bars (a plan mix, top features): label and value on
/// one line, a thin rounded bar under it that grows in over 300 ms. Bars are
/// scaled to the largest value; [showShare] adds each row's share of the total.
/// Skeleton while [loading], [emptyText] when there is nothing to show.
class AdminHorizontalBars extends StatelessWidget {
  final List<HBarItem> items;
  final String title;
  final String unit;
  final bool showShare;
  final bool loading;
  final String emptyText;

  const AdminHorizontalBars({
    super.key,
    required this.items,
    required this.title,
    this.unit = '',
    this.showShare = true,
    this.loading = false,
    this.emptyText = 'Nothing yet',
  });

  @override
  Widget build(BuildContext context) {
    if (loading) return const ChartSkeleton(height: 120, bars: 6);
    final total = sumOf(items.map((e) => e.value));
    if (items.isEmpty || total <= 0) return ChartEmpty(height: 120, text: emptyText, icon: Icons.align_horizontal_left_rounded);
    final s = ChartStyle.of(context);
    final hi = items.map((e) => e.value).reduce((a, b) => a > b ? a : b);
    String share(num v) => '${(v / total * 100).round()}%';
    final summary = '$title: ${items.map((e) => '${e.label} ${compactNumber(e.value)}${showShare ? ' (${share(e.value)})' : ''}').join(', ')}';
    return Semantics(
      label: summary,
      container: true,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final it in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(it.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: s.text))),
                      const SizedBox(width: 8),
                      Text(
                        compactNumber(it.value),
                        style: AppText.label.copyWith(color: s.text, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                      if (showShare) ...[
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 40,
                          child: Text(share(it.value), textAlign: TextAlign.end, style: AppText.caption.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: hi <= 0 ? 0 : it.value / hi),
                    duration: chartAnimDuration,
                    curve: chartAnimCurve,
                    builder: (context, f, _) => ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        height: 8,
                        color: s.skeleton,
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: f.clamp(0.0, 1.0),
                          heightFactor: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(color: it.highlight ? s.main : s.other, borderRadius: BorderRadius.circular(4)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
