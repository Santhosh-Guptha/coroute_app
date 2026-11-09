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

  /// Whether the app is operating in offline mode (traffic/weather unavailable).
  final bool isOfflineMode;

  /// Optional tap handler for offline mode indicator.
  final VoidCallback? onOfflineModeTap;

  /// Whether the trip has only 1 participant (solo trip).
  final bool isSolo;

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
    this.isOfflineMode = false,
    this.onOfflineModeTap,
    this.isSolo = false,
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
    final hasSecondaryPills = isAirbagPaired || isRemotePaired || isTunnelCoasting || isOfflineMode;

    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: overLimit
            ? Border.all(color: AppTheme.sos, width: isSunlightHud ? 3 : 2)
            : (isSunlightHud ? Border.all(color: AppTheme.border.withValues(alpha: 0.9), width: 2) : null),
        boxShadow: dsFloatingShadow(),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (back != null)
                Tooltip(
                  message: 'Back',
                  child: InkWell(
                    onTap: back,
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppTheme.card,
                        border: Border.all(
                          color: isSunlightHud ? AppTheme.text : AppTheme.border,
                          width: isSunlightHud ? 2.0 : 1.5,
                        ),
                      ),
                      child: Icon(Icons.chevron_left_rounded, color: AppTheme.text, size: 24),
                    ),
                  ),
                )
              else
                GestureDetector(
                  key: const Key('top_bar_navigation_action'),
                  onTap: onNavigationTap,
                  child: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: emergencyRoute ? AppTheme.sos : AppTheme.brand,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      emergencyRoute ? Icons.emergency_rounded : Icons.navigation_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Primary: Destination & total distance
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.title.copyWith(
                        fontSize: 15,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (roadName != null && roadName!.isNotEmpty) ...[
                          // Flexible (it used to be flex 0): a long road name ellipsizes
                          // instead of overflowing the top bar on narrow phones.
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              margin: const EdgeInsets.only(right: 6),
                              decoration: BoxDecoration(
                                color: AppTheme.brand.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(color: AppTheme.brand.withValues(alpha: 0.4), width: 1),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.edit_road_rounded, size: 11, color: AppTheme.brand),
                                  const SizedBox(width: 3),
                                  Flexible(
                                    child: Text(
                                      roadName!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppText.caption.copyWith(
                                        color: AppTheme.brand,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                        if (sub != null && sub.isNotEmpty) ...[
                          Flexible(
                            child: Text(
                              sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.caption.copyWith(
                                color: AppTheme.textMuted,
                                fontWeight: FontWeight.w600,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        // Live rider count badge (hidden for solo trips)
                        if (!isSolo && (riderCount ?? 1) > 1)
                          Flexible(
                            child: _StatusPill(
                              key: const Key('cockpit_pill_live_riders'),
                              iconDot: connection != null ? AppTheme.accent : AppTheme.success,
                              label: connection != null
                                  ? connection!
                                  : '${riderCount ?? 1} Riders',
                              ellipsize: true,
                            ),
                          )
                        else if (connection != null)
                          Flexible(
                            child: _StatusPill(
                              key: const Key('cockpit_pill_live_riders'),
                              iconDot: AppTheme.accent,
                              label: connection!,
                              ellipsize: true,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Right: Speed readout or GPS dot
              if (speed != null)
                CockpitSpeedometer(
                  speedKmh: speed,
                  speedLimitKmh: speedLimitKmh,
                  fontSize: 24,
                  showUnit: true,
                  showLimitBadge: limit > 0,
                )
              else
                _GpsDot(gps: gps),
              if (onStopNavigation != null) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Stop navigation',
                  child: InkWell(
                    onTap: onStopNavigation,
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSunlightHud ? AppTheme.card : AppTheme.card.withValues(alpha: 0.9),
                        border: Border.all(
                          color: isSunlightHud ? AppTheme.sos : AppTheme.border,
                          width: isSunlightHud ? 2.0 : 1.5,
                        ),
                      ),
                      child: Icon(Icons.close_rounded,
                          color: isSunlightHud ? AppTheme.sos : AppTheme.text, size: 20),
                    ),
                  ),
                ),
              ],
            ],
          ),
          // Secondary status pills tray in disciplined vertical flow
          if (hasSecondaryPills) ...[
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isAirbagPaired) ...[
                    _StatusPill(
                      key: const Key('cockpit_pill_airbag'),
                      icon: Icons.shield_rounded,
                      iconColor: AppTheme.accent,
                      label: 'Airbag',
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (isRemotePaired) ...[
                    _StatusPill(
                      key: const Key('cockpit_pill_remote'),
                      icon: Icons.radio_button_checked_rounded,
                      iconColor: AppTheme.primary,
                      label: 'Remote',
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (isTunnelCoasting) ...[
                    _StatusPill(
                      key: const Key('cockpit_pill_tunnel_mode'),
                      icon: Icons.alt_route_rounded,
                      iconColor: AppTheme.warning,
                      label: 'Tunnel Mode',
                      accentColor: AppTheme.warnBorder,
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (isOfflineMode) ...[
                    _StatusPill(
                      key: const Key('cockpit_pill_offline_mode'),
                      icon: Icons.cloud_off_rounded,
                      iconColor: AppTheme.warning,
                      label: 'Offline Mode',
                      accentColor: AppTheme.warnBorder,
                      onTap: onOfflineModeTap,
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ],
          if (hasRoute && !isTunnelCoasting) ...[
            const SizedBox(height: 4),
            _StatusRow(
              icon: emergencyRoute ? Icons.emergency_rounded : Icons.alt_route_rounded,
              label: routeStatus!,
              color: emergencyRoute ? AppTheme.sos : AppTheme.accentText,
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

class _StatusPill extends StatelessWidget {
  final Color? iconDot;
  final IconData? icon;
  final Color? iconColor;
  final String label;
  final Color? accentColor;
  final VoidCallback? onTap;

  /// Shrinks and ellipsizes the label when its parent gives it a bounded
  /// width (a Flexible in a row). Leave false inside horizontal scrollers,
  /// where the width is unbounded.
  final bool ellipsize;

  const _StatusPill({
    super.key,
    this.iconDot,
    this.icon,
    this.iconColor,
    required this.label,
    this.accentColor,
    this.onTap,
    this.ellipsize = false,
  });

  static TextStyle get _labelStyle => TextStyle(
        color: AppTheme.text,
        fontSize: 11,
        fontWeight: FontWeight.w500,
      );

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
            color: AppTheme.card,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: accentColor ?? AppTheme.border,
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
                  ),
                ),
                const SizedBox(width: 5),
              ] else if (icon != null) ...[
                Icon(icon, size: 12, color: iconColor ?? AppTheme.text),
                const SizedBox(width: 4),
              ],
              if (ellipsize)
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _labelStyle,
                  ),
                )
              else
                Text(label, style: _labelStyle),
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

// ---------------------------------------------------------------------------
// MinimalStoppedBar
// ---------------------------------------------------------------------------

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
              style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(width: 6),
            Text(
              'LIMIT $limitKmh',
              style: TextStyle(color: fg, fontWeight: FontWeight.w500, fontSize: 11),
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
    this.fontSize = 28,
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
        ? AppTheme.danger
        : (isNearLimit ? AppTheme.warnText : AppTheme.text);

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
              fontWeight: FontWeight.w700,
              height: 1.0,
              fontFeatures: const [FontFeature.tabularFigures()],
              // A faint legibility halo over the map, not a glow.
              shadows: [
                Shadow(color: AppTheme.bg.withValues(alpha: 0.6), blurRadius: 3),
              ],
            ),
          ),
          if (showUnit)
            Text(
              'km/h',
              style: TextStyle(
                color: overLimit ? AppTheme.danger : (isNearLimit ? AppTheme.warnText : AppTheme.textMuted),
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
            ),
          if (showLimitBadge && limit > 0) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: overLimit ? AppTheme.danger : (isNearLimit ? AppTheme.warnTint : AppTheme.tint),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: overLimit ? AppTheme.danger : (isNearLimit ? AppTheme.warnBorder : Colors.transparent),
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
                    overLimit ? 'Over $limit' : 'Limit $limit',
                    style: TextStyle(
                      color: overLimit ? Colors.white : (isNearLimit ? AppTheme.warnText : AppTheme.accentText),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
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
      hint: 'Press and hold to send SOS to your group',
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
                  // Strong red stays; the soft shadow only lifts it off the map.
                  boxShadow: [
                    BoxShadow(color: AppTheme.shadow, blurRadius: 8, offset: const Offset(0, 2)),
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
                          fontWeight: FontWeight.w700,
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

