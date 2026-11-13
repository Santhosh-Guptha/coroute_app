import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'adaptive_spec.dart';

export 'adaptive_spec.dart';

/// What a screen needs to know to lay itself out: the window class, gutters,
/// text scale, orientation, safe areas. `final a = Adaptive.of(context);`
/// docs/features_355/motion_and_loading.md
class Adaptive {
  final Size size;
  final double textScale;
  final EdgeInsets safe;
  final EdgeInsets viewInsets;

  const Adaptive({required this.size, this.textScale = 1, this.safe = EdgeInsets.zero, this.viewInsets = EdgeInsets.zero});

  factory Adaptive.of(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Adaptive(
      size: mq.size,
      textScale: AdaptiveSpec.clampTextScale(mq.textScaler.scale(100) / 100),
      safe: mq.padding,
      viewInsets: mq.viewInsets,
    );
  }

  /// From the space a widget really has (inside a pane or a sheet).
  factory Adaptive.fromConstraints(BuildContext context, BoxConstraints box) {
    final a = Adaptive.of(context);
    return Adaptive(
      size: Size(box.hasBoundedWidth ? box.maxWidth : a.size.width, box.hasBoundedHeight ? box.maxHeight : a.size.height),
      textScale: a.textScale,
      safe: a.safe,
      viewInsets: a.viewInsets,
    );
  }

  double get width => size.width;
  double get height => size.height;
  WindowClass get windowClass => AdaptiveSpec.classFor(width);
  bool get isCompact => windowClass == WindowClass.compact;
  bool get isNormal => windowClass == WindowClass.normal;
  bool get isLarge => windowClass == WindowClass.large;
  bool get twoPane => AdaptiveSpec.twoPane(width);
  bool get landscape => AdaptiveSpec.landscape(width, height);
  bool get shortHeight => AdaptiveSpec.shortHeight(height - viewInsets.bottom);
  bool get bigText => textScale >= 1.15;
  double get gutter => AdaptiveSpec.gutter(width);
  bool get stackTrailing => AdaptiveSpec.stackTrailing(width, textScale);
  int columns({double minTile = 156, double gap = 12, int max = 6}) => AdaptiveSpec.columns(width, minTile: minTile, gap: gap, max: max);

  /// One of three values by window class.
  T pick<T>({required T compact, required T normal, T? large}) {
    switch (windowClass) {
      case WindowClass.compact:
        return compact;
      case WindowClass.normal:
        return normal;
      case WindowClass.large:
        return large ?? normal;
    }
  }

  /// Page padding: gutters at the sides (centred column on wide windows),
  /// plus the notch / cut-out in landscape.
  EdgeInsets pagePadding({double top = 0, double bottom = 0, double maxWidth = AdaptiveSpec.maxContentWidth}) {
    final side = AdaptiveSpec.centeredInset(width, maxWidth: maxWidth);
    return EdgeInsets.fromLTRB(side > safe.left ? side : safe.left + gutter, top, side > safe.right ? side : safe.right + gutter, bottom);
  }
}

/// Rebuilds with the [Adaptive] of the space the widget has (LayoutBuilder),
/// so it is right in split-screen, in a pane and in a sheet.
class AdaptiveBuilder extends StatelessWidget {
  final Widget Function(BuildContext context, Adaptive a) builder;
  const AdaptiveBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (ctx, box) => builder(ctx, Adaptive.fromConstraints(ctx, box)));
}

/// Centres content and stops it from stretching on tablets and in landscape.
class ContentWidth extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final AlignmentGeometry alignment;
  final double? heightFactor;
  const ContentWidth({
    super.key,
    required this.child,
    this.maxWidth = AdaptiveSpec.maxContentWidth,
    this.alignment = Alignment.topCenter,
    this.heightFactor,
  });

  @override
  Widget build(BuildContext context) => Align(
        alignment: alignment,
        heightFactor: heightFactor,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
      );
}

/// List + detail side by side from 720 dp; below that only [list] (the
/// screen pushes the detail as a page). [detail] null shows [placeholder].
class TwoPane extends StatelessWidget {
  final Widget list;
  final Widget? detail;
  final Widget? placeholder;
  const TwoPane({super.key, required this.list, this.detail, this.placeholder});

  /// Whether a screen in [context] shows two panes (decide push vs. select).
  static bool active(BuildContext context) => AdaptiveSpec.twoPane(MediaQuery.sizeOf(context).width);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        if (!box.hasBoundedWidth || !AdaptiveSpec.twoPane(box.maxWidth)) return list;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: AdaptiveSpec.listPaneWidth(box.maxWidth), child: list),
            VerticalDivider(width: 1, thickness: 1, color: AppTheme.border),
            Expanded(child: ClipRect(child: detail ?? placeholder ?? const SizedBox.shrink())),
          ],
        );
      },
    );
  }
}

/// Makes any small control at least 48 x 48 dp to touch.
class MinTapTarget extends StatelessWidget {
  final Widget child;
  const MinTapTarget({super.key, required this.child});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(minWidth: AdaptiveSpec.minTap, minHeight: AdaptiveSpec.minTap),
        child: Center(widthFactor: 1, heightFactor: 1, child: child),
      );
}

/// A row that never overflows: [leading], flexible [body], [trailing]. On a
/// narrow window or with big text the trailing part moves under the body.
class AdaptiveRow extends StatelessWidget {
  final Widget? leading;
  final Widget body;
  final Widget? trailing;
  final double gap;
  const AdaptiveRow({super.key, this.leading, required this.body, this.trailing, this.gap = 12});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final scale = MediaQuery.textScalerOf(context).scale(100) / 100;
        final w = box.hasBoundedWidth ? box.maxWidth : MediaQuery.sizeOf(context).width;
        final stack = trailing != null && AdaptiveSpec.stackTrailing(w, scale);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (leading != null) ...[leading!, SizedBox(width: gap)],
            Expanded(
              child: stack
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [body, const SizedBox(height: 8), trailing!],
                    )
                  : body,
            ),
            if (trailing != null && !stack) ...[SizedBox(width: gap), trailing!],
          ],
        );
      },
    );
  }
}

/// Primary actions at the bottom edge, inside the safe area and above the
/// keyboard: within thumb reach on tall phones. Side by side when there is
/// room, stacked on narrow windows or with big text.
class BottomActionBar extends StatelessWidget {
  final List<Widget> children;
  final bool elevated;
  const BottomActionBar({super.key, required this.children, this.elevated = true});

  @override
  Widget build(BuildContext context) {
    final a = Adaptive.of(context);
    final stack = a.isCompact || a.bigText || children.length == 1;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.bg,
        border: elevated ? Border(top: BorderSide(color: AppTheme.border)) : null,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(a.gutter, 12, a.gutter, 12),
          child: ContentWidth(
            alignment: Alignment.center,
            heightFactor: 1,
            child: stack
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: 8), children[i]],
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(width: 12), Expanded(child: children[i])],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
