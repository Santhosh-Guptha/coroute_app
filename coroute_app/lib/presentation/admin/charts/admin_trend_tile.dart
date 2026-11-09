import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../domain/analytics/chart_math.dart';
import 'admin_sparkline.dart';

/// A KPI tile with a trend: small label, big value, a ▲/▼ chip against the
/// previous period (green when it moved the good way, red when the bad way,
/// grey when flat or new) and a tiny sparkline. [note] replaces the chip
/// (for counts with nothing to compare, e.g. "2 this week").
class AdminTrendTile extends StatelessWidget {
  final String label;
  final String value;
  final num current;
  final num? previous;
  final List<num> spark;

  /// The period the arrow compares against, for screen readers ("previous 7 days").
  final String compareText;

  /// False when more is worse (SOS): an increase is shown in red.
  final bool upIsGood;
  final String? note;
  final Color? valueColor;

  /// Sparkline colour (primary by default; the SOS tile keeps it a quiet grey).
  final Color? sparkColor;
  final bool loading;

  const AdminTrendTile({
    super.key,
    required this.label,
    required this.value,
    required this.current,
    this.previous,
    this.spark = const [],
    this.compareText = 'previous period',
    this.upIsGood = true,
    this.note,
    this.valueColor,
    this.sparkColor,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.palette;
    final prev = previous;
    final change = prev == null ? null : formatChange(current, prev);
    final trend = prev == null ? Trend.flat : trendOf(percentChange(current, prev));
    final good = trend == Trend.flat ? null : ((trend == Trend.up) == upIsGood);
    final chipColor = good == null ? p.textMuted : (good ? p.success : p.danger);
    final n = note;
    final said = [
      '$label: $value',
      if (change != null && change != '—') '$change against the $compareText',
      ?n,
    ].join(', ');
    return Semantics(
      label: said,
      excludeSemantics: true,
      child: DsCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(loading ? '–' : value, maxLines: 1, style: AppText.metric.copyWith(fontSize: 28, color: valueColor)),
                  ),
                ),
                const SizedBox(width: 8),
                if (!loading && n != null)
                  Flexible(child: Text(n, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption))
                else if (!loading && change != null && change != '—')
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: chipColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                    child: Text(change, style: AppText.caption.copyWith(color: chipColor, fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            AdminSparkline(values: loading ? const [] : spark, height: 26, color: sparkColor),
          ],
        ),
      ),
    );
  }
}
