import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'ui_tokens.dart';

/// v3.58: what a place card shows when the admin has not uploaded a photo. Our own flat illustration (no stock
/// photos, nothing hotlinked): a deep teal sky, two hill layers, a winding road and a sun or a moon. The scene
/// varies with [seed] (the place name) so a list does not look repeated. White text is safe on it (primaryFill).
class PlaceArt extends StatelessWidget {
  final String seed;
  final bool night;
  final double? width;
  final double? height;
  final BorderRadius borderRadius;

  /// Darkens the lower part so text drawn over it stays readable.
  final bool scrim;

  const PlaceArt({super.key, required this.seed, this.night = false, this.width, this.height, this.borderRadius = Radii.lgAll, this.scrim = false});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: SizedBox(
        width: width,
        height: height,
        child: CustomPaint(
          painter: PlaceArtPainter(
            seed: seed.hashCode,
            sky: AppTheme.primaryFill,
            hillFar: Color.alphaBlend(Colors.white.withValues(alpha: night ? 0.06 : 0.12), AppTheme.primaryFill),
            hillNear: Color.alphaBlend(Colors.black.withValues(alpha: night ? 0.34 : 0.22), AppTheme.primaryFill),
            road: Colors.white.withValues(alpha: 0.55),
            orb: night ? const Color(0xFFE9E4D8) : AppTheme.accent,
            scrim: scrim,
          ),
        ),
      ),
    );
  }
}

class PlaceArtPainter extends CustomPainter {
  final int seed;
  final Color sky, hillFar, hillNear, road, orb;
  final bool scrim;
  PlaceArtPainter({required this.seed, required this.sky, required this.hillFar, required this.hillNear, required this.road, required this.orb, this.scrim = false});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;
    final rnd = math.Random(seed);
    canvas.drawRect(Offset.zero & size, Paint()..color = sky);
    // Sun / moon.
    final orbX = w * (0.62 + rnd.nextDouble() * 0.25), orbY = h * (0.22 + rnd.nextDouble() * 0.1);
    canvas.drawCircle(Offset(orbX, orbY), math.min(w, h) * 0.09, Paint()..color = orb.withValues(alpha: 0.9));
    Path hills(double base, double amp, double phase) {
      final p = Path()..moveTo(0, h);
      p.lineTo(0, h * base);
      const steps = 24;
      for (var i = 0; i <= steps; i++) {
        final x = w * i / steps;
        final y = h * base - math.sin(i / steps * math.pi * 2 + phase) * h * amp - math.sin(i / steps * math.pi * 5 + phase * 2) * h * amp * 0.25;
        p.lineTo(x, y);
      }
      return p
        ..lineTo(w, h)
        ..close();
    }

    canvas.drawPath(hills(0.58, 0.12, rnd.nextDouble() * 6), Paint()..color = hillFar);
    canvas.drawPath(hills(0.74, 0.08, rnd.nextDouble() * 6), Paint()..color = hillNear);
    // A winding road from the bottom towards the hills.
    final r = Path()..moveTo(w * (0.25 + rnd.nextDouble() * 0.2), h * 1.02);
    r.cubicTo(w * 0.75, h * 0.92, w * 0.15, h * 0.82, w * (0.5 + rnd.nextDouble() * 0.15), h * 0.7);
    canvas.drawPath(
      r,
      Paint()
        ..color = road
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2, h * 0.035)
        ..strokeCap = StrokeCap.round,
    );
    if (scrim) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0), Colors.black.withValues(alpha: 0.45)],
            stops: const [0.35, 1],
          ).createShader(Offset.zero & size),
      );
    }
  }

  @override
  bool shouldRepaint(PlaceArtPainter old) => old.seed != seed || old.sky != sky || old.scrim != scrim || old.orb != orb;
}

/// Page dots under a carousel: the current one is a short pill. Decorative (the carousel has its own labels).
class CarouselDots extends StatelessWidget {
  final int count;
  final int index;
  const CarouselDots({super.key, required this.count, required this.index});

  @override
  Widget build(BuildContext context) {
    if (count <= 1) return const SizedBox.shrink();
    return ExcludeSemantics(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: Motion.tab,
              curve: Motion.curve,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == index ? 18 : 6,
              height: 6,
              decoration: BoxDecoration(color: i == index ? AppTheme.primary : AppTheme.border2, borderRadius: BorderRadius.circular(999)),
            ),
        ],
      ),
    );
  }
}

/// A section title with an optional text action on the right ("See all", "Full view"); the action is a 48 dp
/// target.
class SectionTitle extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const SectionTitle(this.title, {super.key, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    final a = action;
    return Row(
      children: [
        Expanded(child: Semantics(header: true, child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 18)))),
        if (a != null && onAction != null)
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(minimumSize: const Size(48, 48), padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: Text(a, style: AppText.label.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }
}

/// A small icon + text pill ("Breakfast ride", "Crash detection on"). Sentence case, never colour alone.
class InfoPill extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  final Color? background;
  const InfoPill({super.key, required this.icon, required this.text, this.color, this.background});

  @override
  Widget build(BuildContext context) {
    final fg = color ?? AppTheme.text2;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: background ?? AppTheme.soft, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 6),
          Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: fg, fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }
}
