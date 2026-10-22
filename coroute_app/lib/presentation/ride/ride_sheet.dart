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

  final double? minFraction;

  const RideSheet({
    super.key,
    required this.header,
    required this.body,
    this.onTopChanged,
    this.maxFraction = 0.85,
    this.minFraction,
  });

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
      final calculatedMin = widget.minFraction ?? (_headerPx / h);
      final min = calculatedMin.clamp(0.05, 0.8).toDouble();
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
              color: AppTheme.card,
              elevation: 8,
              shadowColor: AppTheme.shadow,
              shape: RoundedRectangleBorder(borderRadius: Radii.sheetTop, side: BorderSide(color: AppTheme.border, width: 2)),
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
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 600),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: widget.body,
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

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22,
      child: Center(
        child: Container(
          width: 44,
          height: 5,
          decoration: BoxDecoration(color: AppTheme.border2, borderRadius: const BorderRadius.all(Radius.circular(3))),
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
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
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
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
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

/// The small uppercase section header of the canvas ("RIDING ORDER"), with
/// the same block rhythm as [SheetSectionTitle].
class SheetOverline extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SheetOverline(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 10),
      child: Semantics(header: true, child: DsSectionHeader(text, trailing: trailing)),
    );
  }
}

/// The "Group" header at the top of the expanded sheet: title 22/800 and
/// a muted subtitle ("Bangalore Highway Convoy · 3 riders").
class SheetGroupHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const SheetGroupHeader({super.key, required this.title, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    return Row(
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(header: true, child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.headline)),
              if (sub != null && sub.isNotEmpty) ...[
                const SizedBox(height: 1),
                Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    );
  }
}

/// The teal hero card of the canvas "Group" screen: "CONVOY SPREAD ·
/// 4.6 km · Lead to last rider" with a white "Talk to all" button that
/// opens the intercom. [spreadM] null (or fewer than two riders) shows "-".
class ConvoySpreadHero extends StatelessWidget {
  final double? spreadM;
  final VoidCallback? onTalkToAll;
  final String talkLabel;
  const ConvoySpreadHero({super.key, required this.spreadM, this.onTalkToAll, this.talkLabel = 'Talk to all'});

  @override
  Widget build(BuildContext context) {
    final m = spreadM;
    final value = m == null || !m.isFinite ? '-' : formatDistanceRounded(m);
    return DsHeroCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('CONVOY SPREAD', style: TextStyle(color: DsHeroCard.overline, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1)),
                const SizedBox(height: 2),
                Text(value, maxLines: 1, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
                const SizedBox(height: 2),
                const Text('Lead to last rider', style: TextStyle(color: DsHeroCard.secondary, fontSize: 13, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          if (onTalkToAll != null) ...[
            const SizedBox(width: 12),
            SizedBox(
              height: 48,
              child: Material(
                color: AppTheme.card,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onTalkToAll,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.mic_none_rounded, size: 18, color: AppTheme.accentText),
                        const SizedBox(width: 8),
                        Text(talkLabel, style: TextStyle(color: AppTheme.accentText, fontSize: 14, fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One of the two side-by-side outline buttons under the riding order
/// ("Regroup stop" / "Share route"), 56 dp with a coloured icon.
class SheetAction {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? iconColor;
  const SheetAction({required this.icon, required this.label, required this.onTap, this.iconColor});
}

/// Two outline buttons in one row, 10 dp apart.
class SheetActionPair extends StatelessWidget {
  final SheetAction first;
  final SheetAction second;
  const SheetActionPair({super.key, required this.first, required this.second});

  Widget _button(SheetAction a) {
    return SizedBox(
      height: 56,
      child: Material(
        color: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: AppTheme.border, width: 2)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: a.onTap,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(a.icon, size: 20, color: a.iconColor ?? AppTheme.accentText),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    a.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppTheme.text, fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _button(first)),
        const SizedBox(width: 10),
        Expanded(child: _button(second)),
      ],
    );
  }
}

/// The dashed "INVITE CODE · BHC-482" card with a teal "Share" button and
/// an optional copy action.
class InviteCodeCard extends StatelessWidget {
  final String code;
  final VoidCallback? onShare;
  final VoidCallback? onCopy;
  const InviteCodeCard({super.key, required this.code, this.onShare, this.onCopy});

  @override
  Widget build(BuildContext context) {
    return DsCard(
      dashed: true,
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const DsSectionHeader('Invite code'),
                const SizedBox(height: 2),
                Text(
                  code,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.metric.copyWith(fontSize: 24, letterSpacing: 4),
                ),
              ],
            ),
          ),
          if (onCopy != null)
            IconButton(
              tooltip: 'Copy code',
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              icon: Icon(Icons.copy_rounded, color: AppTheme.accentText),
              onPressed: onCopy,
            ),
          if (onShare != null)
            SizedBox(
              height: 44,
              child: Material(
                color: AppTheme.brand,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onShare,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Center(child: Text('Share', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800))),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A 56 dp row in the expanded sheet (Messages, Group settings, ...). With
/// no [onTap] it is a plain information row (its [trailing] may still act).
/// Canvas list row: teal 22 dp icon, 15/700 title, hairline divider.
class SheetRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  const SheetRow({super.key, required this.icon, required this.title, this.subtitle, this.onTap, this.trailing});

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    final hasSub = sub != null && sub.isNotEmpty;
    final row = Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
      child: Row(
        children: [
          Icon(icon, size: 22, color: AppTheme.accentText),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                if (hasSub) ...[
                  const SizedBox(height: 2),
                  Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ] else if (onTap != null)
            Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
        ],
      ),
    );
    if (onTap == null) return row;
    return Semantics(button: true, child: InkWell(onTap: onTap, child: row));
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

/// How the "Save route map" row reads (pure, for tests): idle, saving,
/// saved or failed.
enum SaveMapState { idle, running, saved, failed }

SaveMapState saveMapStateOf({required bool running, required int done, required int total, String? error}) {
  if (running) return SaveMapState.running;
  if (error != null && error.isNotEmpty) return SaveMapState.failed;
  if (total > 0 && done >= total) return SaveMapState.saved;
  return SaveMapState.idle;
}

/// "Save route map" in the ride sheet and the review sheet (3.16, item 16):
/// a button while idle, a progress line while the tiles download, "Route map
/// saved" when done, and a retry when it failed. Tapping it is always
/// allowed, whatever the network (the automatic prefetch waits for Wi-Fi).
class SaveRouteMapRow extends StatelessWidget {
  final bool running;
  final int done;
  final int total;
  final String? error;
  final VoidCallback? onSave;

  const SaveRouteMapRow({super.key, required this.running, required this.done, required this.total, this.error, this.onSave});

  static const String idleTitle = 'Save route map';
  static const String savedTitle = 'Route map saved';
  static const String failedTitle = 'Could not save the map right now';
  static String progressTitle(int done, int total) => 'Saving route map: $done of $total';

  @override
  Widget build(BuildContext context) {
    final state = saveMapStateOf(running: running, done: done, total: total, error: error);
    switch (state) {
      case SaveMapState.running:
        return SheetRow(
          icon: Icons.download_rounded,
          title: progressTitle(done, total),
          trailing: SizedBox(
            width: 48,
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accentText, value: total > 0 ? (done / total).clamp(0.0, 1.0) : null),
              ),
            ),
          ),
        );
      case SaveMapState.saved:
        return SheetRow(
          icon: Icons.download_done_rounded,
          title: savedTitle,
          subtitle: 'Maps along the route work without signal.',
          trailing: Icon(Icons.check_circle_rounded, color: AppTheme.accentText),
        );
      case SaveMapState.failed:
        return SheetRow(
          icon: Icons.download_rounded,
          title: failedTitle,
          subtitle: 'Tap to try again.',
          onTap: onSave,
        );
      case SaveMapState.idle:
        return SheetRow(
          icon: Icons.download_rounded,
          title: idleTitle,
          subtitle: 'Map tiles along the route are kept on the phone for 30 days.',
          onTap: onSave,
        );
    }
  }
}
