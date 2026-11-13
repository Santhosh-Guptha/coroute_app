import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_motion.dart';
import 'ui_tokens.dart';

/// Skeleton placeholders: grey shapes in the layout of the content that is
/// loading, with one soft light sweep. Cheap: one ticker per [Shimmer], bones
/// only repaint (no rebuild, no layout). With reduce motion or battery saver
/// the shapes are static. docs/features_355/motion_and_loading.md
class Shimmer extends StatefulWidget {
  final Widget child;
  const Shimmer({super.key, required this.child});

  static Animation<double>? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_ShimmerScope>()?.animation;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

// Not the Single- mixin: the controller is created again when motion comes back (battery saver off).
class _ShimmerState extends State<Shimmer> with TickerProviderStateMixin {
  AnimationController? _c;

  void _sync() {
    final run = MotionSpec.loops(AppMotion.levelOf(context));
    if (run && _c == null) {
      _c = AnimationController(vsync: this, duration: AppMotion.shimmer)..repeat();
    } else if (!run && _c != null) {
      _c!.dispose();
      _c = null;
    }
  }

  @override
  void initState() {
    super.initState();
    AppMotion.batterySaver.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void dispose() {
    AppMotion.batterySaver.removeListener(_changed);
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _sync();
    return Semantics(
      label: 'Loading',
      container: true,
      excludeSemantics: true,
      child: RepaintBoundary(child: _ShimmerScope(animation: _c, child: widget.child)),
    );
  }
}

class _ShimmerScope extends InheritedWidget {
  final Animation<double>? animation;
  const _ShimmerScope({required this.animation, required super.child});

  @override
  bool updateShouldNotify(_ShimmerScope old) => old.animation != animation;
}

/// One grey shape. Use the presets below where they fit.
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double? height;
  final double radius;
  final bool circle;
  const SkeletonBox({super.key, this.width, this.height, this.radius = Radii.sm, this.circle = false});

  static Color get _base => Color.alphaBlend(AppTheme.text.withValues(alpha: AppTheme.isLight ? 0.07 : 0.10), AppTheme.card);
  static Color get _glow => Color.alphaBlend(AppTheme.text.withValues(alpha: AppTheme.isLight ? 0.02 : 0.18), AppTheme.card);

  @override
  Widget build(BuildContext context) {
    final a = Shimmer.maybeOf(context);
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _BonePainter(
          animation: a,
          base: _base,
          glow: _glow,
          radius: circle ? null : radius,
          origin: () {
            final box = context.findRenderObject();
            return box is RenderBox && box.attached ? box.localToGlobal(Offset.zero) : Offset.zero;
          },
          screenWidth: MediaQuery.sizeOf(context).width,
        ),
      ),
    );
  }
}

class _BonePainter extends CustomPainter {
  final Animation<double>? animation;
  final Color base;
  final Color glow;
  final double? radius;
  final Offset Function() origin;
  final double screenWidth;
  _BonePainter({required this.animation, required this.base, required this.glow, required this.radius, required this.origin, required this.screenWidth})
      : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = base;
    final a = animation;
    if (a != null && screenWidth > 0) {
      // One sweep across the whole screen, so all bones light up as one band.
      final band = screenWidth * 0.6;
      final x = -band + (screenWidth + 2 * band) * a.value - origin().dx;
      paint.shader = LinearGradient(colors: [base, glow, base], stops: const [0, 0.5, 1]).createShader(Rect.fromLTWH(x, 0, band, size.height));
    }
    final r = radius;
    if (r == null) {
      canvas.drawOval(Offset.zero & size, paint);
    } else {
      canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(r)), paint);
    }
  }

  @override
  bool shouldRepaint(_BonePainter old) => old.base != base || old.glow != glow || old.radius != radius || old.animation != animation || old.screenWidth != screenWidth;
}

/// A text line. [widthFactor] of the available width (text lines differ).
class SkeletonLine extends StatelessWidget {
  final double widthFactor;
  final double height;
  const SkeletonLine({super.key, this.widthFactor = 1, this.height = 12});

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
        widthFactor: widthFactor.clamp(0.05, 1.0).toDouble(),
        alignment: AlignmentDirectional.centerStart,
        child: SkeletonBox(height: height, radius: height / 2),
      );
}

/// Several text lines (plans / capability text, descriptions).
class SkeletonParagraph extends StatelessWidget {
  final int lines;
  final double gap;
  const SkeletonParagraph({super.key, this.lines = 3, this.gap = 10});

  static const List<double> _widths = [1, 0.92, 0.78, 0.96, 0.6, 0.85];

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < lines; i++) ...[
            if (i > 0) SizedBox(height: gap),
            SkeletonLine(widthFactor: i == lines - 1 && lines > 1 ? 0.55 : _widths[i % _widths.length]),
          ],
        ],
      );
}

/// A list row: avatar or icon, two lines, optional trailing chip. 72 dp high
/// (the height of the app's rider / crew / trip rows).
class SkeletonListTile extends StatelessWidget {
  final bool avatar;
  final bool trailing;
  final double height;
  const SkeletonListTile({super.key, this.avatar = true, this.trailing = false, this.height = extent});

  static const double extent = 72;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: Row(
          children: [
            if (avatar) ...[const SkeletonBox(width: 44, height: 44, circle: true), const SizedBox(width: Space.s12)],
            const Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [SkeletonLine(widthFactor: 0.62, height: 14), SizedBox(height: 10), SkeletonLine(widthFactor: 0.4, height: 11)],
              ),
            ),
            if (trailing) ...[const SizedBox(width: Space.s12), const SkeletonBox(width: 56, height: 24, radius: 12)],
          ],
        ),
      );
}

/// A card: title line and [lines] text lines inside the app's card frame.
class SkeletonCard extends StatelessWidget {
  final int lines;
  final double? height;
  final bool media;
  const SkeletonCard({super.key, this.lines = 2, this.height, this.media = false});

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        padding: const EdgeInsets.all(Space.s16),
        decoration: BoxDecoration(color: AppTheme.card, borderRadius: Radii.lgAll, border: Border.all(color: AppTheme.border)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (media) ...[const SkeletonBox(height: 120, radius: Radii.md), const SizedBox(height: Space.s12)],
            const SkeletonLine(widthFactor: 0.5, height: 15),
            if (lines > 0) ...[const SizedBox(height: Space.s12), SkeletonParagraph(lines: lines)],
          ],
        ),
      );
}

/// Three stat cells in a row (profile numbers, score, analytics).
class SkeletonStatRow extends StatelessWidget {
  final int cells;
  const SkeletonStatRow({super.key, this.cells = 3});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          for (var i = 0; i < cells; i++) ...[
            if (i > 0) const SizedBox(width: Space.s8),
            const Expanded(child: SkeletonBox(height: 64, radius: Radii.md)),
          ],
        ],
      );
}

/// Profile header: big avatar, name, handle, stats, two cards.
class SkeletonProfile extends StatelessWidget {
  final int cards;
  const SkeletonProfile({super.key, this.cards = 2});

  @override
  Widget build(BuildContext context) => SkeletonGroup(
        children: [
          const Center(child: SkeletonBox(width: 96, height: 96, circle: true)),
          const SizedBox(height: Space.s16),
          const Center(child: SizedBox(width: 160, child: SkeletonLine(height: 18))),
          const SizedBox(height: Space.s8),
          const Center(child: SizedBox(width: 110, child: SkeletonLine())),
          const SizedBox(height: Space.s24),
          const SkeletonStatRow(),
          for (var i = 0; i < cards; i++) ...[const SizedBox(height: Space.s12), const SkeletonCard(lines: 2)],
        ],
      );
}

/// A column of skeleton pieces with one shimmer. Never overflows: it clips
/// and does not scroll (the real list replaces it).
class SkeletonGroup extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  const SkeletonGroup({super.key, required this.children, this.padding = EdgeInsets.zero});

  @override
  Widget build(BuildContext context) => Shimmer(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          padding: padding,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      );
}

/// A list of skeleton rows. [count] null = as many as fit the space.
class SkeletonList extends StatelessWidget {
  final int? count;
  final double itemExtent;
  final double gap;
  final EdgeInsetsGeometry padding;
  final WidgetBuilder? itemBuilder;
  const SkeletonList({super.key, this.count, this.itemExtent = SkeletonListTile.extent, this.gap = 0, this.padding = const EdgeInsets.symmetric(horizontal: Space.s16), this.itemBuilder});

  /// Cards instead of rows (history, clubs, places, admin lists).
  const SkeletonList.cards({super.key, this.count, this.itemExtent = 104, this.gap = Space.s12, this.padding = const EdgeInsets.all(Space.s16)}) : itemBuilder = _card;

  static Widget _card(BuildContext _) => const SkeletonCard(lines: 1);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final h = box.hasBoundedHeight ? box.maxHeight : MediaQuery.sizeOf(context).height * 0.6;
        final n = count ?? MotionSpec.skeletonRows(h, itemExtent + gap);
        final build = itemBuilder ?? (_) => const SkeletonListTile();
        return SkeletonGroup(
          padding: padding,
          children: [
            for (var i = 0; i < n; i++) ...[
              if (i > 0 && gap > 0) SizedBox(height: gap),
              SizedBox(height: itemExtent, child: build(context)),
            ],
          ],
        );
      },
    );
  }
}

/// Skeleton while [loading], then the content, with a short cross-fade and no
/// layout jump (both are top-aligned in the same box).
class SkeletonSwitcher extends StatelessWidget {
  final bool loading;
  final WidgetBuilder skeleton;
  final WidgetBuilder builder;
  const SkeletonSwitcher({super.key, required this.loading, required this.skeleton, required this.builder});

  @override
  Widget build(BuildContext context) => FadeThroughSwitcher(
        child: loading
            ? KeyedSubtree(key: const ValueKey<String>('skeleton'), child: Builder(builder: skeleton))
            : KeyedSubtree(key: const ValueKey<String>('content'), child: Builder(builder: builder)),
      );
}

/// The thin line at the top of a screen while it refreshes in place. Appears
/// only when the work takes longer than a moment and never flickers.
class TopProgressLine extends StatefulWidget {
  final bool active;
  const TopProgressLine({super.key, required this.active});

  @override
  State<TopProgressLine> createState() => _TopProgressLineState();
}

class _TopProgressLineState extends State<TopProgressLine> {
  bool _visible = false;
  Timer? _timer;
  DateTime? _shownAt;

  @override
  void initState() {
    super.initState();
    if (widget.active) _schedule();
  }

  @override
  void didUpdateWidget(TopProgressLine old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (widget.active) {
      if (_visible) return;
      _timer = Timer(const Duration(milliseconds: MotionMs.loaderDelay), () {
        if (!mounted) return;
        _shownAt = DateTime.now();
        setState(() => _visible = true);
      });
    } else {
      if (!_visible) return;
      final shown = _shownAt == null ? MotionMs.loaderMinVisible : DateTime.now().difference(_shownAt!).inMilliseconds;
      _timer = Timer(Duration(milliseconds: MotionSpec.loaderHoldMs(shown)), () {
        if (mounted) setState(() => _visible = false);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = AppMotion.reducedOf(context);
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: AppMotion.durationOf(context, AppMotion.fast),
        child: SizedBox(
          height: 2,
          child: !_visible
              ? null
              : Semantics(
                  label: 'Refreshing',
                  liveRegion: true,
                  child: still
                      ? ColoredBox(color: AppTheme.brand.withValues(alpha: 0.6))
                      : LinearProgressIndicator(minHeight: 2, color: AppTheme.brand, backgroundColor: Colors.transparent),
                ),
        ),
      ),
    );
  }
}

/// [count] skeleton rows for use INSIDE a list or a card (takes only the
/// height it needs, has its own shimmer).
class SkeletonRows extends StatelessWidget {
  final int count;
  final bool avatar;
  final bool trailing;
  final double itemExtent;
  const SkeletonRows({super.key, this.count = 4, this.avatar = true, this.trailing = false, this.itemExtent = SkeletonListTile.extent});

  @override
  Widget build(BuildContext context) => Shimmer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [for (var i = 0; i < count; i++) SkeletonListTile(avatar: avatar, trailing: trailing, height: itemExtent)],
        ),
      );
}

/// [count] skeleton cards for use INSIDE a list (history, clubs, places,
/// plans, admin lists). [stats] adds a row of stat cells on top.
class SkeletonCards extends StatelessWidget {
  final int count;
  final int lines;
  final bool stats;
  const SkeletonCards({super.key, this.count = 3, this.lines = 2, this.stats = false});

  @override
  Widget build(BuildContext context) => Shimmer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (stats) ...[const SkeletonStatRow(), const SizedBox(height: Space.s12)],
            for (var i = 0; i < count; i++) ...[if (i > 0) const SizedBox(height: Space.s12), SkeletonCard(lines: lines)],
          ],
        ),
      );
}
