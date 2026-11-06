import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';

/// "98 km" as a value and a unit for [RideMetric] (rounded so it does not
/// change on every fix). "-" when unknown.
(String, String?) metricDistance(double? meters) {
  if (meters == null || !meters.isFinite) return ('-', null);
  final parts = formatDistanceRounded(meters).split(' ');
  return (parts.first, parts.length > 1 ? parts[1] : null);
}

/// The draggable ride sheet. [header] is the collapsed part (metrics or
/// stopped details, plus the talk row); it is measured, so the collapsed
/// sheet is exactly as tall as it and never scrolls. [body] is shown when
/// the rider drags the sheet up (or taps the header); only the expanded
/// sheet scrolls.
class RideSheet extends StatefulWidget {
  final Widget header;
  final List<Widget> body;

  /// Called with the sheet's visible height in logical pixels (for placing
  /// the SOS button and the map controls just above it).
  final ValueChanged<double>? onTopChanged;

  /// Called with how far the sheet is open: 0 collapsed, 1 fully expanded
  /// (for fading the floating map controls out as it opens).
  final ValueChanged<double>? onExpansionChanged;

  /// Largest share of the screen the expanded sheet takes.
  final double maxFraction;

  final double? minFraction;

  const RideSheet({
    super.key,
    required this.header,
    required this.body,
    this.onTopChanged,
    this.onExpansionChanged,
    this.maxFraction = 0.85,
    this.minFraction,
  });

  /// Horizontal padding shared by the collapsed header and the expanded body
  /// so every section of the sheet lines up on the same edges.
  static const double hPad = 16;

  /// Widest the sheet content gets (tablets, landscape): centred beyond it.
  static const double maxContentWidth = 600;

  @override
  State<RideSheet> createState() => RideSheetState();
}

class RideSheetState extends State<RideSheet> {
  final DraggableScrollableController _controller = DraggableScrollableController();

  /// Opacity of the body: hidden while collapsed (the strip under the header
  /// that sits behind the system navigation bar), shown as soon as it opens.
  final ValueNotifier<double> _bodyOpacity = ValueNotifier<double>(0);
  double _headerPx = 196;
  double _available = 0;
  double _min = 0.3;
  double _max = 0.85;
  double _bottomPad = 0;
  ScrollController? _inner;
  bool _reportScheduled = false;
  double _lastTop = -1;
  double _lastExpansion = -1;

  // Cached so the sheet is not told about "new" snap sizes on every rebuild
  // (that re-snaps it and fights the rider's finger mid-drag).
  (double, double)? _snapFor;
  List<double> _snapSizes = const <double>[];

  bool get _expanded => _controller.isAttached && _controller.size > _min + 0.05;

  double get _currentExtent => _controller.isAttached ? _controller.size : _min;

  /// Height of the collapsed sheet in logical pixels (header plus the bottom
  /// system inset), 0 before the first layout.
  double get collapsedHeight => _min * _available;

  /// Opens the sheet fully, or collapses it when it is open.
  void toggle() {
    if (!_controller.isAttached) return;
    if (_expanded) {
      collapse();
      return;
    }
    final target = _max.clamp(_min, 1.0).toDouble();
    _controller.animateTo(target, duration: Motion.sheet, curve: Motion.curve);
  }

  void collapse() {
    if (_controller.isAttached && _expanded) {
      // Back to the top of the list first, or the collapsed sheet would show
      // the middle of the body instead of the header.
      final inner = _inner;
      if (inner != null && inner.hasClients && inner.positions.length == 1 && inner.offset > 0) {
        inner.jumpTo(0);
      }
      _controller.animateTo(_min, duration: Motion.sheet, curve: Motion.curve);
    }
  }

  /// Tells the screen where the sheet's top edge is and how far it is open.
  /// Never while the tree is being built or laid out (the listeners rebuild
  /// widgets): then it waits for the end of the frame.
  void _report(double extent) {
    if (!mounted || _available <= 0) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      if (_reportScheduled) return;
      _reportScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _reportScheduled = false;
        if (mounted) _report(_currentExtent);
      });
      return;
    }
    final top = extent * _available;
    final span = _max - _min;
    final t = span <= 0.001 ? 0.0 : ((extent - _min) / span).clamp(0.0, 1.0).toDouble();
    // Fade the body in over the first 48 dp of dragging.
    _bodyOpacity.value = (((extent - _min) * _available) / 48).clamp(0.0, 1.0).toDouble();
    if ((top - _lastTop).abs() >= 0.5) {
      _lastTop = top;
      widget.onTopChanged?.call(top);
    }
    if ((t - _lastExpansion).abs() >= 0.002 || ((t == 0 || t == 1) && t != _lastExpansion)) {
      _lastExpansion = t;
      widget.onExpansionChanged?.call(t);
    }
  }

  void _onHeaderSize(Size size) {
    if (!mounted || (size.height - _headerPx).abs() < 1) return;
    final wasCollapsed = !_expanded;
    setState(() => _headerPx = size.height);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (wasCollapsed && _controller.isAttached && (_controller.size - _min).abs() > 0.0005) {
        _controller.jumpTo(_min);
      }
      _report(_currentExtent);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _bodyOpacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return LayoutBuilder(builder: (context, c) {
      final h = c.maxHeight;
      if (!h.isFinite || h <= 0) return const SizedBox.shrink();
      // Room for the gesture / navigation bar under the collapsed header, so
      // the talk bar is never hidden behind it.
      final bottomPad = pad.bottom;
      if ((h - _available).abs() >= 1 || (bottomPad - _bottomPad).abs() >= 1) {
        _available = h;
        _bottomPad = bottomPad;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _report(_currentExtent);
        });
      }
      final calculatedMin = widget.minFraction ?? ((_headerPx + bottomPad) / h);
      final min = calculatedMin.clamp(0.05, 0.8).toDouble();
      final oldMin = _min;
      _min = min;
      // The collapsed size changed (header re-measured, navigation bar inset
      // changed, rotation): a collapsed sheet follows it, once, after layout.
      if ((min - oldMin).abs() > 0.0005 && _controller.isAttached && _controller.size <= oldMin + 0.05) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_controller.isAttached) return;
          final size = _controller.size;
          if ((size - _min).abs() > 0.0005 && size <= oldMin + 0.05) _controller.jumpTo(_min);
        });
      }
      // Always room to open: on very short windows (split screen, large text)
      // the body stays reachable even when that beats [maxFraction].
      final floor = (min + 0.25).clamp(min, 0.95).toDouble();
      final max = widget.maxFraction < floor ? floor : widget.maxFraction.clamp(min, 1.0).toDouble();
      _max = max;
      // Three resting points: collapsed, half and expanded (half only when
      // it sits clearly between the other two).
      final key = (min, max);
      if (_snapFor != key) {
        _snapFor = key;
        _snapSizes = (min + 0.08 < 0.5 && 0.5 < max - 0.08) ? <double>[0.5] : const <double>[];
      }
      return NotificationListener<DraggableScrollableNotification>(
        onNotification: (n) {
          _report(n.extent);
          return false;
        },
        child: DraggableScrollableSheet(
          controller: _controller,
          initialChildSize: min,
          minChildSize: min,
          maxChildSize: max,
          snap: true,
          snapSizes: _snapSizes,
          snapAnimationDuration: Motion.sheet,
          builder: (context, scroll) {
            _inner = scroll;
            return Material(
              color: AppTheme.card,
              elevation: 8,
              shadowColor: AppTheme.shadow,
              shape: RoundedRectangleBorder(borderRadius: Radii.sheetTop, side: BorderSide(color: AppTheme.border, width: 2)),
              clipBehavior: Clip.antiAlias,
              child: ListView(
                controller: scroll,
                // The last rows scroll clear of the navigation bar and any side cutout.
                padding: EdgeInsets.only(left: pad.left, right: pad.right, bottom: bottomPad),
                children: [
                  _MeasureSize(
                    onChange: _onHeaderSize,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Handle(onTap: toggle),
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: RideSheet.maxContentWidth),
                            child: widget.header,
                          ),
                        ),
                      ],
                    ),
                  ),
                  ValueListenableBuilder<double>(
                    valueListenable: _bodyOpacity,
                    builder: (context, opacity, child) => Opacity(
                      opacity: opacity,
                      alwaysIncludeSemantics: true,
                      child: child,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(RideSheet.hPad, 8, RideSheet.hPad, 28),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: RideSheet.maxContentWidth),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: widget.body,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    });
  }
}

/// The grab handle: a full-width 32 dp strip (easy to hit with gloves) that
/// drags the sheet like the rest of the header; a tap opens or closes it.
class _Handle extends StatelessWidget {
  final VoidCallback? onTap;
  const _Handle({this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: 'Ride sheet',
      hint: onTap == null ? null : 'Double tap to open or close',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 32,
          child: Center(
            child: Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(color: AppTheme.border2, borderRadius: const BorderRadius.all(Radius.circular(3))),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reports its child's size after layout when it changed.
class _MeasureSize extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onChange;
  const _MeasureSize({required this.onChange, required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeasureSize(onChange);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasureSize renderObject) => renderObject.onChange = onChange;
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onChange);
  ValueChanged<Size> onChange;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    final s = size;
    if (s == _last) return;
    _last = s;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(s));
  }
}

/// Collapsed sheet while riding: four numbers, nothing to scroll.
class RidingMetrics extends StatelessWidget {
  final double? remainingM;
  final String eta;
  final int riding;
  final int total;
  final double spreadM;
  final VoidCallback? onTap;

  const RidingMetrics({
    super.key,
    required this.remainingM,
    required this.eta,
    required this.riding,
    required this.total,
    required this.spreadM,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final (remVal, remUnit) = metricDistance(remainingM);
    final (spVal, spUnit) = metricDistance(total < 2 ? null : spreadM);
    return Semantics(
      container: true,
      hint: onTap == null ? null : 'Double tap to show riders and route',
      child: InkWell(
        onTap: onTap,
        child: Padding(
          // The sheet body already applies [RideSheet.hPad]; no second inset here.
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: RideMetric(value: remVal, unit: remUnit, label: 'Remaining', emphasis: true, alignment: CrossAxisAlignment.center)),
              Expanded(flex: 4, child: RideMetric(value: eta, label: 'ETA', alignment: CrossAxisAlignment.center)),
              if (total >= 2) ...[
                Expanded(flex: 3, child: RideMetric(value: '$riding/$total', label: 'Riding', alignment: CrossAxisAlignment.center)),
                Expanded(flex: 4, child: RideMetric(value: spVal, unit: spUnit, label: 'Spread', alignment: CrossAxisAlignment.center)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Collapsed sheet while stopped: how long, where, who is near, how far the
/// next stop is, and "Tell the group why".
class StoppedDetails extends StatelessWidget {
  final Duration stoppedFor;
  final String place;
  final int nearby;
  final double nearbyRadiusM;
  final double? nextM;
  final String nextLabel;
  final String reason;
  final VoidCallback onTellWhy;
  final VoidCallback? onTap;
  final bool isSolo;

  const StoppedDetails({
    super.key,
    required this.stoppedFor,
    required this.place,
    required this.nearby,
    required this.nearbyRadiusM,
    required this.nextM,
    required this.nextLabel,
    required this.reason,
    required this.onTellWhy,
    this.onTap,
    this.isSolo = false,
  });

  @override
  Widget build(BuildContext context) {
    final (nVal, nUnit) = metricDistance(nextM);
    return InkWell(
      onTap: onTap,
      child: Padding(
        // Horizontal inset comes from the sheet header ([RideSheet.hPad]) so
        // this lines up with the talk bar and the body below.
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: AppTheme.warnTint, borderRadius: BorderRadius.circular(12)),
                  child: Icon(RiderStatus.stopped.icon, color: AppTheme.warnText, size: 22),
                ),
                const SizedBox(width: Space.s8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Stopped ${formatDuration(stoppedFor)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title),
                      if (place.isNotEmpty) Text(place, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.s8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isSolo)
                  Expanded(
                    child: RideMetric(
                      value: '$nearby',
                      label: '${nearby == 1 ? 'Rider' : 'Riders'} within ${formatDistance(nearbyRadiusM)}',
                    ),
                  ),
                Expanded(child: RideMetric(value: nVal, unit: nUnit, label: nextLabel)),
              ],
            ),
            const SizedBox(height: Space.s8),
            if (reason.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.s4),
                child: Text('You told the group: $reason', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label),
              ),
            DsButton(
              label: reason.isEmpty ? 'Tell the group why' : 'Change the reason',
              icon: Icons.chat_bubble_outline_rounded,
              tone: DsButtonTone.outline,
              height: 48,
              fontSize: 15,
              onPressed: onTellWhy,
            ),
          ],
        ),
      ),
    );
  }
}

/// A section title inside the expanded sheet ("Riders (3)", "Trip
/// progress"): 16/800 with the canvas block rhythm above it. The text is
/// shown as given (tests look for it); use [SheetOverline] for the
/// uppercase "RIDING ORDER" style header.
class SheetSectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SheetSectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = trailing;
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 10),
      child: Row(
        children: [
          Expanded(child: Semantics(header: true, child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title))),
          ?t,
        ],
      ),
    );
  }
}

/// One short line with an icon under the sheet title ("Rain likely after
/// Warangal around 3 PM", "Dark in 40 min"). Static.
class SheetLine extends StatelessWidget {
  final IconData icon;
  final String text;
  const SheetLine({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppTheme.accentText),
          const SizedBox(width: 8),
          Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label)),
        ],
      ),
    );
  }
}

