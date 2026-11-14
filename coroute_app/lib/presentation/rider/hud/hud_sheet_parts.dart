import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../domain/ride/ride_stats_accumulator.dart';
import 'hud_logic.dart';
import 'hud_speed.dart';
import 'hud_top.dart' show kHudGlove;

/// Round 11 ride HUD: the parts of the ride sheet.
///
/// Collapsed: [HudCollapsedRow] (speed dial, ETA, km left, hold-to-end) and [HudGroupPillView].
/// Half: [HudArcSpeedometer] (hud_speed.dart), [HudEtaRow], [HudRideSoFar], [HudSpeedBands],
/// [HudOverLimit]. Full: [HudTripChart] and the cockpit's group / intercom / chat parts.
///
/// Charts follow one rule set: one series, one hue (teal), numbers in text ink beside the bars
/// (the numbers are the table view), no legend for a single series.

/// One labelled number ("9:03 pm" over "ETA").
class HudMetric extends StatelessWidget {
  const HudMetric({super.key, required this.value, required this.label, this.unit, this.valueColor, this.big = true});

  final String value;
  final String? unit;
  final String label;
  final Color? valueColor;
  final bool big;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label $value${unit == null ? '' : ' $unit'}',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: value),
                if (unit != null) TextSpan(text: ' $unit', style: AppText.label.copyWith(fontSize: big ? 14 : 12)),
              ]),
              maxLines: 1,
              style: AppText.metric.copyWith(
                fontSize: big ? 26 : 20,
                height: 1.15,
                color: valueColor ?? AppTheme.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
        ],
      ),
    );
  }
}

/// The collapsed sheet's main row: speed dial with the limit ring, ETA, distance left and the
/// hold-to-end button (then the existing confirm and end-ride rules).
class HudCollapsedRow extends StatelessWidget {
  const HudCollapsedRow({
    super.key,
    required this.speedKmh,
    required this.limitKmh,
    required this.hasFix,
    required this.eta,
    required this.leftValue,
    this.leftUnit,
    this.onHoldEnd,
    this.endLabel = 'End',
    this.onTap,
    this.etaLabel = 'ETA',
    this.leftLabel = 'Left',
  });

  /// Without a destination the cockpit shows "Moving" time and "Ridden" km here instead.
  final String etaLabel;
  final String leftLabel;

  final double speedKmh;
  final int limitKmh;
  final bool hasFix;
  final String eta;
  final String leftValue;
  final String? leftUnit;

  /// Null hides the end button (a rider who can neither end nor leave).
  final VoidCallback? onHoldEnd;
  final String endLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(
        children: [
          HudSpeedDial(key: const Key('hud_speed_dial'), speedKmh: speedKmh, limitKmh: limitKmh, hasFix: hasFix),
          const SizedBox(width: Space.s12),
          Expanded(child: HudMetric(value: eta, label: etaLabel, valueColor: etaLabel == 'ETA' ? AppTheme.primary : null)),
          Container(width: 1, height: 36, color: AppTheme.border),
          Expanded(child: HudMetric(value: leftValue, unit: leftUnit, label: leftLabel)),
          if (onHoldEnd != null) ...[
            const SizedBox(width: Space.s8),
            HudHoldButton(key: const Key('hud_end_ride'), label: endLabel, onHeld: onHoldEnd!),
          ],
        ],
      ),
    );
  }
}

/// Hold-to-confirm square (64 dp): a ring fills over [holdFor]; let go early and nothing happens.
/// The callback then runs the cockpit's existing end / leave flow (confirm dialog, lock-screen gate).
class HudHoldButton extends StatefulWidget {
  const HudHoldButton({super.key, required this.label, required this.onHeld, this.holdFor = const Duration(milliseconds: 1200)});

  final String label;
  final VoidCallback onHeld;
  final Duration holdFor;

  @override
  State<HudHoldButton> createState() => _HudHoldButtonState();
}

class _HudHoldButtonState extends State<HudHoldButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.holdFor)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        HapticFeedback.heavyImpact();
        _c.reset();
        widget.onHeld();
      }
    });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _down() {
    HapticFeedback.selectionClick();
    _c.forward(from: 0);
  }

  void _up() {
    if (_c.status != AnimationStatus.completed) _c.reverse();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Hold to ${widget.label.toLowerCase()} ride',
      onTap: widget.onHeld, // screen readers: the confirm dialog that follows is the safeguard
      excludeSemantics: true,
      child: Listener(
        onPointerDown: (_) => _down(),
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: SizedBox(
          width: 64,
          height: 64,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => CustomPaint(
              painter: _HoldRing(progress: _c.value, color: AppTheme.danger, track: AppTheme.border),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.stop_rounded, color: AppTheme.danger, size: 26),
                    Text(widget.label, style: AppText.caption.copyWith(color: AppTheme.danger, fontWeight: FontWeight.w600, height: 1.1)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HoldRing extends CustomPainter {
  _HoldRing({required this.progress, required this.color, required this.track});
  final double progress;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size size) {
    final rr = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(Radii.md));
    canvas.drawRRect(rr.deflate(1), Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    if (progress > 0) {
      final r = size.shortestSide / 2 - 3;
      canvas.drawArc(Rect.fromCircle(center: size.center(Offset.zero), radius: r), -math.pi / 2, 2 * math.pi * progress, false, Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(_HoldRing o) => o.progress != progress || o.color != color;
}

/// "5 riders · lead 1.2 km ahead" (tap: the group list in the full sheet).
class HudGroupPillView extends StatelessWidget {
  const HudGroupPillView({super.key, required this.text, this.warn = false, this.onTap, this.solo = false});

  final String text;
  final bool warn;
  final bool solo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = warn ? AppTheme.accentStrong : AppTheme.text;
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        key: const Key('hud_group_pill'),
        color: warn ? AppTheme.accentSoft : AppTheme.surfaceAlt,
        shape: StadiumBorder(side: BorderSide(color: warn ? AppTheme.warnBorder : AppTheme.border)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: Space.s12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(solo ? Icons.person_outline_rounded : (warn ? Icons.warning_amber_rounded : Icons.groups_outlined), size: 18, color: warn ? AppTheme.accentStrong : AppTheme.primary),
              const SizedBox(width: Space.s8),
              Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: fg, fontWeight: FontWeight.w600))),
            ]),
          ),
        ),
      ),
    );
  }
}

/// ETA / left / max under the arc speedometer.
class HudEtaRow extends StatelessWidget {
  const HudEtaRow({super.key, required this.eta, required this.leftValue, this.leftUnit, required this.maxKmh});
  final String eta;
  final String leftValue;
  final String? leftUnit;
  final double maxKmh;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(child: HudMetric(value: eta, label: 'ETA', valueColor: AppTheme.primary, big: false)),
      Container(width: 1, height: 32, color: AppTheme.border),
      Expanded(child: HudMetric(value: leftValue, unit: leftUnit, label: 'Left', big: false)),
      Container(width: 1, height: 32, color: AppTheme.border),
      Expanded(child: HudMetric(value: HudFormat.kmh(maxKmh), unit: 'km/h', label: 'Max', big: false)),
    ]);
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child, this.trailing, this.cardKey});
  final String title;
  final Widget child;
  final Widget? trailing;
  final Key? cardKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: cardKey,
      padding: const EdgeInsets.all(Space.s16),
      decoration: BoxDecoration(color: AppTheme.surfaceAlt, borderRadius: Radii.lgAll),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: Semantics(header: true, child: Text(title, style: AppText.overline))),
          ?trailing,
        ]),
        const SizedBox(height: Space.s12),
        child,
      ]),
    );
  }
}

/// "Ride so far": average moving speed, peak, distance, moving time, stops.
class HudRideSoFar extends StatelessWidget {
  const HudRideSoFar({super.key, required this.stats});
  final RideStatsAccumulator stats;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    return _Card(
      cardKey: const Key('hud_ride_so_far'),
      title: 'Ride so far',
      child: Column(children: [
        Row(children: [
          Expanded(child: HudMetric(value: HudFormat.kmh(s.avgMovingKmh), unit: 'km/h', label: 'Avg moving')),
          Expanded(child: HudMetric(value: HudFormat.kmh(s.peakKmh), unit: 'km/h', label: 'Peak')),
          Expanded(child: HudMetric(value: HudFormat.km(s.distanceM), unit: 'km', label: 'Ridden')),
        ]),
        const SizedBox(height: Space.s12),
        Row(children: [
          Expanded(child: HudMetric(value: HudFormat.clock(s.movingMs), label: 'Moving time', big: false)),
          Expanded(child: HudMetric(value: '${s.stops}', label: s.stops == 1 ? 'Stop' : 'Stops', big: false)),
          Expanded(child: HudMetric(value: HudFormat.clock(s.stoppedMs), label: 'Stopped', big: false)),
        ]),
      ]),
    );
  }
}

/// "Distance by speed": one bar per band of the vehicle profile, km and %; the band I am in now
/// is marked (bold label), so the bars also read as "where am I right now".
class HudSpeedBands extends StatelessWidget {
  const HudSpeedBands({super.key, required this.stats, required this.edgesKmh, this.currentKmh = 0});
  final RideStatsAccumulator stats;
  final List<int> edgesKmh;
  final double currentKmh;

  @override
  Widget build(BuildContext context) {
    final bands = stats.bands(edgesKmh);
    final total = stats.distanceM;
    final maxShare = bands.fold<double>(0, (m, b) => math.max(m, b.shareOf(total)));
    return _Card(
      cardKey: const Key('hud_speed_bands'),
      title: 'Distance by speed',
      trailing: Text('km/h', style: AppText.caption),
      child: Column(children: [
        for (final b in bands) ...[
          _BandRow(
            band: b,
            share: b.shareOf(total),
            scale: maxShare <= 0 ? 0 : b.shareOf(total) / maxShare,
            current: currentKmh >= 5 && currentKmh >= b.fromKmh && (b.toKmh == null || currentKmh < b.toKmh!),
          ),
          if (b != bands.last) const SizedBox(height: Space.s8),
        ],
      ]),
    );
  }
}

class _BandRow extends StatelessWidget {
  const _BandRow({required this.band, required this.share, required this.scale, required this.current});
  final SpeedBand band;
  final double share;
  final double scale;
  final bool current;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${band.label} kilometres per hour: ${HudFormat.bandDistance(band.distanceM)}, ${HudFormat.percent(share)}${current ? ', current speed' : ''}',
      excludeSemantics: true,
      child: SizedBox(
        height: 28,
        child: Row(children: [
          SizedBox(
            width: 68,
            child: Text(band.label, maxLines: 1, style: AppText.label.copyWith(color: current ? AppTheme.text : AppTheme.textMuted, fontWeight: current ? FontWeight.w700 : FontWeight.w500)),
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth * scale;
              return Stack(alignment: Alignment.centerLeft, children: [
                Container(height: 8, decoration: BoxDecoration(color: AppTheme.border, borderRadius: BorderRadius.circular(4))),
                if (w > 0)
                  Container(width: math.max(8, w), height: 8, decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(4))),
              ]);
            }),
          ),
          const SizedBox(width: Space.s12),
          SizedBox(
            width: 92,
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: HudFormat.bandDistance(band.distanceM), style: AppText.label.copyWith(color: AppTheme.text, fontWeight: FontWeight.w600)),
                TextSpan(text: '  ${(share * 100).round()}%', style: AppText.caption),
              ]),
              textAlign: TextAlign.right,
              maxLines: 1,
            ),
          ),
        ]),
      ),
    );
  }
}

/// "Over the limit": time and distance above the effective limit (a calm, honest safety stat;
/// amber with an icon, never a score or a scolding).
class HudOverLimit extends StatelessWidget {
  const HudOverLimit({super.key, required this.stats});
  final RideStatsAccumulator stats;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final any = s.overLimitMs > 0;
    return Container(
      key: const Key('hud_over_limit'),
      padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s12),
      decoration: BoxDecoration(
        color: any ? AppTheme.accentSoft : AppTheme.surfaceAlt,
        borderRadius: Radii.lgAll,
        border: Border.all(color: any ? AppTheme.warnBorder : AppTheme.surfaceAlt),
      ),
      child: Row(children: [
        Icon(any ? Icons.speed_rounded : Icons.check_circle_outline_rounded, color: any ? AppTheme.accentStrong : AppTheme.success, size: 22),
        const SizedBox(width: Space.s12),
        Expanded(
          child: Text(
            any
                ? 'Over the limit ${_minutes(s.overLimitMs)} · ${HudFormat.bandDistance(s.overLimitM)} (${HudFormat.percent(s.overLimitShare)})'
                : 'Within the limit so far',
            style: AppText.label.copyWith(color: any ? AppTheme.accentStrong : AppTheme.text, fontWeight: FontWeight.w600),
          ),
        ),
      ]),
    );
  }

  static String _minutes(int ms) {
    final m = ms ~/ 60000;
    if (m < 1) return '${(ms / 1000).round()} s';
    return '$m min';
  }
}

/// Trip so far: speed over time (one line, area under it, the limit as a dashed reference).
class HudTripChart extends StatelessWidget {
  const HudTripChart({super.key, required this.trace, required this.stepMs, this.limitKmh = 0});
  final List<int> trace;
  final int stepMs;
  final int limitKmh;

  @override
  Widget build(BuildContext context) {
    final minutes = (trace.length * stepMs / 60000).round();
    return _Card(
      cardKey: const Key('hud_trip_chart'),
      title: 'Speed over the ride',
      trailing: Text(trace.isEmpty ? '' : '$minutes min', style: AppText.caption),
      child: SizedBox(
        height: 96,
        child: trace.length < 2
            ? Center(child: Text('The chart starts after a few minutes of riding.', style: AppText.caption, textAlign: TextAlign.center))
            : RepaintBoundary(
                child: CustomPaint(
                  painter: _TracePainter(trace: trace, limit: limitKmh, line: AppTheme.primary, area: AppTheme.primary.withValues(alpha: 0.14), grid: AppTheme.border, limitColor: AppTheme.danger),
                  size: Size.infinite,
                ),
              ),
      ),
    );
  }
}

class _TracePainter extends CustomPainter {
  _TracePainter({required this.trace, required this.limit, required this.line, required this.area, required this.grid, required this.limitColor});
  final List<int> trace;
  final int limit;
  final Color line, area, grid, limitColor;

  @override
  void paint(Canvas canvas, Size size) {
    final top = math.max(trace.fold<int>(0, math.max), limit).toDouble() * 1.15;
    if (top <= 0) return;
    double y(num v) => size.height - (v / top) * size.height;
    final dx = size.width / (trace.length - 1);
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), Paint()..color = grid);
    final path = Path()..moveTo(0, y(trace.first));
    for (var i = 1; i < trace.length; i++) {
      path.lineTo(i * dx, y(trace[i]));
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = area);
    canvas.drawPath(path, Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round);
    if (limit > 0) {
      final ly = y(limit);
      final p = Paint()
        ..color = limitColor
        ..strokeWidth = 1.5;
      for (double x = 0; x < size.width; x += 10) {
        canvas.drawLine(Offset(x, ly), Offset(math.min(x + 5, size.width), ly), p);
      }
    }
  }

  @override
  bool shouldRepaint(_TracePainter o) => !identical(o.trace, trace) || o.limit != limit || o.line != line;
}

/// Section title inside the full sheet ("Group", "Intercom").
class HudSectionTitle extends StatelessWidget {
  const HudSectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Space.s8, bottom: Space.s8),
        child: Row(children: [
          Expanded(child: Semantics(header: true, child: Text(text, style: AppText.title))),
          ?trailing,
        ]),
      );
}

/// One rider row of the full sheet's group list.
class HudRiderRow extends StatelessWidget {
  const HudRiderRow({
    super.key,
    required this.name,
    required this.color,
    this.role,
    this.distanceText,
    this.statusText,
    this.battery,
    this.warn = false,
    this.onTap,
    this.onCall,
  });

  final String name;
  final Color color;

  /// "Lead", "Sweep", "You".
  final String? role;

  /// "1.2 km ahead · 4 min".
  final String? distanceText;

  /// "Stopped 5 min", "No signal", "Falling behind".
  final String? statusText;
  final int? battery;
  final bool warn;
  final VoidCallback? onTap;

  /// Call this rider (asks for the unlock while locked, like every call).
  final VoidCallback? onCall;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final sub = [?distanceText, ?statusText].join(' · ');
    return InkWell(
      onTap: onTap,
      borderRadius: Radii.mdAll,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kHudGlove),
        child: Row(children: [
          CircleAvatar(radius: 18, backgroundColor: color, child: Text(initial, style: AppText.label.copyWith(color: Colors.white, fontWeight: FontWeight.w700))),
          const SizedBox(width: Space.s12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600))),
                if (role != null) ...[
                  const SizedBox(width: Space.s8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(999)),
                    child: Text(role!, style: AppText.caption.copyWith(color: AppTheme.primary, fontWeight: FontWeight.w600)),
                  ),
                ],
              ]),
              if (sub.isNotEmpty)
                Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: warn ? AppTheme.accentStrong : AppTheme.textMuted, fontWeight: warn ? FontWeight.w600 : FontWeight.w400)),
            ]),
          ),
          if (battery != null && battery! >= 0) ...[
            Icon(battery! <= 15 ? Icons.battery_alert_rounded : Icons.battery_std_rounded, size: 18, color: battery! <= 15 ? AppTheme.danger : AppTheme.textMuted),
            Text('$battery%', style: AppText.caption),
            const SizedBox(width: Space.s4),
          ],
          if (onCall != null)
            IconButton(
              tooltip: 'Call $name',
              constraints: const BoxConstraints(minWidth: kHudGlove, minHeight: kHudGlove),
              onPressed: onCall,
              icon: Icon(Icons.call_outlined, color: AppTheme.primary),
            ),
        ]),
      ),
    );
  }
}
