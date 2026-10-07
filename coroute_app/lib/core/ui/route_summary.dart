import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'ui_format.dart';
import 'ui_tokens.dart';

/// Trip overview stats in a wrapping row: distance, time, stops, riders
/// and (optionally) the departure time. Used on the trip review screen
/// before [Start Ride] and at the top of a trip card.
class RouteSummary extends StatelessWidget {
  final double distanceKm;
  final Duration duration;
  final int stops;
  final int riders;
  final DateTime? departure;

  const RouteSummary({
    super.key,
    required this.distanceKm,
    required this.duration,
    required this.stops,
    required this.riders,
    this.departure,
  });

  static String departureText(BuildContext context, DateTime d) {
    final loc = MaterialLocalizations.of(context);
    final time = loc.formatTimeOfDay(
      TimeOfDay.fromDateTime(d),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final now = DateTime.now();
    final sameDay = d.year == now.year && d.month == now.month && d.day == now.day;
    return sameDay ? time : '${loc.formatShortMonthDay(d)}, $time';
  }

  @override
  Widget build(BuildContext context) {
    final dep = departure;
    final items = <Widget>[
      _Stat(icon: Icons.route_rounded, value: formatDistance(distanceKm * 1000), label: 'Distance'),
      _Stat(icon: Icons.schedule_rounded, value: formatDuration(duration), label: 'Time'),
      _Stat(icon: Icons.place_rounded, value: '$stops', label: stops == 1 ? 'Stop' : 'Stops'),
      _Stat(icon: Icons.groups_rounded, value: '$riders', label: riders == 1 ? 'Rider' : 'Riders'),
      if (dep != null) _Stat(icon: Icons.flag_rounded, value: departureText(context, dep), label: 'Departs'),
    ];
    return Wrap(
      spacing: Space.s24,
      runSpacing: Space.s12,
      children: items,
    );
  }
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _Stat({required this.icon, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$label: $value',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: AppTheme.textSecondary),
          const SizedBox(width: Space.s8),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.metric.copyWith(fontSize: 18),
                ),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
