import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../ui/ui_tokens.dart';

/// A flat card surface: opaque card colour, 18 px radius, 2 px border,
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
    this.borderRadius = Radii.lg,
    this.borderColor,
    this.backgroundColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    final tap = onTap;
    return Material(
      color: backgroundColor ?? AppTheme.card,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: borderColor ?? AppTheme.border, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: tap == null
          ? Padding(padding: padding, child: child)
          : InkWell(onTap: tap, child: Padding(padding: padding, child: child)),
    );
  }
}
