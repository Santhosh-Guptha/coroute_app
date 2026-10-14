import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/models/convoy_model.dart';
import '../../../data/models/rider_model.dart';
import '../../../data/models/route_essential.dart';
import '../../../data/models/stop_point_model.dart';
import '../../../data/services/route_essentials_service.dart';
import '../../../domain/ride/ride_facts.dart';
import '../../../domain/route/route_plan.dart';
import '../../../domain/tracking/geo_math.dart';

/// Floating right-side action stack in the motorcycle cockpit.
///
/// Stacks real-time alerts line-by-line one on another:
/// 1. Low Fuel Pop-up Button: Red fuel icon with usable km left & nearest station.
/// 2. Member Stop Suggestions (Food, Chai/Coffee, Rest, Scenic).
/// 3. Lead Emergency / Meeting Points.
/// 4. Convoy Rider Stopped / Needs Assistance alerts.
class CockpitActionStack extends StatelessWidget {
  final ConvoyModel convoy;
  final RiderModel me;
  final RouteEssentialsService? essentialsService;
  final double? estimatedUsableKm;
  final bool isLead;
  final Function(RouteEssential station)? onAddStationStop;
  final Function(StopPointModel stop)? onAcceptStopSuggestion;
  final Function(double lat, double lng)? onFocusLocation;
  final VoidCallback? onOpenFuelSheet;
  final VoidCallback? onOpenStopsSheet;

  const CockpitActionStack({
    super.key,
    required this.convoy,
    required this.me,
    this.essentialsService,
    this.estimatedUsableKm,
    required this.isLead,
    this.onAddStationStop,
    this.onAcceptStopSuggestion,
    this.onFocusLocation,
    this.onOpenFuelSheet,
    this.onOpenStopsSheet,
  });

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];

    // 1. Fuel Alert / Nearest Station Check
    final usableKm = estimatedUsableKm;
    final essentials = essentialsService;
    final progressM = essentials?.progressM ?? 0;
    final upcomingFuel = essentials?.upcoming.where((e) => e.category == 'FUEL').toList() ?? [];
    final nearestStation = upcomingFuel.isNotEmpty ? upcomingFuel.first : null;
    final fuelAheadM = nearestStation?.aheadM(progressM);
    final fuelAheadKm = (fuelAheadM != null && fuelAheadM > 0) ? fuelAheadM / 1000 : null;

    final isLowFuel = usableKm != null && (usableKm <= 60 || (fuelAheadKm != null && fuelAheadKm > usableKm));

    if (isLowFuel) {
      items.add(
        _ActionPill(
          icon: Icons.local_gas_station_rounded,
          iconColor: Colors.white,
          accentColor: AppTheme.sos,
          title: 'LOW FUEL · ${usableKm.round()} km left',
          subtitle: nearestStation != null && fuelAheadM != null
              ? '${nearestStation.name} in ${formatDistanceRounded(fuelAheadM)} · Tap to route'
              : 'Tap to find fuel stations',
          onTap: () {
            HapticFeedback.mediumImpact();
            _showFuelQuickSheet(
              context,
              usableKm: usableKm,
              stations: upcomingFuel.take(3).toList(),
              progressM: progressM,
              onAddStationStop: onAddStationStop,
              onOpenFuelSheet: onOpenFuelSheet,
            );
          },
        ),
      );
    }

    // 2. Stop Suggestions from Convoy Members (Food, Coffee, Rest, etc.)
    final suggestions = convoy.suggestedStops;
    for (final stop in suggestions.take(2)) {
      final IconData stopIcon;
      final Color stopColor;
      switch (stop.category.toUpperCase()) {
        case 'FOOD':
          stopIcon = Icons.restaurant_rounded;
          stopColor = const Color(0xFFEA580C); // Warm Orange
          break;
        case 'FUEL':
          stopIcon = Icons.local_gas_station_rounded;
          stopColor = AppTheme.sos;
          break;
        case 'SCENIC':
          stopIcon = Icons.photo_camera_rounded;
          stopColor = const Color(0xFF0284C7); // Blue
          break;
        default:
          stopIcon = Icons.local_cafe_rounded;
          stopColor = AppTheme.warnText; // Amber
          break;
      }

      final who = stop.suggestedByName.split(' ').first;
      final distM = (me.lat != 0 && me.lng != 0)
          ? GeoMath.haversine(me.lat, me.lng, stop.lat, stop.lng)
          : null;
      final distText = distM != null ? ' · ${formatDistanceRounded(distM)}' : '';

      items.add(
        _ActionPill(
          icon: stopIcon,
          iconColor: Colors.white,
          accentColor: stopColor,
          title: '$who: ${stop.name.isEmpty ? stop.category : stop.name}',
          subtitle: '${stop.category} stop suggested$distText · Tap to view',
          onTap: () {
            HapticFeedback.lightImpact();
            if (onFocusLocation != null && stop.lat != 0 && stop.lng != 0) {
              onFocusLocation!(stop.lat, stop.lng);
            }
            if (onOpenStopsSheet != null) {
              onOpenStopsSheet!();
            }
          },
        ),
      );
    }

    // 3. Lead Meeting Points / Meet Here
    final meetingStops = convoy.plannedStops.where((s) => s.category == RoutePlan.meetingCategory);
    for (final meet in meetingStops.take(1)) {
      final distM = (me.lat != 0 && me.lng != 0)
          ? GeoMath.haversine(me.lat, me.lng, meet.lat, meet.lng)
          : null;
      final distText = distM != null ? ' · ${formatDistanceRounded(distM)}' : '';

      items.add(
        _ActionPill(
          icon: Icons.flag_rounded,
          iconColor: Colors.white,
          accentColor: AppTheme.accentText,
          title: 'MEET HERE · ${meet.name}',
          subtitle: 'Group meeting point$distText · Tap to view',
          onTap: () {
            HapticFeedback.lightImpact();
            if (onFocusLocation != null && meet.lat != 0 && meet.lng != 0) {
              onFocusLocation!(meet.lat, meet.lng);
            }
          },
        ),
      );
    }

    // 4. Convoy Rider Stopped with Reason (e.g. Puncture, Rest, Breakdown)
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final rider in convoy.riders.values) {
      if (rider.userId == me.userId || !RideFacts.hasPosition(rider)) continue;
      final isStopped = (nowMs - rider.lastSeenEpochMs < 300000) && rider.speedKmh < 5.0 && rider.statusReason.isNotEmpty;
      if (isStopped) {
        final who = rider.name.split(' ').first;
        final reason = rider.statusReason;
        final distM = (me.lat != 0 && me.lng != 0)
            ? GeoMath.haversine(me.lat, me.lng, rider.lat, rider.lng)
            : null;
        final distText = distM != null ? ' · ${formatDistanceRounded(distM)} away' : '';

        items.add(
          _ActionPill(
            icon: Icons.warning_amber_rounded,
            iconColor: Colors.white,
            accentColor: AppTheme.warnText,
            title: '$who stopped: $reason',
            subtitle: 'Rider stopped$distText · Tap to locate',
            onTap: () {
              HapticFeedback.lightImpact();
              if (onFocusLocation != null) {
                onFocusLocation!(rider.lat, rider.lng);
              }
            },
          ),
        );
        break; // Only show 1 stopped rider alert at a time to prevent overflow
      }
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (int i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(height: Space.s8),
          items[i],
        ],
      ],
    );
  }

  void _showFuelQuickSheet(
    BuildContext context, {
    required double usableKm,
    required List<RouteEssential> stations,
    required double progressM,
    Function(RouteEssential station)? onAddStationStop,
    VoidCallback? onOpenFuelSheet,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(borderRadius: Radii.sheetTop),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.s24, Space.s16, Space.s24, Space.s24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppTheme.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: Space.s16),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(Space.s8),
                      decoration: BoxDecoration(
                        color: AppTheme.sos.withOpacity(0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.local_gas_station_rounded, color: AppTheme.sos, size: 28),
                    ),
                    const SizedBox(width: Space.s12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Low Fuel Warning', style: AppText.title),
                          Text('Estimated ~${usableKm.round()} km usable range left',
                              style: AppText.caption.copyWith(color: AppTheme.sos, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.s16),
                const Divider(),
                const SizedBox(height: Space.s8),
                Text('UPCOMING CORRIDOR STATIONS',
                    style: AppText.caption.copyWith(fontWeight: FontWeight.w800, color: AppTheme.muted)),
                const SizedBox(height: Space.s8),
                if (stations.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.s12),
                    child: Text('No fuel stations found in current offline window. Open full map or fuel manager.',
                        style: AppText.body.copyWith(color: AppTheme.muted)),
                  )
                else
                  for (final st in stations) ...[
                    _StationRow(
                      station: st,
                      progressM: progressM,
                      onAdd: () {
                        Navigator.pop(ctx);
                        onAddStationStop?.call(st);
                      },
                    ),
                    const SizedBox(height: Space.s8),
                  ],
                const SizedBox(height: Space.s12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.text,
                          side: BorderSide(color: AppTheme.border, width: 1.5),
                          padding: const EdgeInsets.symmetric(vertical: Space.s12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          onOpenFuelSheet?.call();
                        },
                        icon: const Icon(Icons.tune_rounded, size: 18),
                        label: const Text('Manage Fuel'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ActionPill extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color accentColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionPill({
    required this.icon,
    required this.iconColor,
    required this.accentColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.card.withAlpha(245),
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 270),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: accentColor.withOpacity(0.8), width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.label.copyWith(
                        color: AppTheme.text,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: AppTheme.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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

class _StationRow extends StatelessWidget {
  final RouteEssential station;
  final double progressM;
  final VoidCallback onAdd;

  const _StationRow({
    required this.station,
    required this.progressM,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final aheadM = station.aheadM(progressM);
    final distStr = formatDistanceRounded(aheadM);

    return Container(
      padding: const EdgeInsets.all(Space.s12),
      decoration: BoxDecoration(
        color: AppTheme.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Icon(Icons.local_gas_station_rounded, color: AppTheme.brand, size: 22),
          const SizedBox(width: Space.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  station.name.isEmpty ? 'Petrol Pump' : station.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.title.copyWith(fontSize: 14),
                ),
                Text(
                  '$distStr ahead on corridor',
                  style: AppText.caption.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.s8),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: const Size(0, 36),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: onAdd,
            icon: const Icon(Icons.add_location_alt_rounded, size: 16),
            label: const Text('Add Stop', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
