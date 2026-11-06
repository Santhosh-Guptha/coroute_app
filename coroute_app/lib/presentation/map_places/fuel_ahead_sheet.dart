import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/map_places_service.dart';
import '../../domain/places/fuel_ahead.dart';
import '../../domain/places/fuel_match.dart';
import 'place_card.dart';
import 'place_style.dart';

Color _reachColor(Reach r) => switch (r) {
      Reach.reachable => StatusColors.success,
      Reach.onReserve => StatusColors.warning,
      Reach.tooFar => StatusColors.critical,
      Reach.unknown => AppTheme.muted,
    };

/// The next stations on the route for this bike, with distance along the route
/// and whether the fuel left reaches them (shown inside the place chips).
class FuelAheadList extends StatelessWidget {
  const FuelAheadList({super.key, required this.service, this.usableKm, this.marginKm = 0});
  final MapPlacesService service;
  final double? usableKm;
  final double marginKm;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final stops = service.fuelStops(usableKm: usableKm, marginKm: marginKm, limit: 10);
          final word = service.fuelType.stationWord;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Next ${word}s on your route', style: AppText.title),
              const SizedBox(height: Space.s4),
              Text(
                usableKm == null
                    ? 'Set your tank and mileage in Fuel to see what you can reach.'
                    : 'About ${usableKm!.floor()} km before reserve.',
                style: AppText.caption.copyWith(color: AppTheme.muted),
              ),
              const SizedBox(height: Space.s12),
              if (!service.hasRoute)
                Text('No route loaded. Stations near you show on the map.', style: AppText.body.copyWith(color: AppTheme.text2))
              else if (stops.isEmpty)
                Text(service.offline ? 'Offline: no saved stations ahead yet.' : 'No $word mapped ahead yet.',
                    style: AppText.body.copyWith(color: AppTheme.text2)),
              for (final s in stops)
                ListTile(
                  key: ValueKey('fuelAhead_${s.poi.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: s.confirmed ? s.poi.category.color : AppTheme.soft,
                    child: Icon(s.poi.category.icon, color: s.confirmed ? Colors.white : AppTheme.muted),
                  ),
                  title: Text(s.poi.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${s.distanceKm < 10 ? s.distanceKm.toStringAsFixed(1) : s.distanceKm.round()} km along the route'
                    '${s.offM > 300 ? ' · ${(s.offM / 1000).toStringAsFixed(1)} km off it' : ''}'
                    '${s.match == FuelMatch.unknown ? ' · fuel type unknown' : ''}',
                  ),
                  trailing: Text(s.reach.label, style: AppText.caption.copyWith(color: _reachColor(s.reach), fontWeight: FontWeight.w800)),
                  onTap: () => showPlaceCard(context, s.poi, service),
                ),
            ],
          );
        },
      );
}
