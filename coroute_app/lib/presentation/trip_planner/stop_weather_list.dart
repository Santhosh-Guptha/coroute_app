import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/weather_service.dart';

/// v3.63 trip planning lite: weather at each planned stop and the destination at the expected time (rain chance,
/// temperature, wind), from the route weather the app already asks for (WeatherService, MET Norway through the
/// gateway). Shows nothing when there is no answer yet, in data saver, or when no point is a named stop.
class StopWeatherList extends StatelessWidget {
  const StopWeatherList({super.key, this.max = 4});

  final int max;

  /// "Warangal · 3 PM · rain 60% · 28°C · wind 14 km/h" (parts only when known).
  static String lineFor(WeatherPoint p, WeatherReading r) {
    final parts = <String>[p.name, WeatherService.hourText(p.atS)];
    if (r.storm) {
      parts.add('thunderstorm');
    } else {
      parts.add('rain ${r.precipProb.clamp(0, 100)}%');
    }
    final t = r.tempC;
    if (t != null && t.isFinite) parts.add('${t.round()}°C');
    final w = r.windKmh;
    if (w != null && w >= 0) parts.add('wind $w km/h');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final w = context.watch<WeatherService?>();
    final stops = w?.lastStops ?? const [];
    if (stops.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const Key('stop_weather_list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: const EdgeInsets.only(top: 8, bottom: 4), child: Text('Weather at stops', style: AppText.label.copyWith(fontWeight: FontWeight.w700))),
        for (final s in stops.take(max))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Icon(s.$2.storm ? Icons.thunderstorm_rounded : (s.$2.rain ? Icons.umbrella_rounded : Icons.wb_cloudy_outlined),
                  size: 18, color: s.$2.rain || s.$2.storm ? AppTheme.warnText : AppTheme.textMuted),
              const SizedBox(width: 8),
              Expanded(child: Text(lineFor(s.$1, s.$2), style: AppText.caption.copyWith(color: AppTheme.text), maxLines: 2, overflow: TextOverflow.ellipsis)),
            ]),
          ),
        if (w?.last?.attribution.isNotEmpty ?? false) Text(w!.last!.attribution, style: AppText.caption.copyWith(fontSize: 11)),
      ],
    );
  }
}
