import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../domain/route/next_turn.dart' as nt;
import 'hud_logic.dart';

/// Round 11 ride HUD: the top of the ride screen.
///
/// * [HudTopBar]   56 dp back button + destination pill (tap: route options) + status chips.
/// * [HudTurnCard] the big turn card: arrow, live distance, instruction with the road name, the
///                 "then ..." line, the road's limit sign at the end; without a route it shows the
///                 road I am on and the limit sign (round 7) instead. Lanes are never invented.

/// Glove-sized control edge (dp) for everything the rider taps while riding.
const double kHudGlove = 56;

IconData hudTurnIcon(HudTurnDir d) => switch (d) {
      HudTurnDir.straight => Icons.straight_rounded,
      HudTurnDir.slightLeft => Icons.turn_slight_left_rounded,
      HudTurnDir.left => Icons.turn_left_rounded,
      HudTurnDir.sharpLeft => Icons.turn_sharp_left_rounded,
      HudTurnDir.slightRight => Icons.turn_slight_right_rounded,
      HudTurnDir.right => Icons.turn_right_rounded,
      HudTurnDir.sharpRight => Icons.turn_sharp_right_rounded,
      HudTurnDir.uTurn => Icons.u_turn_left_rounded,
    };

/// The route engine's direction as the HUD's (same names).
HudTurnDir hudDirOf(nt.TurnDirection d) => HudTurnDir.values.byName(d.name);

/// What the turn card shows (built by the cockpit once per position update).
class HudTurnModel {
  const HudTurnModel.turn({required this.direction, required this.distanceM, required this.road, this.thenLine, this.thenDirection})
      : free = false,
        title = null,
        subtitle = null;

  /// Following a route without a known next step: "Continue on NH 44", distance to the next stop.
  const HudTurnModel.follow({required String this.title, this.distanceM, this.subtitle})
      : free = false,
        direction = HudTurnDir.straight,
        road = '',
        thenLine = null,
        thenDirection = null;

  /// No route: the road I am on.
  const HudTurnModel.free({required String this.title, this.subtitle})
      : free = true,
        direction = HudTurnDir.straight,
        distanceM = null,
        road = '',
        thenLine = null,
        thenDirection = null;

  final bool free;
  final HudTurnDir direction;
  final double? distanceM;
  final String road;
  final String? thenLine;
  final HudTurnDir? thenDirection;
  final String? title;
  final String? subtitle;

  /// Builds the model from the route engine's next turns.
  static HudTurnModel fromTurns(List<nt.NextTurn> turns) {
    final a = turns.first;
    final then = HudTurnText.thenLine([for (final t in turns) (direction: hudDirOf(t.direction), distanceM: t.distanceM, road: t.road)]);
    return HudTurnModel.turn(
      direction: hudDirOf(a.direction),
      distanceM: a.distanceM,
      road: a.road,
      thenLine: then,
      thenDirection: then == null || turns.length < 2 ? null : hudDirOf(turns[1].direction),
    );
  }
}

class HudTopBar extends StatelessWidget {
  const HudTopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.onBack,
    this.onRouteOptions,
    this.connection,
    this.emergencyRoute = false,
    this.chips = const [],
  });

  /// "Gandikota", "Next: Fuel stop", or the ride's name.
  final String title;

  /// "386 km · 9:03 pm".
  final String? subtitle;
  final VoidCallback? onBack;

  /// Change destination, add a stop, share ETA (opens the route options sheet).
  final VoidCallback? onRouteOptions;

  /// "Reconnecting" etc.; null when connected.
  final String? connection;
  final bool emergencyRoute;

  /// Small status chips under the pill (airbag, remote, tunnel, offline mode).
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final back = onBack;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (back != null) ...[
              _HudRoundButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onTap: back, buttonKey: const Key('hud_back_button')),
              const SizedBox(width: Space.s8),
            ],
            Expanded(
              child: Semantics(
                button: onRouteOptions != null,
                label: 'Route: $title${subtitle == null ? '' : ', $subtitle'}. Route options',
                excludeSemantics: true,
                child: Material(
                  color: AppTheme.card,
                  shape: StadiumBorder(side: BorderSide(color: AppTheme.border)),
                  elevation: 0,
                  shadowColor: AppTheme.shadow,
                  child: InkWell(
                    key: const Key('hud_destination_pill'),
                    customBorder: const StadiumBorder(),
                    onTap: onRouteOptions,
                    child: Container(
                      constraints: const BoxConstraints(minHeight: kHudGlove),
                      padding: const EdgeInsets.only(left: Space.s16, right: Space.s8),
                      decoration: BoxDecoration(boxShadow: dsFloatingShadow(), borderRadius: BorderRadius.circular(999)),
                      child: Row(
                        children: [
                          Icon(emergencyRoute ? Icons.emergency_rounded : Icons.flag_outlined,
                              size: 22, color: emergencyRoute ? AppTheme.sos : AppTheme.primary),
                          const SizedBox(width: Space.s8),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(height: 1.2)),
                                if (subtitle != null || connection != null)
                                  Text(
                                    connection ?? subtitle!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppText.caption.copyWith(
                                      color: connection != null ? AppTheme.accentStrong : AppTheme.textMuted,
                                      fontWeight: connection != null ? FontWeight.w600 : FontWeight.w400,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (onRouteOptions != null) Icon(Icons.expand_more_rounded, color: AppTheme.textMuted, size: 24),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: Space.s8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [for (var i = 0; i < chips.length; i++) ...[if (i > 0) const SizedBox(width: Space.s8), chips[i]]]),
          ),
        ],
      ],
    );
  }
}

/// A small status chip for the top bar ("Airbag", "Tunnel mode", "Offline").
class HudStatusChip extends StatelessWidget {
  const HudStatusChip({super.key, required this.icon, required this.label, this.warn = false, this.onTap});

  final IconData icon;
  final String label;
  final bool warn;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = warn ? AppTheme.accentStrong : AppTheme.primary;
    return Material(
      color: warn ? AppTheme.accentSoft : AppTheme.card,
      shape: StadiumBorder(side: BorderSide(color: warn ? AppTheme.warnBorder : AppTheme.border)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: Space.s12),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: Space.s4),
            Text(label, style: AppText.caption.copyWith(color: fg, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

class HudTurnCard extends StatelessWidget {
  const HudTurnCard({
    super.key,
    required this.model,
    this.limitSign,
    this.routeStatus,
    this.emergencyRoute = false,
    this.onStopNavigation,
    this.onTap,
  });

  final HudTurnModel model;

  /// The road's speed limit sign (round 7 RoadLimitSign behind its own listenable), at the end.
  final Widget? limitSign;

  /// Quiet route line status ("New route, 42 km") or the emergency route line.
  final String? routeStatus;
  final bool emergencyRoute;
  final VoidCallback? onStopNavigation;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final dist = m.distanceM == null ? null : HudTurnText.distance(m.distanceM!);
    final String headline;
    final String body;
    if (m.free) {
      headline = m.title ?? 'Free ride';
      body = m.subtitle ?? 'No route · riding free';
    } else if (m.title != null) {
      headline = dist ?? m.title!;
      body = dist == null ? (m.subtitle ?? '') : m.title!;
    } else {
      headline = dist ?? '';
      body = HudTurnText.instruction(m.direction, m.road);
    }
    final then = m.thenLine;
    final status = routeStatus;
    return RepaintBoundary(
      child: Semantics(
        container: true,
        liveRegion: false,
        label: m.free ? '$headline. $body' : '$body${dist == null ? '' : ' in $dist'}${then == null ? '' : '. $then'}',
        excludeSemantics: true,
        child: Material(
          key: const Key('hud_turn_card'),
          color: AppTheme.card,
          borderRadius: Radii.xlAll,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(borderRadius: Radii.xlAll, border: Border.all(color: AppTheme.border), boxShadow: dsFloatingShadow()),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(Space.s12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: m.free ? AppTheme.surfaceAlt : (emergencyRoute ? AppTheme.sos : AppTheme.primaryFill),
                            borderRadius: Radii.mdAll,
                          ),
                          child: Icon(
                            m.free ? Icons.edit_road_rounded : hudTurnIcon(m.direction),
                            size: 44,
                            color: m.free ? AppTheme.primary : Colors.white,
                          ),
                        ),
                        const SizedBox(width: Space.s12),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                headline,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: m.free
                                    ? AppText.headline.copyWith(fontSize: 22, height: 1.2)
                                    : AppText.metric.copyWith(fontSize: 34, height: 1.1, fontFeatures: const [FontFeature.tabularFigures()]),
                              ),
                              if (body.isNotEmpty)
                                Text(
                                  body,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: (m.free ? AppText.label : AppText.title.copyWith(fontSize: 17, height: 1.3)),
                                ),
                            ],
                          ),
                        ),
                        if (limitSign != null) ...[const SizedBox(width: Space.s8), limitSign!],
                      ],
                    ),
                  ),
                  if (then != null)
                    Container(
                      key: const Key('hud_turn_then'),
                      color: AppTheme.surfaceAlt,
                      padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s8),
                      child: Row(children: [
                        Icon(hudTurnIcon(m.thenDirection ?? HudTurnDir.straight), size: 22, color: AppTheme.text),
                        const SizedBox(width: Space.s8),
                        Expanded(child: Text(then, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600))),
                      ]),
                    ),
                  if (status != null)
                    Container(
                      color: emergencyRoute ? AppTheme.sos.withValues(alpha: 0.12) : AppTheme.primarySoft,
                      padding: const EdgeInsets.only(left: Space.s16, right: Space.s4),
                      constraints: const BoxConstraints(minHeight: 40),
                      child: Row(children: [
                        Icon(emergencyRoute ? Icons.emergency_rounded : Icons.alt_route_rounded,
                            size: 16, color: emergencyRoute ? AppTheme.sos : AppTheme.primary),
                        const SizedBox(width: Space.s8),
                        Expanded(
                          child: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: AppText.caption.copyWith(color: emergencyRoute ? AppTheme.sos : AppTheme.text, fontWeight: FontWeight.w600)),
                        ),
                        if (onStopNavigation != null)
                          IconButton(
                            tooltip: 'Stop navigation',
                            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                            onPressed: onStopNavigation,
                            icon: Icon(Icons.close_rounded, color: AppTheme.text, size: 20),
                          ),
                      ]),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HudRoundButton extends StatelessWidget {
  const _HudRoundButton({required this.icon, required this.tooltip, required this.onTap, this.buttonKey});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppTheme.card,
        shape: CircleBorder(side: BorderSide(color: AppTheme.border)),
        child: InkWell(
          key: buttonKey,
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: kHudGlove, height: kHudGlove, child: Icon(icon, color: AppTheme.text, size: 26)),
        ),
      ),
    );
  }
}
