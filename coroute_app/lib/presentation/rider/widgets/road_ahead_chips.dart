import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/services/road_data_service.dart';
import '../../../domain/road/cockpit_layout.dart';
import '../../../domain/road/curve_predictor.dart';
import '../../../domain/road/road_ahead_engine.dart';
import '../../../domain/road/speed_limit_resolver.dart';

/// Round 7: the road's speed limit sign and the "bend ahead" chip of the ride cockpit.
///
/// Listens to [view] itself and sits behind a [RepaintBoundary]: a new limit or bend repaints
/// these two small chips only, never the map or the rest of the cockpit. Advisory: hidden while
/// an emergency is open (RoadCareService publishes an empty view then).
///
/// * Limit from the map: a round sign with the number. Estimated: "~50" with "est." under it and
///   a dashed-look amber ring, so it is never mistaken for a posted limit.
/// * Over the limit: the ring turns red; well over (more than 20%): the sign fills red.
/// * Bend: an arrow for the side and tightness, the comfortable speed and the distance.
/// * [onLimitTap]: only offered when the rider is not moving (the "wrong limit?" sheet).
class RoadAheadChips extends StatelessWidget {
  const RoadAheadChips({super.key, required this.view, required this.layout, this.onLimitTap});

  final ValueListenable<RoadAheadView> view;
  final CockpitLayout layout;
  final VoidCallback? onLimitTap;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<RoadAheadView>(
        valueListenable: view,
        builder: (context, v, _) {
          if (v.isEmpty) return const SizedBox.shrink();
          final limit = v.limit, curve = v.curve;
          final children = <Widget>[
            if (limit != null) RoadLimitSign(limit: limit, level: v.level, size: layout.signSize, onTap: onLimitTap),
            if (curve != null) CurveChip(curve: curve, advisoryKmh: v.curveAdvisoryKmh, distanceM: v.curveDistanceM, height: layout.chipHeight),
          ];
          return MediaQuery.withClampedTextScaling(
            minScaleFactor: 1.0,
            maxScaleFactor: 1.3,
            child: layout.stacked
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(height: layout.gap), children[i]],
                    ],
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(width: layout.gap), children[i]],
                    ],
                  ),
          );
        },
      ),
    );
  }
}

class RoadLimitSign extends StatelessWidget {
  const RoadLimitSign({super.key, required this.limit, required this.level, this.size = 52, this.onTap});

  final ResolvedLimit limit;
  final OverspeedLevel level;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final strong = level == OverspeedLevel.strong, over = level != OverspeedLevel.none;
    final est = limit.estimated;
    final ring = over ? AppTheme.danger : (est ? AppTheme.warnText : const Color(0xFFD32F2F));
    final fill = strong ? AppTheme.danger : Colors.white;
    final ink = strong ? Colors.white : const Color(0xFF111111);
    final what = est ? 'Estimated speed limit about ${limit.kmh}' : 'Speed limit ${limit.kmh}';
    final zone = limit.school ? ', school zone' : (limit.hospital ? ', hospital zone' : '');
    final state = strong ? ', you are well over it' : (over ? ', you are over it' : '');
    final sign = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: est ? size * 0.07 : size * 0.11),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 1))],
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(limit.label, maxLines: 1, style: TextStyle(color: ink, fontSize: size * 0.4, fontWeight: FontWeight.w800, height: 1.0)),
        ),
      ),
    );
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        sign,
        if (est || limit.zone)
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(color: AppTheme.card, borderRadius: BorderRadius.circular(6)),
            child: Text(
              limit.school ? 'school' : (limit.hospital ? 'hospital' : 'est.'),
              style: TextStyle(color: est ? AppTheme.warnText : AppTheme.text, fontSize: 10, fontWeight: FontWeight.w700, height: 1.1),
            ),
          ),
      ],
    );
    return Semantics(
      label: '$what km/h$zone$state',
      button: onTap != null,
      child: onTap == null ? body : GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: ConstrainedBox(constraints: const BoxConstraints(minWidth: 48, minHeight: 48), child: body)),
    );
  }
}

class CurveChip extends StatelessWidget {
  const CurveChip({super.key, required this.curve, required this.advisoryKmh, required this.distanceM, this.height = 44});

  final RoadCurve curve;
  final int advisoryKmh;
  final int distanceM;
  final double height;

  static IconData iconFor(RoadCurve c) => switch (c.cls) {
        CurveClass.hairpin => c.right ? Icons.u_turn_right_rounded : Icons.u_turn_left_rounded,
        CurveClass.sharp => c.right ? Icons.turn_right_rounded : Icons.turn_left_rounded,
        _ => c.right ? Icons.turn_slight_right_rounded : Icons.turn_slight_left_rounded,
      };

  static String nameFor(RoadCurve c) => switch (c.cls) {
        CurveClass.hairpin => 'Hairpin',
        CurveClass.sharp => 'Sharp bend',
        CurveClass.medium => 'Bend',
        CurveClass.gentle => 'Gentle bend',
      };

  @override
  Widget build(BuildContext context) {
    final severe = curve.cls.index >= CurveClass.sharp.index;
    final color = severe ? AppTheme.danger : AppTheme.warnText;
    return Semantics(
      label: '${nameFor(curve)} to the ${curve.right ? 'right' : 'left'}${distanceM > 0 ? ' in $distanceM metres' : ''}, comfortable speed $advisoryKmh km/h',
      child: Container(
        constraints: BoxConstraints(minHeight: height),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color, width: 2),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 1))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(iconFor(curve), color: color, size: height * 0.62),
            const SizedBox(width: 6),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$advisoryKmh', style: TextStyle(color: AppTheme.text, fontSize: 18, fontWeight: FontWeight.w800, height: 1.0)),
                if (distanceM > 0) Text('$distanceM m', style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w600, height: 1.15)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "Is this limit wrong?" One tap on the right value sends the report. Only opened when the
/// rider is not moving (the cockpit checks the tap gate; Settings shows it after the ride).
class WrongLimitSheet extends StatelessWidget {
  const WrongLimitSheet({super.key, required this.shown, required this.roads});

  final ShownLimit shown;
  final RoadDataService roads;

  static const List<int> choices = [20, 30, 40, 50, 60, 70, 80];

  static Future<void> show(BuildContext context, {required ShownLimit shown, required RoadDataService roads}) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        backgroundColor: AppTheme.card,
        builder: (_) => WrongLimitSheet(shown: shown, roads: roads),
      );

  @override
  Widget build(BuildContext context) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Is this limit wrong?', style: TextStyle(color: AppTheme.text, fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
              '${shown.name.isEmpty ? 'This road' : shown.name}: CoRoute shows ${shown.label}.'
              '${shown.estimated ? ' That is an estimate from the kind of road, not a posted limit.' : ''}'
              ' Tap what the sign on the road says. The limit changes when 3 riders agree.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 14, height: 1.35),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final v in choices)
                  if (v != shown.kmh || shown.estimated)
                    SizedBox(
                      width: 72,
                      height: 56,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.text,
                          side: BorderSide(color: AppTheme.border, width: 2),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          padding: EdgeInsets.zero,
                        ),
                        onPressed: () async {
                          Navigator.of(context).pop();
                          final line = await roads.reportWrongLimit(shown, v);
                          messenger?.showSnackBar(SnackBar(content: Text(line)));
                        },
                        child: Text('$v', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                      ),
                    ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Road data (C) OpenStreetMap contributors. Always follow the signs on the road.', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
