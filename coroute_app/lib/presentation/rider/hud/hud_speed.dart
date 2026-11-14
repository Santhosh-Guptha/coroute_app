import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import 'hud_logic.dart';

/// Round 11 ride HUD: the speed components.
///
/// * [HudSpeedDial]       the collapsed sheet's round speed readout with the limit ring
///                        (teal at or under the limit, amber over it, red past the +10 % margin).
/// * [HudArcSpeedometer]  the half sheet's arc gauge: scale, needle arc, the effective limit marker
///                        (round 9), the peak tick.
///
/// Both paint with a CustomPainter inside a RepaintBoundary: a new speed repaints the dial only.

Color hudSpeedColor(HudSpeedLevel level) => switch (level) {
      HudSpeedLevel.strong => AppTheme.danger,
      HudSpeedLevel.over => AppTheme.warning,
      HudSpeedLevel.normal => AppTheme.primary,
      HudSpeedLevel.none => AppTheme.primary,
    };

class HudSpeedDial extends StatelessWidget {
  const HudSpeedDial({super.key, required this.speedKmh, required this.limitKmh, this.size = 76, this.hasFix = true});

  final double speedKmh;
  final int limitKmh;
  final double size;

  /// No GPS fix yet: "-" instead of 0 (never a made-up speed).
  final bool hasFix;

  @override
  Widget build(BuildContext context) {
    final level = HudSpeedRing.level(speedKmh, limitKmh);
    final color = hudSpeedColor(level);
    final value = hasFix ? HudFormat.kmh(speedKmh) : '-';
    final limitText = limitKmh > 0 ? ', limit $limitKmh' : '';
    final over = level == HudSpeedLevel.over || level == HudSpeedLevel.strong;
    return Semantics(
      label: 'Speed $value kilometres per hour$limitText${over ? ', over the limit' : ''}',
      excludeSemantics: true,
      child: RepaintBoundary(
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _DialPainter(
              fraction: limitKmh > 0 ? (speedKmh / limitKmh).clamp(0.0, 1.0).toDouble() : (speedKmh / 120).clamp(0.0, 1.0).toDouble(),
              color: color,
              track: AppTheme.border,
              strong: level == HudSpeedLevel.strong,
              fill: level == HudSpeedLevel.strong ? AppTheme.danger.withValues(alpha: 0.14) : (level == HudSpeedLevel.over ? AppTheme.accentSoft : Colors.transparent),
            ),
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.2,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FittedBox(
                      child: Text(
                        value,
                        style: AppText.metric.copyWith(
                          fontSize: size * 0.38,
                          height: 1.0,
                          color: over ? (level == HudSpeedLevel.strong ? AppTheme.danger : AppTheme.accentStrong) : AppTheme.text,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    Text('km/h', style: AppText.caption.copyWith(fontSize: 11, height: 1.1)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({required this.fraction, required this.color, required this.track, required this.strong, required this.fill});

  final double fraction;
  final Color color;
  final Color track;
  final bool strong;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.075;
    final r = size.width / 2 - stroke / 2;
    final c = size.center(Offset.zero);
    if (fill.a > 0) canvas.drawCircle(c, r, Paint()..color = fill);
    // 270 degree ring opening at the bottom, like a speedometer.
    const start = math.pi * 0.75;
    const sweep = math.pi * 1.5;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawArc(rect, start, sweep, false, Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round);
    if (fraction > 0) {
      canvas.drawArc(rect, start, sweep * fraction, false, Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strong ? stroke * 1.25 : stroke
        ..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(_DialPainter o) => o.fraction != fraction || o.color != color || o.track != track || o.strong != strong || o.fill != fill;
}

/// The half sheet's arc speedometer.
class HudArcSpeedometer extends StatelessWidget {
  const HudArcSpeedometer({
    super.key,
    required this.speedKmh,
    required this.limitKmh,
    this.peakKmh = 0,
    this.hasFix = true,
    this.height = 196,
  });

  final double speedKmh;

  /// The effective limit (round 9: stricter of group / personal / road); 0 = none (no marker).
  final int limitKmh;
  final double peakKmh;
  final bool hasFix;
  final double height;

  @override
  Widget build(BuildContext context) {
    final level = HudSpeedRing.level(speedKmh, limitKmh);
    final max = HudSpeedRing.dialMax(peakKmh: math.max(peakKmh, speedKmh), limitKmh: limitKmh);
    final value = hasFix ? HudFormat.kmh(speedKmh) : '-';
    final over = level == HudSpeedLevel.over || level == HudSpeedLevel.strong;
    return Semantics(
      label: 'Speed $value kilometres per hour${limitKmh > 0 ? ', limit $limitKmh' : ''}${over ? ', over the limit' : ''}',
      excludeSemantics: true,
      child: RepaintBoundary(
        child: Center(
          child: SizedBox(
            height: height,
            width: height * 1.25,
            child: CustomPaint(
              painter: _ArcPainter(
                speed: hasFix ? speedKmh : 0,
                max: max,
                limit: limitKmh,
                peak: peakKmh,
                color: hudSpeedColor(level),
                track: AppTheme.border,
                tick: AppTheme.textMuted,
                limitColor: AppTheme.danger,
                peakColor: AppTheme.accent,
                labelStyle: AppText.caption.copyWith(fontSize: 11),
              ),
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.2,
                child: Align(
                  alignment: const Alignment(0, 0.15),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        value,
                        style: AppText.metric.copyWith(
                          fontSize: height * 0.30,
                          height: 1.0,
                          color: over ? (level == HudSpeedLevel.strong ? AppTheme.danger : AppTheme.accentStrong) : AppTheme.text,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: Space.s4),
                      Text('km/h', style: AppText.label),
                      if (limitKmh > 0) ...[
                        const SizedBox(height: Space.s4),
                        Text(
                          over ? 'Over limit $limitKmh' : 'Limit $limitKmh',
                          style: AppText.caption.copyWith(
                            color: over ? (level == HudSpeedLevel.strong ? AppTheme.danger : AppTheme.accentStrong) : AppTheme.textMuted,
                            fontWeight: over ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter({
    required this.speed,
    required this.max,
    required this.limit,
    required this.peak,
    required this.color,
    required this.track,
    required this.tick,
    required this.limitColor,
    required this.peakColor,
    required this.labelStyle,
  });

  final double speed;
  final int max;
  final int limit;
  final double peak;
  final Color color, track, tick, limitColor, peakColor;
  final TextStyle labelStyle;

  static const double start = math.pi * 0.75;
  static const double sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.06;
    final r = size.shortestSide / 2 - stroke - 14;
    final c = Offset(size.width / 2, size.height / 2 + stroke * 0.6);
    final rect = Rect.fromCircle(center: c, radius: r);
    double angle(double v) => start + sweep * (v / max).clamp(0.0, 1.0);

    canvas.drawArc(rect, start, sweep, false, Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round);
    // Over-limit stretch of the scale, lightly tinted, so the rider sees where the limit band begins.
    if (limit > 0 && limit < max) {
      canvas.drawArc(rect, angle(limit.toDouble()), sweep * (1 - limit / max), false, Paint()
        ..color = limitColor.withValues(alpha: 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke);
    }
    if (speed > 0) {
      canvas.drawArc(rect, start, sweep * (speed / max).clamp(0.0, 1.0), false, Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round);
    }
    // Ticks every 10 km/h, labels every 40.
    final tickPaint = Paint()
      ..color = tick
      ..strokeWidth = 1.5;
    for (var v = 0; v <= max; v += 10) {
      final a = angle(v.toDouble());
      final major = v % 40 == 0;
      final r1 = r + stroke / 2 + 3;
      final r2 = r1 + (major ? 8 : 4);
      canvas.drawLine(c + Offset(math.cos(a), math.sin(a)) * r1, c + Offset(math.cos(a), math.sin(a)) * r2, tickPaint);
      if (major) {
        final tp = TextPainter(text: TextSpan(text: '$v', style: labelStyle), textDirection: TextDirection.ltr)..layout();
        final p = c + Offset(math.cos(a), math.sin(a)) * (r2 + 10);
        tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
      }
    }
    // Limit marker: a bold red notch across the ring.
    if (limit > 0) {
      final a = angle(limit.toDouble());
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + dir * (r - stroke * 0.9), c + dir * (r + stroke * 0.9), Paint()
        ..color = limitColor
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round);
    }
    // Peak tick inside the ring.
    if (peak > 0) {
      final a = angle(peak);
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawCircle(c + dir * (r - stroke * 1.4), 3.5, Paint()..color = peakColor);
    }
  }

  @override
  bool shouldRepaint(_ArcPainter o) =>
      o.speed != speed || o.max != max || o.limit != limit || o.peak != peak || o.color != color || o.track != track || o.tick != tick;
}
