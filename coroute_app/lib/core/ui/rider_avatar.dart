import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'rider_status.dart';
import 'ui_format.dart';

/// A rider's initials in a circle, with a small status dot.
///
/// Static (no animation). Screen readers hear "Name, Status". At [size] 44
/// and above the dot also carries the status icon; below that, show the
/// status as text next to the avatar (for example a [RiderStatusChip]).
/// With [onTap] the touch area grows to at least 48 x 48.
class RiderAvatar extends StatelessWidget {
  final String name;

  /// The rider's colour (usually from MemberColors). Defaults to the primary colour.
  final Color? color;
  final RiderStatus? status;
  final double size;
  final VoidCallback? onTap;

  const RiderAvatar({
    super.key,
    required this.name,
    this.color,
    this.status,
    this.size = 40,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.neonCyan;
    final s = status;
    final dot = (size * 0.32).clamp(10.0, 18.0).toDouble();
    final avatar = SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color.alphaBlend(c.withOpacity(0.18), AppTheme.slateCard),
                border: Border.all(color: c, width: 2),
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      initialsOf(name),
                      maxLines: 1,
                      softWrap: false,
                      textScaler: TextScaler.noScaling,
                      style: TextStyle(
                        color: c,
                        fontSize: math.max(11.0, size * 0.36),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (s != null)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: dot,
                height: dot,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: s.color,
                  border: Border.all(color: AppTheme.slateCard, width: 2),
                ),
                child: dot >= 14 ? Icon(s.icon, size: dot - 6, color: AppTheme.slateCard) : null,
              ),
            ),
        ],
      ),
    );

    final label = s == null ? name : '$name, ${s.label}';
    final tap = onTap;
    if (tap == null) {
      return Semantics(container: true, label: label, excludeSemantics: true, child: avatar);
    }
    return Semantics(
      container: true,
      label: label,
      button: true,
      excludeSemantics: true,
      onTap: tap,
      child: GestureDetector(
        onTap: tap,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Center(widthFactor: 1, heightFactor: 1, child: avatar),
        ),
      ),
    );
  }
}
