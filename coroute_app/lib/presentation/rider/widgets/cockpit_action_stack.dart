import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/config/feature_gates.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/models/convoy_model.dart';
import '../../../data/models/rider_model.dart';
import '../../../data/models/route_essential.dart';
import '../../../data/models/stop_point_model.dart';
import '../../../data/services/route_essentials_service.dart';
import '../../../domain/fuel/group_fuel_consensus.dart';
import '../../../domain/ride/ride_facts.dart';
import '../../../domain/route/route_plan.dart';
import '../../../domain/tracking/geo_math.dart';

/// Floating right-side action stack in the motorcycle cockpit.
///
/// Ergonomically optimized for handlebar phone mounts:
/// - Constrained to prioritize and display at most 1 primary action capsule with
///   horizontal swipe and tap-to-next pagination to prevent covering the map.
/// - Touch targets are upscaled for leather motorcycle gloves (SideFuelButton >= 56 dp,
///   StationRow button >= 48 dp).
/// - Integrates [FeatureGates.isUnlocked] for [Feature.sunlightHudMode] high-contrast outdoor styling.
class CockpitActionStack extends StatefulWidget {
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
  State<CockpitActionStack> createState() => _CockpitActionStackState();
}

class _CockpitActionStackState extends State<CockpitActionStack> {
  int _currentIndex = 0;
  double _dragOffset = 0;

  void _nextCapsule(int total) {
    if (total <= 1) return;
    setState(() {
      _currentIndex = (_currentIndex + 1) % total;
    });
    HapticFeedback.lightImpact();
  }

  void _prevCapsule(int total) {
    if (total <= 1) return;
    setState(() {
      _currentIndex = (_currentIndex - 1 + total) % total;
    });
    HapticFeedback.lightImpact();
  }

  @override
  Widget build(BuildContext context) {
    final isSunlightHud = FeatureGates.isUnlocked(Feature.sunlightHudMode);
    final items = <Widget>[];

    // 0. Active SOS Distress Alert (Highest Priority - Gateway or Offline P2P Mesh)
    for (final alert in widget.convoy.activeAlerts) {
      if (alert.userId == widget.me.userId || alert.resolved) continue;
      final who = alert.userName.split(' ').first;
      final distM = (widget.me.lat != 0 && widget.me.lng != 0 && alert.lat != 0 && alert.lng != 0)
          ? GeoMath.haversine(widget.me.lat, widget.me.lng, alert.lat, alert.lng)
          : null;
      final distText = distM != null ? ' · ${formatDistanceRounded(distM)} away' : '';
      final isMeshAlert = alert.alertId.startsWith('mesh_');
      final sourceTag = isMeshAlert ? ' (via Mesh)' : '';

      items.add(
        _ActionPill(
          icon: Icons.emergency_rounded,
          iconColor: Colors.white,
          accentColor: AppTheme.sos,
          title: 'SOS: $who$sourceTag',
          subtitle: '${alert.alertType}$distText · Tap to locate',
          onTap: () {
            HapticFeedback.heavyImpact();
            if (widget.onFocusLocation != null && alert.lat != 0 && alert.lng != 0) {
              widget.onFocusLocation!(alert.lat, alert.lng);
            }
          },
        ),
      );
      break; // Display top critical alert first
    }

    // 1. Fuel Alert / Nearest Station Check
    final usableKm = widget.estimatedUsableKm;
    final essentials = widget.essentialsService;
    final progressM = essentials?.progressM ?? 0;
    final upcomingFuel = essentials?.upcoming.where((e) => e.category == 'FUEL').toList() ?? [];
    final nearestStation = upcomingFuel.isNotEmpty ? upcomingFuel.first : null;
    final rawAheadM = nearestStation?.aheadM(progressM);
    final fuelAheadM = nearestStation != null
        ? ((rawAheadM != null && rawAheadM > 0)
            ? rawAheadM
            : (widget.me.lat != 0 && widget.me.lng != 0
                ? GeoMath.haversine(widget.me.lat, widget.me.lng, nearestStation.lat, nearestStation.lng)
                : null))
        : null;
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
              stations: upcomingFuel.take(4).toList(),
              progressM: progressM,
              riderLat: widget.me.lat,
              riderLng: widget.me.lng,
              onAddStationStop: widget.onAddStationStop,
              onOpenFuelSheet: widget.onOpenFuelSheet,
            );
          },
        ),
      );
    } else if (usableKm != null && usableKm <= 100) {
      // Only show proactive fuel recommendation when tank is actually in reserve (<= 100 km)
      if (nearestStation != null && fuelAheadM != null) {
        final rangeText = ' · ${usableKm.round()} km left';
        items.add(
          _ActionPill(
            icon: Icons.local_gas_station_rounded,
            iconColor: Colors.white,
            accentColor: AppTheme.warnText,
            title: 'NEXT FUEL · in ${formatDistanceRounded(fuelAheadM)}$rangeText',
            subtitle: '${nearestStation.name} · Tap to route',
            onTap: () {
              HapticFeedback.lightImpact();
              _showFuelQuickSheet(
                context,
                usableKm: usableKm,
                stations: upcomingFuel.take(4).toList(),
                progressM: progressM,
                riderLat: widget.me.lat,
                riderLng: widget.me.lng,
                onAddStationStop: widget.onAddStationStop,
                onOpenFuelSheet: widget.onOpenFuelSheet,
              );
            },
          ),
        );
      } else {
        items.add(
          _ActionPill(
            icon: Icons.local_gas_station_rounded,
            iconColor: Colors.white,
            accentColor: AppTheme.warnText,
            title: 'FUEL · ${usableKm.round()} km range',
            subtitle: 'Tap to view petrol stations',
            onTap: () {
              HapticFeedback.lightImpact();
              widget.onOpenFuelSheet?.call();
            },
          ),
        );
      }
    }

    // 1b. Group Fuel Consensus (Tracks lowest-range motorcycle in the convoy pack)
    final consensus = GroupFuelConsensus.evaluate(
      convoy: widget.convoy,
      upcomingStations: upcomingFuel,
      progressM: progressM,
    );

    if (consensus != null && consensus.alertLead && consensus.bottleneckUserId != widget.me.userId) {
      final who = consensus.bottleneckRiderName.split(' ').first;
      final st = consensus.recommendedStation;
      final distStr = consensus.distanceToStationKm != null ? ' in ${consensus.distanceToStationKm!.toStringAsFixed(1)} km' : '';
      items.add(
        _ActionPill(
          icon: Icons.local_gas_station_rounded,
          iconColor: Colors.white,
          accentColor: const Color(0xFFD97706),
          title: 'GROUP FUEL · $who: ${consensus.lowestRangeKm.round()} km left',
          subtitle: st != null
              ? '${st.name}$distStr · Tap to add stop'
              : 'Bottleneck rider needs fuel · Tap to search',
          onTap: () {
            HapticFeedback.mediumImpact();
            _showFuelQuickSheet(
              context,
              usableKm: consensus.lowestRangeKm,
              stations: upcomingFuel.take(4).toList(),
              progressM: progressM,
              riderLat: widget.me.lat,
              riderLng: widget.me.lng,
              onAddStationStop: widget.onAddStationStop,
              onOpenFuelSheet: widget.onOpenFuelSheet,
            );
          },
        ),
      );
    }

    // 2. Stop Suggestions from Convoy Members (Food, Coffee, Rest, etc.)
    final suggestions = widget.convoy.suggestedStops;
    for (final stop in suggestions.take(4)) {
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
      final distM = (widget.me.lat != 0 && widget.me.lng != 0)
          ? GeoMath.haversine(widget.me.lat, widget.me.lng, stop.lat, stop.lng)
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
            if (widget.onFocusLocation != null && stop.lat != 0 && stop.lng != 0) {
              widget.onFocusLocation!(stop.lat, stop.lng);
            }
            if (widget.onOpenStopsSheet != null) {
              widget.onOpenStopsSheet!();
            }
          },
        ),
      );
    }

    // 3. Lead Meeting Points / Meet Here
    final meetingStops = widget.convoy.plannedStops.where((s) => s.category == RoutePlan.meetingCategory);
    for (final meet in meetingStops.take(1)) {
      final distM = (widget.me.lat != 0 && widget.me.lng != 0)
          ? GeoMath.haversine(widget.me.lat, widget.me.lng, meet.lat, meet.lng)
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
            if (widget.onFocusLocation != null && meet.lat != 0 && meet.lng != 0) {
              widget.onFocusLocation!(meet.lat, meet.lng);
            }
          },
        ),
      );
    }

    // 4. Convoy Rider Stopped with Reason (e.g. Puncture, Rest, Breakdown)
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final rider in widget.convoy.riders.values) {
      if (rider.userId == widget.me.userId || !RideFacts.hasPosition(rider)) continue;
      final isStopped = (nowMs - rider.lastSeenEpochMs < 300000) && rider.speedKmh < 5.0 && rider.statusReason.isNotEmpty;
      if (isStopped) {
        final who = rider.name.split(' ').first;
        final reason = rider.statusReason;
        final distM = (widget.me.lat != 0 && widget.me.lng != 0)
            ? GeoMath.haversine(widget.me.lat, widget.me.lng, rider.lat, rider.lng)
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
              if (widget.onFocusLocation != null) {
                widget.onFocusLocation!(rider.lat, rider.lng);
              }
            },
          ),
        );
        break; // Only show 1 stopped rider alert at a time to prevent overflow
      }
    }

    final fuelButton = _SideFuelButton(
      isLowFuel: isLowFuel,
      usableKm: usableKm,
      onTap: () {
        HapticFeedback.lightImpact();
        _showFuelQuickSheet(
          context,
          usableKm: usableKm,
          stations: upcomingFuel.take(4).toList(),
          progressM: progressM,
          riderLat: widget.me.lat,
          riderLng: widget.me.lng,
          onAddStationStop: widget.onAddStationStop,
          onOpenFuelSheet: widget.onOpenFuelSheet,
        );
      },
    );

    final count = items.length;
    final activeIdx = count == 0 ? 0 : (_currentIndex % count);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (count > 0) ...[
          if (count > 1) ...[
            GestureDetector(
              onTap: () => _nextCapsule(count),
              child: Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isSunlightHud ? AppTheme.card : AppTheme.card.withAlpha(240),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSunlightHud ? AppTheme.border.withOpacity(0.9) : AppTheme.border,
                    width: isSunlightHud ? 2 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.shadow.withOpacity(0.12),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${activeIdx + 1}/$count',
                      style: AppText.caption.copyWith(
                        fontWeight: FontWeight.w800,
                        color: AppTheme.accentText,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'Next',
                      style: AppText.caption.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.text,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.chevron_right_rounded, size: 16, color: AppTheme.accentText),
                  ],
                ),
              ),
            ),
          ],
          GestureDetector(
            onHorizontalDragUpdate: (details) {
              _dragOffset += details.primaryDelta ?? 0;
            },
            onHorizontalDragEnd: (details) {
              final vel = details.primaryVelocity ?? 0;
              if (vel < -80 || _dragOffset < -40) {
                _nextCapsule(count);
              } else if (vel > 80 || _dragOffset > 40) {
                _prevCapsule(count);
              }
              _dragOffset = 0;
            },
            child: items[activeIdx],
          ),
          const SizedBox(height: Space.s8),
        ],
        fuelButton,
      ],
    );
  }

  void _showFuelQuickSheet(
    BuildContext context, {
    double? usableKm,
    required List<RouteEssential> stations,
    required double progressM,
    double? riderLat,
    double? riderLng,
    Function(RouteEssential station)? onAddStationStop,
    VoidCallback? onOpenFuelSheet,
  }) {
    final isSunlightHud = FeatureGates.isUnlocked(Feature.sunlightHudMode);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(borderRadius: Radii.sheetTop),
      builder: (ctx) {
        final isLow = usableKm != null && usableKm <= 60;
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
                        color: (isLow ? AppTheme.sos : AppTheme.brand).withOpacity(0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.local_gas_station_rounded,
                        color: isLow ? AppTheme.sos : AppTheme.brand,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: Space.s12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(isLow ? 'Low Fuel Warning' : 'Corridor Fuel Stations', style: AppText.title),
                          Text(
                            usableKm != null
                                ? 'Estimated ~${usableKm.round()} km usable range left'
                                : 'Upcoming petrol bunks along active route',
                            style: AppText.caption.copyWith(
                              color: isLow ? AppTheme.sos : AppTheme.accentText,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
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
                      riderLat: riderLat,
                      riderLng: riderLng,
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
                          side: BorderSide(
                            color: isSunlightHud ? AppTheme.border.withOpacity(0.9) : AppTheme.border,
                            width: isSunlightHud ? 2 : 1.5,
                          ),
                          padding: const EdgeInsets.symmetric(vertical: Space.s12, horizontal: Space.s16),
                          minimumSize: const Size(0, 48),
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
    final isSunlightHud = FeatureGates.isUnlocked(Feature.sunlightHudMode);
    return Material(
      color: isSunlightHud ? AppTheme.card : AppTheme.card.withAlpha(245),
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 280, minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSunlightHud ? accentColor : accentColor.withOpacity(0.8),
              width: isSunlightHud ? 2.5 : 1.5,
            ),
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
                        color: isSunlightHud ? AppTheme.accentText : AppTheme.muted,
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
  final double? riderLat;
  final double? riderLng;
  final VoidCallback onAdd;

  const _StationRow({
    required this.station,
    required this.progressM,
    this.riderLat,
    this.riderLng,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final rawAheadM = station.aheadM(progressM);
    final aheadM = (rawAheadM > 0)
        ? rawAheadM
        : (riderLat != null && riderLng != null && riderLat != 0 && riderLng != 0
            ? GeoMath.haversine(riderLat!, riderLng!, station.lat, station.lng)
            : rawAheadM);
    final distStr = formatDistanceRounded(aheadM);
    final isSunlightHud = FeatureGates.isUnlocked(Feature.sunlightHudMode);

    return Container(
      padding: const EdgeInsets.all(Space.s12),
      decoration: BoxDecoration(
        color: AppTheme.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSunlightHud ? AppTheme.border.withOpacity(0.9) : AppTheme.border,
          width: isSunlightHud ? 1.5 : 1,
        ),
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              minimumSize: const Size(0, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: onAdd,
            icon: const Icon(Icons.add_location_alt_rounded, size: 18),
            label: const Text('Add Stop', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

class _SideFuelButton extends StatelessWidget {
  final bool isLowFuel;
  final double? usableKm;
  final VoidCallback onTap;

  const _SideFuelButton({
    required this.isLowFuel,
    required this.usableKm,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final rangeText = usableKm != null ? '${usableKm!.round()} km' : 'Fuel';
    final isSunlightHud = FeatureGates.isUnlocked(Feature.sunlightHudMode);
    final bgColor = isLowFuel
        ? AppTheme.sos
        : (isSunlightHud ? AppTheme.card : AppTheme.card.withAlpha(245));
    final borderColor = isLowFuel
        ? AppTheme.sos
        : (isSunlightHud ? AppTheme.border.withOpacity(0.9) : AppTheme.border.withOpacity(0.6));
    final iconColor = isLowFuel
        ? Colors.white
        : (usableKm != null && usableKm! <= 100 ? AppTheme.warnText : AppTheme.brand);

    return Material(
      color: bgColor,
      elevation: isLowFuel ? 6 : 3,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56, minWidth: 56),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: borderColor, width: isSunlightHud ? 2.5 : 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.local_gas_station_rounded,
                size: 22,
                color: isLowFuel ? Colors.white : iconColor,
              ),
              const SizedBox(width: 8),
              Text(
                isLowFuel ? 'LOW ($rangeText)' : rangeText,
                style: AppText.caption.copyWith(
                  color: isLowFuel ? Colors.white : AppText.body.color,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
