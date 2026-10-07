import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../ui/ui_tokens.dart';

/// A flat card surface: opaque card colour, medium radius, hairline border,
/// no shadow and no translucency. The name is kept for the existing callers.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final Color? borderColor;
  final Color? backgroundColor;
  final VoidCallback? onTap;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Space.s16),
    this.borderRadius = Radii.md,
    this.borderColor,
    this.backgroundColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    final tap = onTap;
    return Material(
      color: backgroundColor ?? AppTheme.slateCard,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: borderColor ?? AppTheme.subtleBorder, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: tap == null
          ? Padding(padding: padding, child: child)
          : InkWell(onTap: tap, child: Padding(padding: padding, child: child)),
    );
  }
}
