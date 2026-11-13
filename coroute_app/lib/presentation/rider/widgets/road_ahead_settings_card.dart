import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/services/road_data_service.dart';
import '../../../data/services/settings_service.dart';
import '../../../domain/road/speed_limit_resolver.dart';
import 'road_ahead_chips.dart';

/// Round 7 settings for curve warnings and road speed limits, as one self-contained card
/// (shown in Settings > Road safety). Plain Flutter on purpose: when the app-wide UI kit gets
/// its settings rows, this card can adopt them (docs/quality/ROUND7_SAFETY_NOTES.md).
class RoadAheadSettingsCard extends StatelessWidget {
  const RoadAheadSettingsCard({super.key});

  static const String title = 'Bends and speed limits';

  static const String estimatedHelp =
      'Where the map has a speed limit for the road, CoRoute shows it as a round sign. Where it has none, CoRoute shows '
      'an estimate with "~" and "est.": a careful guess from the kind of road and whether the area is built-up, never '
      'above 60 km/h for a motorcycle (80 on expressways and divided 4-lane highways). An estimate never speaks; it '
      'only colours the sign. Bend warnings are computed on your phone from the shape of the road and work without '
      'signal. All of this is advice only: maps can be wrong or out of date. Always follow the signs on the road.';

  static String sizeLabel(int bytes) => bytes >= 1024 * 1024 ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB' : '${(bytes / 1024).ceil()} KB';

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsService?>();
    if (s == null) return const SizedBox.shrink();
    final roads = RoadDataService.shared;
    TextStyle head = TextStyle(color: AppTheme.text, fontSize: 15, fontWeight: FontWeight.w600);
    TextStyle sub = TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.3);
    Widget sw(String key, String t, String d, bool v, ValueChanged<bool>? on) => SwitchListTile(
          key: ValueKey(key),
          contentPadding: EdgeInsets.zero,
          title: Text(t, style: head),
          subtitle: Text(d, style: sub),
          value: v,
          onChanged: on,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        sw('road_ahead_curves', 'Curve warnings', 'A voice and an arrow before a sharp bend or hairpin, only when you are faster than the comfortable speed', s.curveWarnings, s.setCurveWarnings),
        sw('road_ahead_limit', 'Speed limit display', 'The road\'s limit in the ride screen: from the map, or estimated ("~ est.")', s.roadLimitDisplay, s.setRoadLimitDisplay),
        sw('road_ahead_overspeed', 'Overspeed warning', 'Says it once when you are over the limit, then only the sign turns red', s.roadOverspeedWarning && s.roadLimitDisplay,
            s.roadLimitDisplay ? s.setRoadOverspeedWarning : null),
        ListTile(
          key: const ValueKey('road_ahead_tolerance'),
          contentPadding: EdgeInsets.zero,
          enabled: s.roadOverspeedWarning && s.roadLimitDisplay,
          title: Text('Warn when over by', style: head),
          subtitle: Text('Never less than 5 km/h. Near schools and hospitals there is no margin.', style: sub),
          trailing: DropdownButton<int>(
            value: OverspeedPolicy.toleranceChoices.contains(s.roadOverspeedTolerancePct) ? s.roadOverspeedTolerancePct : OverspeedPolicy.defaultTolerancePct,
            items: [for (final p in OverspeedPolicy.toleranceChoices) DropdownMenuItem(value: p, child: Text('$p %'))],
            onChanged: s.roadOverspeedWarning && s.roadLimitDisplay ? (v) => s.setRoadOverspeedTolerancePct(v ?? OverspeedPolicy.defaultTolerancePct) : null,
          ),
        ),
        ExpansionTile(
          key: const ValueKey('road_ahead_estimated_help'),
          tilePadding: EdgeInsets.zero,
          title: Text('About estimated limits', style: head),
          children: [Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(estimatedHelp, style: sub))],
        ),
        if (roads != null)
          ListenableBuilder(
            listenable: roads,
            builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ListTile(
                key: const ValueKey('road_ahead_storage'),
                contentPadding: EdgeInsets.zero,
                title: Text('Road data on this phone', style: head),
                subtitle: Text('${sizeLabel(roads.storedBytes)} for ${roads.storedCells} map squares (at most ${sizeLabel(roads.maxBytes)}; the oldest are removed first)', style: sub),
                trailing: TextButton(
                  key: const ValueKey('road_ahead_clear'),
                  onPressed: roads.storedCells == 0 ? null : () => roads.clear(),
                  child: const Text('Clear'),
                ),
              ),
              if (roads.shownLimits.isNotEmpty) ...[
                Padding(padding: const EdgeInsets.only(top: 8, bottom: 4), child: Text('Limits on your last ride', style: head)),
                Text('Was one of them wrong? Tap it and choose what the sign says.', style: sub),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final l in roads.shownLimits.reversed.take(12))
                    ActionChip(
                      key: ValueKey('road_ahead_shown_${l.way}'),
                      label: Text('${l.name.isEmpty ? 'Road' : l.name}: ${l.label}${l.reported != null ? ' (you said ${l.reported})' : ''}'),
                      onPressed: () => WrongLimitSheet.show(context, shown: l, roads: roads),
                    ),
                ]),
              ],
            ]),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text('Road data (C) OpenStreetMap contributors (ODbL). Advice only.', style: sub.copyWith(fontSize: 12)),
        ),
      ],
    );
  }
}
