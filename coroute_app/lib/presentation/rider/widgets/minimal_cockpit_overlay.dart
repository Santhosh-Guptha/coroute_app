import 'dart:ui';
import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../domain/ride/ride_facts.dart';



// ---------------------------------------------------------------------------
// MinimalCockpitTopBar
// ---------------------------------------------------------------------------

/// Slim pill bar at the very top: destination + distance on the left, GPS/
/// connection state on the right. Height never exceeds 48 dp. When an alert
/// message is present it slides in on a second row that blends into the pill.
///
/// Strict CoRoute standards: no emoji, pure vector icons, 48 dp minimum tap.
class MinimalCockpitTopBar extends StatelessWidget {
  final String title;

  /// Short status word, e.g. "Reconnecting" or null when connected.
  final String? connection;

  /// GPS quality state.
  final GpsState gps;

  /// Quiet route-line status ("New route, 42 km"). Null = nothing to show.
  final String? routeStatus;

  /// When true the route icon and color are red (emergency navigation).
  final bool emergencyRoute;

  /// Stops the emergency navigation when tapped.
  final VoidCallback? onStopNavigation;

  /// Whether the back button is shown (non-embedded mode).
  final VoidCallback? onBack;

  final bool isTunnelCoasting;

  const MinimalCockpitTopBar({
    super.key,
    required this.title,
    required this.connection,
    required this.gps,
    this.routeStatus,
    this.emergencyRoute = false,
    this.onStopNavigation,
    this.onBack,
    this.isTunnelCoasting = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasWarn = connection != null || gps != GpsState.accurate;
    final hasRoute = routeStatus != null;
    final hasExtra = hasWarn || hasRoute || isTunnelCoasting;
    final back = onBack;


    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          decoration: BoxDecoration(
            color: AppTheme.obsidianVoid.withOpacity(0.78),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: hasWarn
                  ? StatusColors.warning.withOpacity(0.55)
                  : AppTheme.neonCyan.withOpacity(0.35),
              width: 1.2,
            ),
          ),
          padding: EdgeInsetsDirectional.fromSTEB(
            back != null ? 4 : 16,
            hasExtra ? 8 : 0,
            onStopNavigation != null ? 4 : 16,
            hasExtra ? 8 : 0,
          ),
          child: IntrinsicHeight(
            child: Row(
              children: [
                if (back != null)
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(Icons.arrow_back_rounded, color: AppTheme.textPrimary, size: 20),
                      tooltip: 'Back',
                      onPressed: back,
                    ),
                  ),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Primary: destination / convoy name
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                          fontSize: 15,
                        ),
                      ),
                      // Secondary: tunnel / connection / GPS / route status
                      if (isTunnelCoasting) ...[
                        const SizedBox(height: 2),
                        _StatusRow(
                          icon: Icons.tune_rounded,
                          label: 'Tunnel Coasting (Dead-Reckoning)',
                          color: AppTheme.neonCyan,
                        ),
                      ] else if (hasWarn) ...[
                        const SizedBox(height: 2),
                        _StatusRow(
                          icon: connection != null
                              ? Icons.cloud_off_rounded
                              : Icons.gps_not_fixed_rounded,
                          label: [
                            ?connection,
                            if (gps != GpsState.accurate)
                              'GPS ${gps.label.toLowerCase()}',
                          ].join(', '),
                          color: StatusColors.warning,
                        ),

                      ],
                      if (hasRoute && !isTunnelCoasting) ...[
                        const SizedBox(height: 2),
                        _StatusRow(
                          icon: emergencyRoute
                              ? Icons.emergency_rounded
                              : Icons.alt_route_rounded,
                          label: routeStatus!,
                          color: emergencyRoute ? StatusColors.critical : StatusColors.info,
                        ),
                      ],
                    ],
                  ),
                ),
                // Right: GPS quality dot
                _GpsDot(gps: gps),
                if (onStopNavigation != null) ...[
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(Icons.close_rounded, color: AppTheme.textPrimary, size: 20),
                      tooltip: 'Stop navigation',
                      onPressed: onStopNavigation,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _StatusRow({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: AppTheme.textSecondary, fontSize: 11),
          ),
        ),
      ],
    );
  }
}

/// Cyan dot (accurate), amber dot (degraded), grey dot (lost).
class _GpsDot extends StatelessWidget {
  final GpsState gps;

  const _GpsDot({required this.gps});

  @override
  Widget build(BuildContext context) {
    final Color color;
    switch (gps) {
      case GpsState.accurate:
        color = AppTheme.neonCyan;
        break;
      case GpsState.updating:
      case GpsState.lowAccuracy:
        color = AppTheme.hyperAmber;
        break;
      case GpsState.unavailable:
        color = AppTheme.offlineGrey;
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [BoxShadow(color: color.withOpacity(0.6), blurRadius: 6, spreadRadius: 1)],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MinimalRideStatsBar
// ---------------------------------------------------------------------------

/// The collapsed sheet handle area: just the 4 key ride numbers rendered as a
/// compact 2 x 2 grid on a frosted glass strip. Tapping anywhere opens the
/// full sheet. The handle notch is centred above the metrics.
class MinimalRideStatsBar extends StatelessWidget {
  final String? remainingText;
  final String etaText;
  final int ridingCount;
  final int totalCount;
  final String? spreadText;
  final VoidCallback onTap;

  const MinimalRideStatsBar({
    super.key,
    required this.remainingText,
    required this.etaText,
    required this.ridingCount,
    required this.totalCount,
    required this.spreadText,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.obsidianVoid.withOpacity(0.88),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              border: Border.all(color: AppTheme.glassBorder, width: 1),

            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 6),
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppTheme.subtleBorder,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // 2 x 2 metric grid
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: _StatCell(
                          value: remainingText ?? '-',
                          label: 'left',
                        ),
                      ),
                      _Divider(),
                      Expanded(
                        child: _StatCell(
                          value: etaText,
                          label: 'ETA',
                          alignEnd: true,
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: _StatCell(
                          value: '$ridingCount/$totalCount',
                          label: 'riding',
                        ),
                      ),
                      _Divider(),
                      Expanded(
                        child: _StatCell(
                          value: spreadText ?? '-',
                          label: 'spread',
                          alignEnd: true,
                        ),
                      ),
                    ],
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

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 32,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: AppTheme.subtleBorder,
    );
  }
}

class _StatCell extends StatelessWidget {
  final String value;
  final String label;
  final bool alignEnd;

  const _StatCell({required this.value, required this.label, this.alignEnd = false});

  @override
  Widget build(BuildContext context) {
    final alignment = alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignment,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: alignEnd ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
          child: Text(
            value,
            maxLines: 1,
            style: AppText.body.copyWith(
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
              fontSize: 17,
              height: 1.1,
            ),
          ),
        ),
        Text(
          label,
          style: AppText.caption.copyWith(
            color: AppTheme.textSecondary,
            fontSize: 11,
          ),
          textAlign: alignEnd ? TextAlign.end : TextAlign.start,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// MinimalStoppedBar
// ---------------------------------------------------------------------------

/// Shown instead of MinimalRideStatsBar while the rider is stopped. Shows
/// how long stopped and a compact "tell why" prompt.
class MinimalStoppedBar extends StatelessWidget {
  final Duration stoppedFor;
  final int nearbyCount;
  final VoidCallback onTap;
  final VoidCallback onTellWhy;

  const MinimalStoppedBar({
    super.key,
    required this.stoppedFor,
    required this.nearbyCount,
    required this.onTap,
    required this.onTellWhy,
  });

  @override
  Widget build(BuildContext context) {
    final mins = stoppedFor.inMinutes;
    final dur = mins < 1 ? 'just stopped' : 'stopped ${mins}m';
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.obsidianVoid.withOpacity(0.88),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              border: Border.all(color: AppTheme.hyperAmber.withOpacity(0.4), width: 1),

            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.hyperAmber.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Icon(Icons.pause_circle_rounded, color: AppTheme.hyperAmber, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            dur,
                            style: AppText.body.copyWith(
                              color: AppTheme.hyperAmber,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            nearbyCount > 0 ? '$nearbyCount riders nearby' : 'Group riding ahead',
                            style: AppText.caption.copyWith(color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: onTellWhy,
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.hyperAmber,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        minimumSize: const Size(64, 44),
                      ),
                      child: const Text('Tell why', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MinimalSpeedAlert
// ---------------------------------------------------------------------------

/// Compact speed-over-limit badge shown below the top bar. Very small
/// footprint: just the number in a red pill.
class MinimalSpeedAlert extends StatelessWidget {
  final double speedKmh;
  final int limitKmh;

  const MinimalSpeedAlert({super.key, required this.speedKmh, required this.limitKmh});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${speedKmh.round()} km/h, group limit $limitKmh km/h',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: StatusColors.critical.withOpacity(0.18),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: StatusColors.critical.withOpacity(0.7), width: 1.5),
          boxShadow: [BoxShadow(color: StatusColors.critical.withOpacity(0.25), blurRadius: 8)],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.speed_rounded, color: StatusColors.critical, size: 16),
            const SizedBox(width: 5),
            Text(
              '${speedKmh.round()} km/h',
              style: AppText.body.copyWith(
                color: StatusColors.critical,
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MapSideControls
// ---------------------------------------------------------------------------

/// Vertical strip of 3 minimal circular icon buttons on the right edge of the
/// map: brightness, re-centre, and sheet-open chevron. They fade out when the
/// sheet is fully expanded.
class MapSideControls extends StatelessWidget {
  final bool keepScreenOn;
  final bool autoFollow;
  final VoidCallback onToggleKeepScreenOn;
  final VoidCallback onCentre;
  final VoidCallback onOpenSheet;
  final bool visible;

  const MapSideControls({
    super.key,
    required this.keepScreenOn,
    required this.autoFollow,
    required this.onToggleKeepScreenOn,
    required this.onCentre,
    required this.onOpenSheet,
    required this.visible,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SideControl(
              icon: keepScreenOn ? Icons.light_mode_rounded : Icons.brightness_low_rounded,
              tooltip: keepScreenOn ? 'Screen stays on' : 'Keep screen on',
              active: keepScreenOn,
              onTap: onToggleKeepScreenOn,
            ),
            const SizedBox(height: 10),
            _SideControl(
              icon: Icons.my_location_rounded,
              tooltip: 'Centre on me',
              active: autoFollow,
              activeTint: AppTheme.neonCyan,
              onTap: onCentre,
            ),
            const SizedBox(height: 10),
            _SideControl(
              icon: Icons.keyboard_arrow_up_rounded,
              tooltip: 'Open ride sheet',
              onTap: onOpenSheet,
            ),
          ],
        ),
      ),
    );
  }
}

class _SideControl extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final Color? activeTint;
  final VoidCallback onTap;

  const _SideControl({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.activeTint,
  });

  @override
  Widget build(BuildContext context) {
    final accent = activeTint ?? AppTheme.hyperAmber;
    return Semantics(
      button: true,
      label: tooltip,
      selected: active,
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? accent.withOpacity(0.18) : AppTheme.slateCard.withOpacity(0.92),
              border: Border.all(
                color: active ? accent : AppTheme.subtleBorder,
                width: active ? 1.8 : 1,
              ),
              boxShadow: [
                BoxShadow(color: AppTheme.shadow.withOpacity(0.5), blurRadius: 8, offset: const Offset(0, 2)),
                if (active)
                  BoxShadow(color: accent.withOpacity(0.3), blurRadius: 10, spreadRadius: 1),
              ],
            ),
            child: Icon(icon, size: 22, color: active ? accent : AppTheme.textPrimary),
          ),
        ),
      ),
    );
  }
}
