import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/config/feature_gates.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../domain/ride/ride_facts.dart';

// ---------------------------------------------------------------------------
// MinimalCockpitTopBar
// ---------------------------------------------------------------------------

/// The floating instruction pill at the top of the map (canvas: card, radius
/// 20, soft shadow): a 60 dp teal square with the navigation icon, the
/// destination or next stop as a 22/800 title with a muted subtitle, and on
/// the right the live speed (32/800 teal, "KM/H", "LIMIT 80" badge). The
/// connection, GPS, tunnel and route status lines sit under the title.
///
/// Strict CoRoute standards: no emoji, pure vector icons, 44 dp minimum tap.
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

  /// Second line under the title (the convoy or road name). Optional.
  final String? subtitle;

  /// Current road or highway name (e.g. "NH 44", "Outer Ring Rd").
  final String? roadName;

  /// My live speed for the right column. Null hides the speed column.
  final double? speedKmh;

  /// The group's speed limit; 0 or null hides the "LIMIT" badge.
  final int? speedLimitKmh;

  /// Live turn-by-turn navigation tap handler.
  final VoidCallback? onNavigationTap;

  /// Number of riders in the convoy for the status pill.
  final int? riderCount;

  /// Whether the smart airbag vest is paired/active.
  final bool isAirbagPaired;

  /// Whether the handlebar BLE remote is paired.
  final bool isRemotePaired;

  const MinimalCockpitTopBar({
    super.key,
    required this.title,
    required this.connection,
    required this.gps,
    this.routeStatus,
    this.emergencyRoute = false,
    this.onStopNavigation,
    this.onBack,
    this.onNavigationTap,
    this.isTunnelCoasting = false,
    this.subtitle,
    this.roadName,
    this.speedKmh,
    this.speedLimitKmh,
    this.riderCount,
    this.isAirbagPaired = false,
    this.isRemotePaired = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasRoute = routeStatus != null;
    final back = onBack;
    final speed = speedKmh;
    final limit = speedLimitKmh ?? 0;
    final overLimit = speed != null && limit > 0 && speed > limit;
    final sub = subtitle;
    final isSunlightHud = FeatureGates.isUnlocked(Feature.sunlightHudMode);

    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(20),
        border: overLimit
            ? Border.all(color: AppTheme.sos, width: isSunlightHud ? 3 : 2)
            : (isSunlightHud ? Border.all(color: AppTheme.border.withOpacity(0.9), width: 2) : null),
        boxShadow: dsFloatingShadow(),
      ),
      child: Row(
        children: [
          if (back != null)
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.card,
                border: Border.all(
                  color: isSunlightHud ? AppTheme.text : AppTheme.border,
                  width: isSunlightHud ? 2.5 : 2,
                ),
              ),
              child: IconButton(
                padding: EdgeInsets.zero,
                icon: Icon(Icons.chevron_left_rounded, color: AppTheme.text, size: 28),
                tooltip: 'Back',
                onPressed: back,
              ),
            )
          else
            GestureDetector(
              key: const Key('top_bar_navigation_action'),
              onTap: onNavigationTap,
              child: Container(
                width: 60,
                height: 60,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: emergencyRoute ? AppTheme.sos : AppTheme.brand,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  emergencyRoute ? Icons.emergency_rounded : Icons.navigation_rounded,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Primary: destination / next stop / convoy name
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.headline,
                ),
                if (roadName != null && roadName!.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: AppTheme.brand.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: AppTheme.brand.withValues(alpha: 0.4), width: 1),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.edit_road_rounded, size: 12, color: AppTheme.brand),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  roadName!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.caption.copyWith(
                                    color: AppTheme.brand,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (sub != null && sub.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.label,
                          ),
                        ),
                      ],
                    ],
                  ),
                ] else if (sub != null && sub.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
                ],
                // Minimal status pills across top status bar:
                // [ 🟢 Live · N Riders ] [ 🦺 Airbag ] [ 🔘 Remote ] [ 🚇 Tunnel Mode ]
                const SizedBox(height: 5),
                CockpitStatusPillsBar(
                  riderCount: riderCount,
                  isLive: connection == null,
                  connectionStatus: connection,
                  isAirbagPaired: isAirbagPaired,
                  isRemotePaired: isRemotePaired,
                  isTunnelMode: isTunnelCoasting,
                ),
                if (hasRoute && !isTunnelCoasting) ...[
                  const SizedBox(height: 3),
                  _StatusRow(
                    icon: emergencyRoute ? Icons.emergency_rounded : Icons.alt_route_rounded,
                    label: routeStatus!,
                    color: emergencyRoute ? AppTheme.sos : AppTheme.accentText,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Right: Big bold speed readout in high-contrast neon white/orange
          if (speed != null)
            CockpitSpeedometer(
              speedKmh: speed,
              speedLimitKmh: speedLimitKmh,
            )
          else
            _GpsDot(gps: gps),
          if (onStopNavigation != null) ...[
            const SizedBox(width: 6),
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSunlightHud ? AppTheme.card : AppTheme.card.withOpacity(0.9),
                border: Border.all(
                  color: isSunlightHud ? AppTheme.sos : AppTheme.border,
                  width: isSunlightHud ? 2.5 : 2,
                ),
              ),
              child: IconButton(
                padding: EdgeInsets.zero,
                icon: Icon(Icons.close_rounded, color: isSunlightHud ? AppTheme.sos : AppTheme.text, size: 26),
                tooltip: 'Stop navigation',
                onPressed: onStopNavigation,
              ),
            ),
          ],
        ],
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
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: color, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

/// Teal dot (accurate), amber dot (degraded), grey dot (lost).
class _GpsDot extends StatelessWidget {
  final GpsState gps;

  const _GpsDot({required this.gps});

  @override
  Widget build(BuildContext context) {
    final Color color;
    switch (gps) {
      case GpsState.accurate:
        color = AppTheme.accentText;
        break;
      case GpsState.updating:
      case GpsState.lowAccuracy:
        color = AppTheme.warnText;
        break;
      case GpsState.unavailable:
        color = AppTheme.muted;
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(color: AppTheme.card, width: 2),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CockpitStatusPillsBar
// ---------------------------------------------------------------------------

/// Minimal status pills across the top status bar for motorcycle cockpit glancability.
/// Displays:
/// - [ 🟢 Live · N Riders ]
/// - [ 🦺 Airbag ] (when paired)
/// - [ 🔘 Remote ] (when paired)
/// - [ 🚇 Tunnel Mode ] (when dead-reckoning)
class CockpitStatusPillsBar extends StatelessWidget {
  final int? riderCount;
  final bool isLive;
  final String? connectionStatus;
  final bool isAirbagPaired;
  final bool isRemotePaired;
  final bool isTunnelMode;
  final bool forceShowAll;
  final VoidCallback? onRidersTap;
  final VoidCallback? onAirbagTap;
  final VoidCallback? onRemoteTap;
  final VoidCallback? onTunnelTap;

  const CockpitStatusPillsBar({
    super.key,
    this.riderCount,
    this.isLive = true,
    this.connectionStatus,
    this.isAirbagPaired = false,
    this.isRemotePaired = false,
    this.isTunnelMode = false,
    this.forceShowAll = false,
    this.onRidersTap,
    this.onAirbagTap,
    this.onRemoteTap,
    this.onTunnelTap,
  });

  @override
  Widget build(BuildContext context) {
    final pills = <Widget>[];

    // 1. [ Live · N Riders ]
    final count = riderCount ?? 1;
    final countText = count == 1 ? '1 Rider' : '$count Riders';
    final liveText = connectionStatus != null ? connectionStatus! : 'Live · $countText';
    final liveColor = connectionStatus != null ? const Color(0xFFFF9100) : const Color(0xFF00E676);

    pills.add(
      _StatusPill(
        key: const Key('cockpit_pill_live_riders'),
        iconDot: liveColor,
        label: liveText,
        onTap: onRidersTap,
      ),
    );

    // 2. [ Airbag ] (when paired or forced)
    if (isAirbagPaired || forceShowAll) {
      pills.add(
        _StatusPill(
          key: const Key('cockpit_pill_airbag'),
          icon: Icons.shield_rounded,
          iconColor: const Color(0xFFFF9100),
          label: 'Airbag',
          accentColor: const Color(0xFFFF9100).withOpacity(0.4),
          onTap: onAirbagTap,
        ),
      );
    }

    // 3. [ Remote ] (when paired or forced)
    if (isRemotePaired || forceShowAll) {
      pills.add(
        _StatusPill(
          key: const Key('cockpit_pill_remote'),
          icon: Icons.radio_button_checked_rounded,
          iconColor: const Color(0xFF00E5FF),
          label: 'Remote',
          accentColor: const Color(0xFF00E5FF).withOpacity(0.4),
          onTap: onRemoteTap,
        ),
      );
    }

    // 4. [ Tunnel Mode ] (when dead-reckoning or forced)
    if (isTunnelMode || forceShowAll) {
      pills.add(
        _StatusPill(
          key: const Key('cockpit_pill_tunnel_mode'),
          icon: Icons.alt_route_rounded,
          iconColor: const Color(0xFFFFB300),
          label: 'Tunnel Mode',
          accentColor: const Color(0xFFFFB300).withOpacity(0.5),
          onTap: onTunnelTap,
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < pills.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            pills[i],
          ],
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final Color? iconDot;
  final IconData? icon;
  final Color? iconColor;
  final String label;
  final Color? accentColor;
  final VoidCallback? onTap;

  const _StatusPill({
    super.key,
    this.iconDot,
    this.icon,
    this.iconColor,
    required this.label,
    this.accentColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF131722),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: accentColor ?? AppTheme.border.withOpacity(0.6),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (iconDot != null) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: iconDot,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: iconDot!.withOpacity(0.6),
                        blurRadius: 4,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 5),
              ] else if (icon != null) ...[
                Icon(icon, size: 12, color: iconColor ?? AppTheme.text),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MinimalRideStatsBar
// ---------------------------------------------------------------------------

/// The collapsed sheet handle area: the 4 key ride numbers as stat cells on
/// a floating card. Tapping anywhere opens the full sheet.
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
    final isSunlightHud = FeatureGates.isUnlocked(Feature.sunlightHudMode);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(Radii.xl),
          border: isSunlightHud ? Border.all(color: AppTheme.border.withOpacity(0.9), width: 1.5) : null,
          boxShadow: dsFloatingShadow(),
        ),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 5,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(color: AppTheme.border2, borderRadius: BorderRadius.circular(3)),
            ),
            Row(
              children: [
                Expanded(child: DsStatCell(label: 'Left', value: remainingText ?? '-')),
                const SizedBox(width: 8),
                Expanded(child: DsStatCell(label: 'ETA', value: etaText)),
                const SizedBox(width: 8),
                Expanded(child: DsStatCell(label: 'Riding', value: '$ridingCount/$totalCount')),
                const SizedBox(width: 8),
                Expanded(child: DsStatCell(label: 'Spread', value: spreadText ?? '-')),
              ],
            ),
          ],
        ),
      ),
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
    final isSunlightHud = FeatureGates.isUnlocked(Feature.sunlightHudMode);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(Radii.xl),
          border: Border.all(color: AppTheme.warnBorder, width: isSunlightHud ? 2.5 : 2),
          boxShadow: dsFloatingShadow(),
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 5,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(color: AppTheme.warnBorder, borderRadius: BorderRadius.circular(3)),
            ),
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: AppTheme.warnTint, borderRadius: BorderRadius.circular(12)),
                  child: Icon(Icons.pause_rounded, color: AppTheme.warnText, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dur,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.title.copyWith(color: AppTheme.warnText),
                      ),
                      Text(
                        nearbyCount > 0 ? '$nearbyCount riders nearby' : 'Group riding ahead',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.label,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: onTellWhy,
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.warnText,
                    backgroundColor: AppTheme.warnTint,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    minimumSize: const Size(64, 48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Tell why', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MinimalSpeedAlert
// ---------------------------------------------------------------------------

/// Compact speed-near-limit chip shown below the top pill. Amber while
/// close to the group limit, red once over it.
class MinimalSpeedAlert extends StatelessWidget {
  final double speedKmh;
  final int limitKmh;

  const MinimalSpeedAlert({super.key, required this.speedKmh, required this.limitKmh});

  @override
  Widget build(BuildContext context) {
    final over = speedKmh > limitKmh;
    final fg = over ? AppTheme.sos : AppTheme.warnText;
    final bg = over ? AppTheme.sos.withOpacity(0.12) : AppTheme.warnTint;
    final border = over ? AppTheme.sos.withOpacity(0.5) : AppTheme.warnBorder;
    return Semantics(
      label: '${speedKmh.round()} km/h, group limit $limitKmh km/h',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: border, width: 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.speed_rounded, color: fg, size: 16),
            const SizedBox(width: 6),
            Text(
              '${speedKmh.round()} km/h',
              style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 13),
            ),
            const SizedBox(width: 6),
            Text(
              'LIMIT $limitKmh',
              style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 0.5),
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

/// Vertical strip of 3 round card buttons on the right edge of the map:
/// screen-on, re-centre, and sheet-open chevron. They fade out when the
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
              activeTint: AppTheme.warnText,
              onTap: onToggleKeepScreenOn,
            ),
            const SizedBox(height: 12),
            _SideControl(
              icon: Icons.my_location_rounded,
              tooltip: 'Centre on me',
              active: autoFollow,
              onTap: onCentre,
            ),
            const SizedBox(height: 12),
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

/// 56 dp round card button with a 2-2.5 px border; the active state uses the
/// accent ring and tint (canvas "round button"). Ergonomically upscaled to 56x56 dp
/// for effortless motorcycle leather glove operation on vibrating handlebars.
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
    final accent = activeTint ?? AppTheme.accentText;
    final isSunlightHud = FeatureGates.isUnlocked(Feature.sunlightHudMode);
    return Semantics(
      button: true,
      label: tooltip,
      selected: active,
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? (isSunlightHud ? accent.withOpacity(0.24) : accent.withOpacity(0.14))
                  : AppTheme.card,
              border: Border.all(
                color: active ? accent : (isSunlightHud ? AppTheme.border.withOpacity(0.9) : AppTheme.border),
                width: isSunlightHud ? 2.5 : 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.shadow.withOpacity(AppTheme.isLight ? 0.16 : 0.5),
                  blurRadius: isSunlightHud ? 14 : 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(icon, size: 26, color: active ? accent : AppTheme.text),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CockpitSpeedometer
// ---------------------------------------------------------------------------

/// Clean, high-contrast HUD speedometer component for motorcycle cockpits.
///
/// Features a big bold readout with tabular figures, dynamic glow based on speed
/// thresholds, crisp "KM/H" unit label, and speed limit badge.
class CockpitSpeedometer extends StatelessWidget {
  final double speedKmh;
  final int? speedLimitKmh;
  final double fontSize;
  final bool showUnit;
  final bool showLimitBadge;
  final Alignment alignment;

  const CockpitSpeedometer({
    super.key,
    required this.speedKmh,
    this.speedLimitKmh,
    this.fontSize = 38,
    this.showUnit = true,
    this.showLimitBadge = true,
    this.alignment = Alignment.centerRight,
  });

  @override
  Widget build(BuildContext context) {
    final limit = speedLimitKmh ?? 0;
    final overLimit = limit > 0 && speedKmh > limit;
    final isNearLimit = limit > 0 && speedKmh >= (limit - 5) && !overLimit;
    final Color speedColor = overLimit
        ? const Color(0xFFFF3D00)
        : (isNearLimit ? const Color(0xFFFF9100) : (AppTheme.isLight ? AppTheme.text : const Color(0xFFFFFFFF)));

    final crossAxis = alignment == Alignment.center
        ? CrossAxisAlignment.center
        : (alignment == Alignment.centerLeft ? CrossAxisAlignment.start : CrossAxisAlignment.end);

    return Semantics(
      label: '${speedKmh.round()} km/h${limit > 0 ? ', limit $limit km/h' : ''}',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: crossAxis,
        children: [
          Text(
            '${speedKmh.round()}',
            style: TextStyle(
              color: speedColor,
              fontSize: fontSize,
              fontWeight: FontWeight.w900,
              letterSpacing: -1.2,
              height: 1.0,
              fontFeatures: const [FontFeature.tabularFigures()],
              shadows: [
                Shadow(
                  color: speedColor.withOpacity(overLimit || isNearLimit ? 0.6 : 0.25),
                  blurRadius: overLimit || isNearLimit ? 10 : 4,
                ),
              ],
            ),
          ),
          if (showUnit)
            Text(
              'KM/H',
              style: TextStyle(
                color: overLimit
                    ? const Color(0xFFFF6E40)
                    : (isNearLimit ? const Color(0xFFFFB74D) : const Color(0xFFB0BEC5)),
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          if (showLimitBadge && limit > 0) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: overLimit
                    ? const Color(0xFFFF3D00)
                    : (isNearLimit ? const Color(0xFFFF9100).withOpacity(0.25) : AppTheme.tint),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: overLimit
                      ? Colors.white
                      : (isNearLimit ? const Color(0xFFFF9100) : AppTheme.accentText.withOpacity(0.3)),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (overLimit) ...[
                    const Icon(Icons.warning_amber_rounded, size: 12, color: Colors.white),
                    const SizedBox(width: 3),
                  ],
                  Text(
                    overLimit ? 'OVER $limit' : 'LIMIT $limit',
                    style: TextStyle(
                      color: overLimit
                          ? Colors.white
                          : (isNearLimit ? const Color(0xFFFF9100) : AppTheme.accentText),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

typedef MinimalCockpitSpeedometer = CockpitSpeedometer;

// ---------------------------------------------------------------------------
// CockpitSosButton (Glove-Friendly SOS Button)
// ---------------------------------------------------------------------------

/// Clean, high-contrast, glove-friendly SOS button for motorcycle cockpit overlays.
///
/// Ergonomically sized (minimum 56x56 dp, default 60 dp) for thick motorcycle
/// leather gloves and bumpy handlebar mounts. Features prominent high-contrast
/// emergency styling, subtle pulse/glow, and press-and-hold activation to
/// prevent accidental false alarms while riding.
class CockpitSosButton extends StatefulWidget {
  final VoidCallback onTriggered;
  final double size;
  final Duration holdDuration;
  final bool showLabel;

  const CockpitSosButton({
    super.key,
    required this.onTriggered,
    this.size = 60.0,
    this.holdDuration = const Duration(milliseconds: 1500),
    this.showLabel = false,
  });

  @override
  State<CockpitSosButton> createState() => _CockpitSosButtonState();
}

class _CockpitSosButtonState extends State<CockpitSosButton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.holdDuration,
    reverseDuration: const Duration(milliseconds: 200),
  )..addStatusListener(_onStatus);

  bool _fired = false;

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_fired) {
      _fired = true;
      _trigger();
    }
  }

  void _trigger() {
    HapticFeedback.heavyImpact();
    widget.onTriggered();
  }

  void _down() {
    _fired = false;
    _controller.forward(from: 0);
  }

  void _release() {
    if (_fired) {
      _controller.value = 0;
    } else if (_controller.value > 0 || _controller.isAnimating) {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Strictly enforce 56 dp minimum dimension for motorcycle glove safety
    final effectiveSize = widget.size < 56.0 ? 56.0 : widget.size;
    final ringSize = effectiveSize + 12;
    final isSunlightHud = FeatureGates.isUnlocked(Feature.sunlightHudMode);

    return Semantics(
      container: true,
      button: true,
      label: 'Emergency SOS, press and hold',
      hint: 'Press and hold to send SOS to convoy',
      excludeSemantics: true,
      onLongPress: _trigger,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _down(),
        onTapUp: (_) => _release(),
        onTapCancel: _release,
        child: SizedBox(
          width: ringSize,
          height: ringSize,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => _controller.value == 0
                    ? const SizedBox.shrink()
                    : SizedBox(
                        width: ringSize,
                        height: ringSize,
                        child: CircularProgressIndicator(
                          value: _controller.value,
                          strokeWidth: 4,
                          color: AppTheme.sos,
                          backgroundColor: AppTheme.sos.withOpacity(0.25),
                        ),
                      ),
              ),
              Container(
                width: effectiveSize,
                height: effectiveSize,
                constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.sos,
                  border: Border.all(
                    color: Colors.white,
                    width: isSunlightHud ? 2.5 : 2.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.sos.withOpacity(0.5),
                      blurRadius: isSunlightHud ? 14 : 10,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.emergency_rounded,
                      color: Colors.white,
                      size: 26,
                    ),
                    if (widget.showLabel) ...[
                      const SizedBox(height: 1),
                      const Text(
                        'SOS',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef GloveFriendlySosButton = CockpitSosButton;
typedef MinimalCockpitSosButton = CockpitSosButton;
