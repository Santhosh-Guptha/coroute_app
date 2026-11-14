import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import 'hud_top.dart' show kHudGlove;

/// Round 11 ride HUD: the right-side map control column (every button 56 dp, glove sized).
///
/// One pill: map orientation (north up / heading up), map layers (the places sheet, with "where
/// riders stop"), night map, group view (fit all riders). Under it, only when useful: Recenter
/// (when the map was panned away), zoom in / out (when there is room). The ride chat button, talk
/// and SOS stay where they are: SOS is never in this column or in any menu.
class HudControlColumn extends StatelessWidget {
  const HudControlColumn({
    super.key,
    required this.headingUp,
    required this.onToggleOrientation,
    required this.following,
    required this.onRecenter,
    this.onLayers,
    required this.night,
    required this.onToggleNight,
    this.onFitGroup,
    this.onZoomIn,
    this.onZoomOut,
    this.showZoom = true,
    this.leading,
  });

  final bool headingUp;
  final VoidCallback onToggleOrientation;
  final bool following;
  final VoidCallback onRecenter;
  final VoidCallback? onLayers;
  final bool night;
  final VoidCallback onToggleNight;

  /// Null in a solo ride (nothing to fit).
  final VoidCallback? onFitGroup;
  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;
  final bool showZoom;

  /// Extra control above the pill (the ride chat button in a group ride).
  final Widget? leading;

  /// Height of the column for a given set of buttons (the cockpit checks the room it has).
  static double heightFor({required bool group, required bool recenter, required bool zoom, bool leading = false}) {
    const gap = Space.s8;
    var h = kHudGlove * (group ? 4 : 3);
    if (recenter) h += gap + kHudGlove;
    if (zoom) h += gap + kHudGlove * 2;
    if (leading) h += gap + kHudGlove;
    return h;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, const SizedBox(height: Space.s8)],
          _Pill(children: [
            HudControlButton(
              key: const Key('hud_orientation'),
              icon: headingUp ? Icons.navigation_rounded : Icons.explore_outlined,
              tooltip: headingUp ? 'Heading up. Tap for north up' : 'North up. Tap for heading up',
              active: headingUp,
              onTap: onToggleOrientation,
            ),
            if (onLayers != null)
              HudControlButton(key: const Key('hud_layers'), icon: Icons.layers_outlined, tooltip: 'Map layers', onTap: onLayers),
            HudControlButton(
              key: const Key('hud_night'),
              icon: night ? Icons.dark_mode_rounded : Icons.light_mode_outlined,
              tooltip: night ? 'Night map on. Tap for day map' : 'Day map. Tap for night map',
              active: night,
              onTap: onToggleNight,
            ),
            if (onFitGroup != null)
              HudControlButton(key: const Key('hud_fit_group'), icon: Icons.groups_outlined, tooltip: 'Show all riders', onTap: onFitGroup),
          ]),
          if (!following) ...[
            const SizedBox(height: Space.s8),
            _Pill(filled: true, children: [
              HudControlButton(key: const Key('hud_recenter'), icon: Icons.my_location_rounded, tooltip: 'Recenter on me', onTap: onRecenter, onFill: true),
            ]),
          ],
          if (showZoom && onZoomIn != null && onZoomOut != null) ...[
            const SizedBox(height: Space.s8),
            _Pill(children: [
              HudControlButton(key: const Key('cockpit_zoom_in_button'), icon: Icons.add_rounded, tooltip: 'Zoom in', onTap: onZoomIn),
              HudControlButton(key: const Key('cockpit_zoom_out_button'), icon: Icons.remove_rounded, tooltip: 'Zoom out', onTap: onZoomOut),
            ]),
          ],
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.children, this.filled = false});
  final List<Widget> children;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: kHudGlove,
      decoration: BoxDecoration(
        color: filled ? AppTheme.primary : AppTheme.card,
        borderRadius: BorderRadius.circular(kHudGlove / 2),
        border: Border.all(color: filled ? AppTheme.primary : AppTheme.border),
        boxShadow: dsFloatingShadow(),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(type: MaterialType.transparency, child: Column(mainAxisSize: MainAxisSize.min, children: children)),
    );
  }
}

class HudControlButton extends StatelessWidget {
  const HudControlButton({super.key, required this.icon, required this.tooltip, required this.onTap, this.active = false, this.onFill = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  /// Drawn on a primary fill (Recenter).
  final bool onFill;

  @override
  Widget build(BuildContext context) {
    final fg = onFill ? AppTheme.onPrimary : (active ? AppTheme.primary : AppTheme.text);
    return Semantics(
      button: true,
      selected: active,
      label: tooltip,
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: kHudGlove,
            height: kHudGlove,
            child: Center(
              child: active && !onFill
                  ? Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: AppTheme.primarySoft, shape: BoxShape.circle),
                      child: Icon(icon, size: 24, color: fg),
                    )
                  : Icon(icon, size: 24, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}
