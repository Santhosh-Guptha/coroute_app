import 'package:flutter/material.dart';
import 'ui_tokens.dart';

/// A big number with its unit and a short label under it:
///
///     186 km
///     Remaining
///
/// The number scales down (never wraps, never overflows) when space is
/// tight, for example 4 metrics in a row on a 320 dp phone at large text.
/// [emphasis] makes the number full metric size; otherwise it is a step
/// smaller so a row of metrics stays calm.
class RideMetric extends StatelessWidget {
  final String value;
  final String? unit;
  final String label;
  final bool emphasis;

  /// Colour of the number (for example a status colour). Defaults to text colour.
  final Color? color;

  /// Start (left) or center alignment.
  final CrossAxisAlignment alignment;

  const RideMetric({
    super.key,
    required this.value,
    this.unit,
    required this.label,
    this.emphasis = false,
    this.color,
    this.alignment = CrossAxisAlignment.start,
  });

  @override
  Widget build(BuildContext context) {
    final big = AppText.metric.copyWith(fontSize: emphasis ? 32 : 24, color: color);
    final small = AppText.label.copyWith(fontSize: emphasis ? 15 : 13);
    final u = unit;
    final centered = alignment == CrossAxisAlignment.center;
    final semantic = u == null || u.isEmpty ? '$label: $value' : '$label: $value $u';
    return Semantics(
      container: true,
      label: semantic,
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: alignment,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: centered ? Alignment.center : AlignmentDirectional.centerStart,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: value, style: big),
                  if (u != null && u.isNotEmpty) TextSpan(text: ' $u', style: small),
                ],
              ),
              maxLines: 1,
              softWrap: false,
            ),
          ),
          const SizedBox(height: Space.s4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: centered ? TextAlign.center : TextAlign.start,
            style: AppText.caption,
          ),
        ],
      ),
    );
  }
}
