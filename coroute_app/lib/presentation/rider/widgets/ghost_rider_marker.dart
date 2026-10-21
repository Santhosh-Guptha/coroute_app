import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_format.dart';
import '../../../core/ui/ui_tokens.dart';
import '../../../data/models/rider_model.dart';

/// Ghost-Rider marker for dropped convoy riders whose telemetry is stale > 30s.
///
/// Visual Specifications:
/// - Desaturated avatar (luminance-only greyscale filter).
/// - 60% opacity across the marker to indicate a ghostly, historic signal fix.
/// - Dashed radar halo enclosing the avatar indicating signal searching/loss.
/// - High-contrast time-elapsed badge (e.g. "Kiran · 3m ago" or "Dropped").
/// - Touch-friendly hit target (144x140 dp container) with tap callback for rider detail.
class GhostRiderMarker extends StatelessWidget {
  /// Standard map marker dimension for flutter_map Marker layer.
  static const double width = 144;
  static const double height = 140;

  /// Stale duration threshold: telemetry stale > 30 seconds triggers ghost mode.
  static const Duration staleThreshold = Duration(seconds: 30);

  final RiderModel rider;
  final int nowMs;
  final VoidCallback? onTap;
  final double avatarSize;
  final bool isMe;

  const GhostRiderMarker({
    super.key,
    required this.rider,
    required this.nowMs,
    this.onTap,
    this.avatarSize = 44.0,
    this.isMe = false,
  });

  /// Evaluates whether a rider's telemetry is stale (> 30s) or dropped.
  static bool isDropped(RiderModel rider, int nowMs, {Duration threshold = staleThreshold}) {
    if (rider.lastSeenEpochMs <= 0) return true;
    final ageMs = nowMs - rider.lastSeenEpochMs;
    return ageMs > threshold.inMilliseconds;
  }

  /// Formats the time-elapsed badge (e.g. "Kiran · 3m ago" or "Kiran · Dropped").
  static String formatElapsedBadge(String riderName, int lastSeenEpochMs, int nowMs) {
    final first = riderName.trim().split(RegExp(r'\s+')).first;
    if (lastSeenEpochMs <= 0) return '$first · Dropped';
    final elapsedMs = nowMs - lastSeenEpochMs;
    if (elapsedMs < 0) return '$first · Dropped';

    final seconds = elapsedMs ~/ 1000;
    if (seconds < 60) {
      return '$first · ${seconds}s ago';
    }
    final minutes = seconds ~/ 60;
    if (minutes < 60) {
      return '$first · ${minutes}m ago';
    }
    final hours = minutes ~/ 60;
    if (hours < 24) {
      return '$first · ${hours}h ago';
    }
    return '$first · Dropped';
  }

  // 4x5 ColorFilter matrix converting RGB channels to ITU-R BT.709 greyscale
  static const ColorFilter _desaturationMatrix = ColorFilter.matrix(<double>[
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0,      0,      0,      1, 0,
  ]);

  @override
  Widget build(BuildContext context) {
    final elapsedBadge = formatElapsedBadge(rider.name, rider.lastSeenEpochMs, nowMs);
    final isDroppedText = elapsedBadge.contains('Dropped');
    final semanticLabel = 'Ghost rider: ${rider.name}, $elapsedBadge. Tap for rider info.';

    // Halo dimensions: radius extends 8 dp beyond avatar edge
    final haloRadius = (avatarSize / 2) + 8.0;
    final haloTotalSize = (haloRadius + 4) * 2;

    return Semantics(
      container: true,
      button: onTap != null,
      label: semanticLabel,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onTap,
        child: Opacity(
          // 60% opacity per design spec
          opacity: 0.60,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              // 1. Dashed Radar Halo & Radar Pulse
              SizedBox(
                width: haloTotalSize,
                height: haloTotalSize,
                child: CustomPaint(
                  painter: _DashedRadarHaloPainter(
                    color: AppTheme.hyperAmber,
                    haloRadius: haloRadius,
                  ),
                ),
              ),

              // 2. Desaturated Ghost Avatar
              ColorFiltered(
                colorFilter: _desaturationMatrix,
                child: Container(
                  width: avatarSize,
                  height: avatarSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.card,
                    border: Border.all(
                      color: AppTheme.border,
                      width: 2.0,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      initialsOf(rider.name),
                      textScaler: TextScaler.noScaling,
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: math.max(12.0, avatarSize * 0.38),
                        fontWeight: FontWeight.w800,
                        fontFamily: AppTheme.fontFamily,
                      ),
                    ),
                  ),
                ),
              ),

              // 3. Stale indicator dot on avatar corner
              Positioned(
                top: (height - avatarSize) / 2 + avatarSize - 12,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.hyperAmber,
                    border: Border.all(color: AppTheme.obsidianVoid, width: 2),
                  ),
                ),
              ),

              // 4. Time-Elapsed Badge Pill positioned below avatar
              Positioned(
                top: (height / 2) + haloRadius + Space.s4,
                left: Space.s4,
                right: Space.s4,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                    decoration: BoxDecoration(
                      color: AppTheme.obsidianVoid.withValues(alpha: 0.90),
                      borderRadius: BorderRadius.circular(Radii.sm),
                      border: Border.all(
                        color: isDroppedText ? AppTheme.hyperAmber : AppTheme.warnBorder,
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          elapsedBadge,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textScaler: TextScaler.noScaling,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.4,
                            fontFamily: AppTheme.fontFamily,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          'LAST SEEN FIX',
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            color: AppTheme.hyperAmber,
                            fontSize: 8.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                            fontFamily: AppTheme.fontFamily,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Custom painter that renders a circular dashed radar halo with outer sweep ring.
class _DashedRadarHaloPainter extends CustomPainter {
  final Color color;
  final double haloRadius;

  _DashedRadarHaloPainter({
    required this.color,
    required this.haloRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // 1. Faint outer radar echo ring
    final echoPaint = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, haloRadius + 3.0, echoPaint);

    // 2. Dashed radar halo
    final dashPaint = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    const int dashCount = 14;
    const double totalAngle = 2 * math.pi;
    const double dashAngle = (totalAngle / dashCount) * 0.55;
    const double gapAngle = (totalAngle / dashCount) * 0.45;

    final rect = Rect.fromCircle(center: center, radius: haloRadius);
    double currentAngle = 0.0;

    for (int i = 0; i < dashCount; i++) {
      canvas.drawArc(rect, currentAngle, dashAngle, false, dashPaint);
      currentAngle += dashAngle + gapAngle;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRadarHaloPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.haloRadius != haloRadius;
  }
}
