import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'ui_tokens.dart';

/// Building blocks of the CoRoute design canvas (Manrope + teal).
///
/// Every screen restyled after the canvas is composed from these so the
/// corners, borders, weights and colours stay identical across the app.
/// Colours come from [AppTheme] getters, so light and dark both work.

/// A white (or dark) card with a 2 px hairline border and 18 px corners.
/// [accent] draws the teal border used for the "selected / best" state,
/// [warning] the amber one, [tinted] fills the card with the pale teal tint.
class DsCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool accent;
  final bool warning;
  final bool tinted;
  final bool dashed;
  final Color? color;
  final Color? borderColor;
  final VoidCallback? onTap;
  final String? semanticsLabel;

  const DsCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = Radii.lg,
    this.accent = false,
    this.warning = false,
    this.tinted = false,
    this.dashed = false,
    this.color,
    this.borderColor,
    this.onTap,
    this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    final bg = color ?? (tinted ? AppTheme.tint : AppTheme.card);
    final border = borderColor ??
        (accent
            ? AppTheme.accentText
            : warning
                ? AppTheme.warnBorder
                : AppTheme.border);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: border, width: 2, style: dashed ? BorderStyle.none : BorderStyle.solid),
    );
    Widget body = Padding(padding: padding, child: child);
    if (dashed) {
      body = CustomPaint(
        foregroundPainter: _DashedBorderPainter(color: AppTheme.border2, radius: radius),
        child: body,
      );
    }
    final card = Material(
      color: bg,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? body : InkWell(onTap: onTap, child: body),
    );
    if (semanticsLabel == null) return card;
    return Semantics(label: semanticsLabel, button: onTap != null, child: card);
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;
  _DashedBorderPainter({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)).deflate(1);
    final path = Path()..addRRect(rrect);
    const dash = 6.0, gap = 5.0;
    for (final metric in path.computeMetrics()) {
      double d = 0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color || old.radius != radius;
}

/// Solid teal hero card with white text (next ride, convoy spread, …).
class DsHeroCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const DsHeroCard({super.key, required this.child, this.padding = const EdgeInsets.all(22)});

  /// Pale teal used for overlines on the hero card.
  static const Color overline = Color(0xFFB7E3E8);

  /// Secondary text on the hero card.
  static const Color secondary = Color(0xFFD6F0F3);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.brand,
      shape: const RoundedRectangleBorder(borderRadius: Radii.xlAll),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding,
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Colors.white),
          child: IconTheme.merge(data: const IconThemeData(color: Colors.white), child: child),
        ),
      ),
    );
  }
}

/// Small uppercase section header ("BIKE STATUS").
class DsSectionHeader extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const DsSectionHeader(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final label = Text(text.toUpperCase(), style: AppText.overline);
    if (trailing == null) return label;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [label, trailing!],
    );
  }
}

/// Screen header: optional round back button, title and subtitle.
class DsScreenHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final String backLabel;
  final Widget? trailing;

  const DsScreenHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onBack,
    this.backLabel = 'Back',
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (onBack != null) ...[
          DsRoundButton(icon: Icons.chevron_left_rounded, label: backLabel, onTap: onBack!),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppText.headline, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (subtitle != null) ...[
                const SizedBox(height: 1),
                Text(subtitle!, style: AppText.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// 44 px round icon button on a card with a hairline border.
class DsRoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double size;
  final Color? iconColor;
  final Color? borderColor;
  final Color? background;
  final double borderWidth;

  const DsRoundButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.size = 44,
    this.iconColor,
    this.borderColor,
    this.background,
    this.borderWidth = 2,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: Material(
        color: background ?? AppTheme.card,
        shape: CircleBorder(side: BorderSide(color: borderColor ?? AppTheme.border, width: borderWidth)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, size: size * 0.5, color: iconColor ?? AppTheme.text),
          ),
        ),
      ),
    );
  }
}

/// Full-width solid button. [tone] picks brand teal (default), SOS red,
/// white-on-teal (inside a hero card) or outlined.
enum DsButtonTone { brand, sos, onHero, outline, warn }

class DsButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final DsButtonTone tone;
  final double height;
  final double fontSize;

  const DsButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.tone = DsButtonTone.brand,
    this.height = 56,
    this.fontSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    Color bg, fg;
    BorderSide side = BorderSide.none;
    switch (tone) {
      case DsButtonTone.brand:
        bg = AppTheme.brand;
        fg = Colors.white;
      case DsButtonTone.sos:
        bg = AppTheme.sos;
        fg = Colors.white;
      case DsButtonTone.onHero:
        bg = AppTheme.card;
        fg = AppTheme.accentText;
      case DsButtonTone.warn:
        bg = AppTheme.warnText;
        fg = Colors.white;
      case DsButtonTone.outline:
        bg = AppTheme.card;
        fg = AppTheme.text;
        side = BorderSide(color: AppTheme.border, width: 2);
    }
    return SizedBox(
      height: height,
      child: Material(
        color: onPressed == null ? bg.withValues(alpha: 0.5) : bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: side),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: fontSize + 6, color: fg),
                  const SizedBox(width: 10),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: fg, fontSize: fontSize, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small rounded label chip ("LEAD", "BEST", "REGROUP").
class DsChip extends StatelessWidget {
  final String text;
  final bool warning;
  final bool inverse;
  final Color? color;
  final Color? background;

  const DsChip(this.text, {super.key, this.warning = false, this.inverse = false, this.color, this.background});

  @override
  Widget build(BuildContext context) {
    final fg = color ??
        (inverse
            ? Colors.white
            : warning
                ? AppTheme.warnText
                : AppTheme.accentText);
    final bg = background ??
        (inverse
            ? AppTheme.text
            : warning
                ? AppTheme.warnTint
                : AppTheme.tint);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(7)),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1),
      ),
    );
  }
}

/// Square icon tile on a soft fill, used in docks and quick-access grids.
class DsIconTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? iconColor;
  final Color? background;
  final Color? foreground;
  final double height;
  final double iconSize;
  final double fontSize;

  const DsIconTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor,
    this.background,
    this.foreground,
    this.height = 64,
    this.iconSize = 22,
    this.fontSize = 11,
  });

  @override
  Widget build(BuildContext context) {
    final fg = foreground ?? AppTheme.text;
    return SizedBox(
      height: height,
      child: Material(
        color: background ?? AppTheme.soft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: iconSize, color: iconColor ?? AppTheme.accentText),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: fg, fontSize: fontSize, fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Initials in a circle. Outlined (teal ring) by default, [filled] for the
/// solid teal "you" avatar, [warning] for an amber ring.
class DsAvatar extends StatelessWidget {
  final String initials;
  final double size;
  final bool filled;
  final bool warning;
  final Color? ringColor;
  final Color? background;

  const DsAvatar(this.initials, {super.key, this.size = 44, this.filled = false, this.warning = false, this.ringColor, this.background});

  @override
  Widget build(BuildContext context) {
    final ring = ringColor ?? (warning ? AppTheme.warnText : AppTheme.accentText);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? AppTheme.brand : (background ?? AppTheme.card),
        border: filled ? Border.all(color: AppTheme.card, width: size >= 52 ? 4 : 2) : Border.all(color: ring, width: size >= 44 ? 3 : 2),
      ),
      child: Text(
        initials.toUpperCase(),
        maxLines: 1,
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          color: filled ? Colors.white : ring,
          fontSize: size * 0.32,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// A row inside a [DsCard] list: leading icon, label, trailing value.
class DsListRow extends StatelessWidget {
  final IconData? icon;
  final String label;
  final String? value;
  final Widget? trailing;
  final bool divider;
  final VoidCallback? onTap;
  final Color? valueColor;

  const DsListRow({
    super.key,
    this.icon,
    required this.label,
    this.value,
    this.trailing,
    this.divider = true,
    this.onTap,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final row = Container(
      constraints: const BoxConstraints(minHeight: 52),
      decoration: BoxDecoration(
        border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null,
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 22, color: AppTheme.accentText),
            const SizedBox(width: 12),
          ],
          Expanded(child: Text(label, style: AppText.body.copyWith(fontWeight: FontWeight.w700))),
          if (value != null)
            Text(value!, style: AppText.body.copyWith(fontWeight: FontWeight.w800, color: valueColor ?? AppTheme.accentText)),
          if (trailing != null) trailing!,
          if (onTap != null) Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

/// Switch row used in settings sheets.
class DsSwitchRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool divider;
  final String? subtitle;

  const DsSwitchRow({super.key, required this.label, required this.value, required this.onChanged, this.divider = true, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 58),
      decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.body.copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
                if (subtitle != null) Text(subtitle!, style: AppText.caption),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// Three-up stat cell on a soft fill ("Left · 82 km").
class DsStatCell extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const DsStatCell({super.key, required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppTheme.bg, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.caption.copyWith(fontSize: 11, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: AppText.title.copyWith(fontSize: 20, color: valueColor)),
          ),
        ],
      ),
    );
  }
}

/// Segmented choice (Convoy · 3 / Lead only).
class DsSegment<T> extends StatelessWidget {
  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onChanged;
  const DsSegment({super.key, required this.values, required this.selected, required this.label, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < values.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 52,
              child: Material(
                color: values[i] == selected ? AppTheme.brand : AppTheme.card,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: values[i] == selected ? AppTheme.brand : AppTheme.border, width: 2),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onChanged(values[i]),
                  child: Center(
                    child: Text(
                      label(values[i]),
                      style: TextStyle(
                        color: values[i] == selected ? Colors.white : AppTheme.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Progress track (fuel range, trip progress) — 14 px, teal on map tint.
class DsProgressBar extends StatelessWidget {
  final double value;
  final Color? color;
  final double height;
  const DsProgressBar({super.key, required this.value, this.color, this.height = 14});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: AppTheme.map)),
            FractionallySizedBox(
              widthFactor: value.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(color: color ?? AppTheme.brand, borderRadius: BorderRadius.circular(height / 2)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Soft shadow used under floating cards on the map.
List<BoxShadow> dsFloatingShadow() => [
      BoxShadow(color: AppTheme.shadow.withValues(alpha: AppTheme.isLight ? 0.14 : 0.5), blurRadius: 24, offset: const Offset(0, 8)),
    ];

/// Standard screen padding from the canvas (56 top handled by SafeArea).
const EdgeInsets dsScreenPadding = EdgeInsets.fromLTRB(20, 16, 20, 28);
