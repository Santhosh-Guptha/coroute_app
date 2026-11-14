import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../domain/road/curve_predictor.dart';
import '../../../domain/road/road_ahead_engine.dart';
import '../../../domain/safety/warning_scheduler.dart';
import '../widgets/road_ahead_chips.dart';
import 'hud_logic.dart';

/// Round 11 ride HUD: the safety strip under the turn card.
///
/// One advisory at a time, picked in the round 7 warning scheduler's order (hazard > curve > speed
/// limit > falling behind > ...). The bend comes from RoadCareService.roadView (the same source as
/// the round 7 bend chip, which the HUD hides so it never shows twice); [extra] are other advisories
/// the cockpit knows of. It listens to [view] itself behind a RepaintBoundary: a new bend repaints
/// the strip only. Empty in an emergency (roadView is empty then; the SOS banners own the screen).
///
/// The strip is larger than the old bend chip (56 dp, 20 sp number), so nothing gets smaller.
class HudSafetyStrip extends StatelessWidget {
  const HudSafetyStrip({super.key, required this.view, this.extra = const [], this.emergency = false});

  final ValueListenable<RoadAheadView>? view;
  final List<HudAdvisory> extra;
  final bool emergency;

  @override
  Widget build(BuildContext context) {
    final v = view;
    if (v == null) return _build(context, null);
    return RepaintBoundary(
      child: ValueListenableBuilder<RoadAheadView>(valueListenable: v, builder: (context, rv, _) => _build(context, rv)),
    );
  }

  Widget _build(BuildContext context, RoadAheadView? rv) {
    final curve = rv?.curve;
    final items = <HudAdvisory>[
      ...extra,
      if (curve != null)
        HudAdvisory(
          kind: WarnKind.curve,
          key: 'curve:${curve.key}',
          title: '${CurveChip.nameFor(curve)} ${curve.right ? 'right' : 'left'}',
          detail: HudSafetyStrip.curveDetailOf(rv!),
        ),
    ];
    final pick = HudSafetyStrip.pickOf(items, emergency: emergency);
    return AnimatedSwitcher(
      duration: Motion.tab,
      switchInCurve: Motion.curve,
      child: pick == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              key: ValueKey<String>(pick.key),
              padding: const EdgeInsets.only(top: Space.s8),
              child: _Strip(advisory: pick, curve: pick.kind == WarnKind.curve ? curve : null, advisoryKmh: rv?.curveAdvisoryKmh ?? 0),
            ),
    );
  }

  static String curveDetailOf(RoadAheadView v) => HudSafetyStripRules.curveDetail(v.curveAdvisoryKmh, v.curveDistanceM);

  static HudAdvisory? pickOf(List<HudAdvisory> items, {bool emergency = false}) => HudSafetyStripRules.pick(items, emergency: emergency);
}

class _Strip extends StatelessWidget {
  const _Strip({required this.advisory, this.curve, this.advisoryKmh = 0});
  final HudAdvisory advisory;
  final RoadCurve? curve;
  final int advisoryKmh;

  @override
  Widget build(BuildContext context) {
    final c = curve;
    final severe = c != null ? c.cls.index >= CurveClass.sharp.index : advisory.kind == WarnKind.hazard;
    final ink = severe ? AppTheme.danger : AppTheme.accentStrong;
    final icon = c != null
        ? CurveChip.iconFor(c)
        : switch (advisory.kind) {
            WarnKind.hazard => Icons.warning_amber_rounded,
            WarnKind.fallingBehind => Icons.directions_bike_outlined,
            WarnKind.roughRoad => Icons.waves_rounded,
            WarnKind.speedLimit => Icons.speed_rounded,
            _ => Icons.info_outline_rounded,
          };
    return Semantics(
      liveRegion: true,
      label: '${advisory.title}. ${advisory.detail}',
      excludeSemantics: true,
      child: Container(
        key: const Key('hud_safety_strip'),
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(horizontal: Space.s12, vertical: Space.s8),
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: Radii.lgAll,
          border: Border.all(color: ink, width: 2),
          boxShadow: dsFloatingShadow(),
        ),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: severe ? AppTheme.danger.withValues(alpha: 0.12) : AppTheme.accentSoft, borderRadius: Radii.mdAll),
            child: Icon(icon, color: ink, size: 30),
          ),
          const SizedBox(width: Space.s12),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(advisory.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 17)),
              if (advisory.detail.isNotEmpty && c == null)
                Text(advisory.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
              if (c != null && advisory.detail.isNotEmpty)
                Text('Comfortable speed', maxLines: 1, style: AppText.caption),
            ]),
          ),
          if (c != null && advisoryKmh > 0)
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('$advisoryKmh', style: AppText.metric.copyWith(fontSize: 26, height: 1.0, color: ink)),
              Text(advisory.detail.split(' · ').last, style: AppText.caption),
            ]),
        ]),
      ),
    );
  }
}
