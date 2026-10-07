import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'ui_format.dart';
import 'ui_tokens.dart';

/// "0.8 km ahead" / "350 m behind" with a direction arrow.
///
/// [ahead] true = ahead of me, false = behind me, null = side unknown
/// ("350 m away"). [warn] colours it as a warning (for example the rider
/// is too far behind); the text still says it, colour is only extra.
class DistanceIndicator extends StatelessWidget {
  final double meters;
  final bool? ahead;
  final bool warn;
  final TextStyle? style;

  const DistanceIndicator({
    super.key,
    required this.meters,
    this.ahead,
    this.warn = false,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final base = style ?? AppText.label;
    final color = warn ? StatusColors.warning : (base.color ?? AppTheme.textSecondary);
    final IconData icon = ahead == true
        ? Icons.arrow_upward_rounded
        : (ahead == false ? Icons.arrow_downward_rounded : Icons.near_me_rounded);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: Space.s4),
        Flexible(
          child: Text(
            describeDistance(meters, ahead: ahead),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base.copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
      ],
    );
  }
}
