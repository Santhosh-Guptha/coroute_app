import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/services/road_data_service.dart';
import '../../../data/services/settings_service.dart';
import 'road_ahead_chips.dart';

/// Round 7 card for curve warnings and road speed limits (shown in Settings > Road safety).
/// Round 9 (docs/quality/ROUND9_SETTINGS_NOTES.md): bend warnings, the speed limit sign and the
/// overspeed warning are always on with a fixed margin (+10 %, at least 5 km/h; none near schools and
/// hospitals), so the card has no switches: it explains estimated limits (help text), shows the road
/// data kept on the phone and lets the rider report a wrong limit.
class RoadAheadSettingsCard extends StatelessWidget {
  const RoadAheadSettingsCard({super.key});

  static const String title = 'Bends and speed limits';
  static const String alwaysOnLine = 'Always on. You are warned when about 10 % over the limit (at least 5 km/h; right at the limit near schools and hospitals).';

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(alwaysOnLine, key: const ValueKey('road_ahead_always_on'), style: head),
        const SizedBox(height: 6),
        Text(estimatedHelp, key: const ValueKey('road_ahead_estimated_help'), style: sub),
        const SizedBox(height: 8),
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
