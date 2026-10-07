import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  /// Largest share of the screen the expanded sheet takes.
  final double maxFraction;

  const RideSheet({super.key, required this.header, required this.body, this.onTopChanged, this.maxFraction = 0.85});

  @override
  State<RideSheet> createState() => RideSheetState();
}

class RideSheetState extends State<RideSheet> {
  final DraggableScrollableController _controller = DraggableScrollableController();
  double _headerPx = 196;
  double _available = 0;
  double _min = 0.3;

  bool get _expanded => _controller.isAttached && _controller.size > _min + 0.05;

  /// Opens the sheet fully, or collapses it when it is open.
  void toggle() {
    if (!_controller.isAttached) return;
    final target = _expanded ? _min : widget.maxFraction.clamp(_min, 1.0).toDouble();
    _controller.animateTo(target, duration: Motion.sheet, curve: Motion.curve);
  }

  void collapse() {
    if (_controller.isAttached && _expanded) {
      _controller.animateTo(_min, duration: Motion.sheet, curve: Motion.curve);
    }
  }

  void _onHeaderSize(Size size) {
    if (!mounted || (size.height - _headerPx).abs() < 1) return;
    final wasCollapsed = !_expanded;
    setState(() => _headerPx = size.height);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (wasCollapsed && _controller.isAttached) _controller.jumpTo(_min);
      if (_available > 0) widget.onTopChanged?.call((_controller.isAttached ? _controller.size : _min) * _available);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final h = c.maxHeight;
      if (!h.isFinite || h <= 0) return const SizedBox.shrink();
      if ((h - _available).abs() >= 1) {
        _available = h;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onTopChanged?.call((_controller.isAttached ? _controller.size : _min) * h);
        });
      }
      final min = (_headerPx / h).clamp(0.12, 0.8).toDouble();
      _min = min;
      final max = widget.maxFraction < min ? min : widget.maxFraction;
      return NotificationListener<DraggableScrollableNotification>(
        onNotification: (n) {
          widget.onTopChanged?.call(n.extent * h);
          return false;
        },
        child: DraggableScrollableSheet(
          controller: _controller,
          initialChildSize: min,
          minChildSize: min,
          maxChildSize: max,
          snap: true,
          snapAnimationDuration: Motion.sheet,
          builder: (context, scroll) {
            return Material(
              color: AppTheme.slateCard,
              elevation: 4,
              shadowColor: AppTheme.shadow,
              shape: RoundedRectangleBorder(borderRadius: Radii.sheetTop, side: BorderSide(color: AppTheme.subtleBorder)),
              clipBehavior: Clip.antiAlias,
              child: ListView(
                controller: scroll,
                padding: EdgeInsets.zero,
                children: [
                  _MeasureSize(
                    onChange: _onHeaderSize,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _Handle(),
                        widget.header,
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.s16, Space.s8, Space.s16, Space.s24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: widget.body,
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

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 20,
      child: Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(color: AppTheme.textMuted, borderRadius: const BorderRadius.all(Radius.circular(2))),
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
          padding: const EdgeInsets.fromLTRB(Space.s12, Space.s4, Space.s12, Space.s12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: RideMetric(value: remVal, unit: remUnit, label: 'Remaining', emphasis: true, alignment: CrossAxisAlignment.center)),
              Expanded(flex: 4, child: RideMetric(value: eta, label: 'ETA', alignment: CrossAxisAlignment.center)),
              Expanded(flex: 3, child: RideMetric(value: '$riding/$total', label: 'Riding', alignment: CrossAxisAlignment.center)),
              Expanded(flex: 4, child: RideMetric(value: spVal, unit: spUnit, label: 'Spread', alignment: CrossAxisAlignment.center)),
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
  });

  @override
  Widget build(BuildContext context) {
    final (nVal, nUnit) = metricDistance(nextM);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.s16, 0, Space.s16, Space.s12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(RiderStatus.stopped.icon, color: StatusColors.warning, size: 24),
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
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: onTellWhy,
              icon: const Icon(Icons.chat_bubble_outline_rounded),
              label: Text(reason.isEmpty ? 'Tell the group why' : 'Change the reason', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}

/// A section title inside the expanded sheet.
class SheetSectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SheetSectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = trailing;
    return Padding(
      padding: const EdgeInsets.only(top: Space.s16, bottom: Space.s8),
      child: Row(
        children: [
          Expanded(child: Semantics(header: true, child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title))),
          ?t,
        ],
      ),
    );
  }
}

/// A 56 dp row in the expanded sheet (Messages, Group settings, ...).
class SheetRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  const SheetRow({super.key, required this.icon, required this.title, this.subtitle, required this.onTap, this.trailing});

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minTileHeight: 56,
      leading: Icon(icon, color: AppTheme.textPrimary),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
      subtitle: sub == null || sub.isEmpty ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
      trailing: trailing ?? Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
      onTap: onTap,
    );
  }
}
