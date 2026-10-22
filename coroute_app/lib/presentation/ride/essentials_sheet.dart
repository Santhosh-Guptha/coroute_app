import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/rider_model.dart';
import '../../data/models/route_essential.dart';
import '../../data/models/route_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/route_essentials_service.dart';
import '../../data/services/safety_service.dart';
import '../../data/services/settings_service.dart';
import '../../domain/safety/fuel_profile.dart';
import '../../domain/safety/group_fuel.dart';
import 'fuel_sheet.dart';

const essentialCategories = {'FUEL': 'Fuel', 'FOOD': 'Food', 'HOSPITAL': 'Hospital', 'REPAIR': 'Repair', 'REST': 'Rest', 'STAY': 'Stay',
  'PHARMACY': 'Pharmacy', 'TYRE': 'Tyre repair', 'WASHROOM': 'Washroom', 'ATM': 'ATM', 'POLICE': 'Police', 'PARKING': 'Parking', 'SCENIC': 'Scenic'};

/// Rounded outline icon for each essentials category (the station tile).
IconData essentialIcon(String category) {
  switch (category) {
    case 'FUEL':
      return Icons.local_gas_station_rounded;
    case 'FOOD':
      return Icons.restaurant_rounded;
    case 'HOSPITAL':
      return Icons.local_hospital_rounded;
    case 'REPAIR':
      return Icons.build_rounded;
    case 'REST':
      return Icons.airline_seat_recline_normal_rounded;
    case 'STAY':
      return Icons.hotel_rounded;
    case 'PHARMACY':
      return Icons.medication_rounded;
    case 'TYRE':
      return Icons.tire_repair_rounded;
    case 'WASHROOM':
      return Icons.wc_rounded;
    case 'ATM':
      return Icons.atm_rounded;
    case 'POLICE':
      return Icons.local_police_rounded;
    case 'PARKING':
      return Icons.local_parking_rounded;
    case 'SCENIC':
      return Icons.landscape_rounded;
  }
  return Icons.place_rounded;
}

class EssentialsRow extends StatelessWidget {
  final RouteEssentialsService service;
  final VoidCallback onTap;
  const EssentialsRow({super.key, required this.service, required this.onTap});

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: service, builder: (_, _) {
    final next = service.upcoming.firstOrNull;
    final s = service.snapshot;
    final title = next == null ? 'Route essentials' : '${essentialCategories[service.category]} · ${formatDistanceRounded(next.aheadM(service.progressM))} ahead';
    final subtitle = service.loading ? 'Checking mapped places…' : s == null ? (service.offline ? 'Offline · no saved places for this route' : service.error ?? 'Fuel, food, hospitals and more')
      : '${s.places.length} mapped · ${service.reliable ? 'View' : 'Cached or partial coverage'}';
    return DsCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: AppTheme.tint, borderRadius: BorderRadius.circular(12)),
            child: Icon(Icons.route_rounded, size: 22, color: AppTheme.accentText),
          ),
          const SizedBox(width: Space.s12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w800)),
                Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label),
              ],
            ),
          ),
          const SizedBox(width: Space.s8),
          Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
        ],
      ),
    );
  });
}

bool _isEssentialsSheetShowing = false;

Future<void> showEssentialsSheet(
  BuildContext context, {
  required RouteEssentialsService service,
  required Future<void> Function(String category, bool force) refresh,
  bool Function(RouteEssential place)? addStop,
  bool leader = false,
  bool moving = false,
}) async {
  if (_isEssentialsSheetShowing) return;
  _isEssentialsSheetShowing = true;
  try {
    await showAppSheet<void>(
      context,
      title: 'Route essentials',
      isScrollControlled: true,
      builder: (_) => _EssentialsSheet(
        service: service,
        refresh: refresh,
        addStop: addStop,
        leader: leader,
        moving: moving,
      ),
    );
  } finally {
    _isEssentialsSheetShowing = false;
  }
}

class _EssentialsSheet extends StatefulWidget {
  final RouteEssentialsService service;
  final Future<void> Function(String, bool) refresh;
  final bool Function(RouteEssential)? addStop;
  final bool leader, moving;
  const _EssentialsSheet({required this.service, required this.refresh, this.addStop, required this.leader, required this.moving});
  @override
  State<_EssentialsSheet> createState() => _EssentialsSheetState();
}

class _EssentialsSheetState extends State<_EssentialsSheet> {
  bool more = false, next100 = false;
  final Set<String> sent = {};

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.service, builder: (context, _) {
    final service = widget.service, snapshot = service.snapshot;
    final safety = context.watch<SafetyService?>();
    final fuel = safety?.estimatedUsableKm;
    final convoyService = context.watch<ConvoyService?>();
    final convoy = convoyService?.activeConvoy;
    final settings = context.watch<SettingsService?>();
    final now = DateTime.now().millisecondsSinceEpoch;
    final shared = <SharedFuelRange>[
      for (final r in convoy?.riders.values ?? const <RiderModel>[])
        if (r.userId != convoyService?.myUserId && r.fuelUsableKm != null)
          SharedFuelRange(r.userId, r.fuelUsableKm!, r.fuelUpdatedAt, r.lastSeenEpochMs),
      if (convoyService?.myUserId != null && settings?.shareFuelEstimate == true && fuel != null && safety?.fuelEstimateUncertain == false)
        SharedFuelRange(convoyService!.myUserId!, fuel, now, convoy?.riders[convoyService.myUserId]?.lastSeenEpochMs ?? 0),
    ];
    final group = GroupFuelSummary.calculate(shared, total: convoy?.riders.length ?? 0, now: now);
    // The rider with the least fresh shared range (the group's bottleneck).
    SharedFuelRange? lowest;
    for (final f in shared) {
      if (f.freshAt(now) && (lowest == null || f.usableKm < lowest.usableKm)) lowest = f;
    }

    final groupStop = convoy == null || !convoy.featurePolicy.groupFuelEnabled ? null : commonFuelStop(
      riders: [for (final r in convoy.riders.values)
        if (r.userId == convoyService?.myUserId) ...[
          if (settings?.shareFuelEstimate == true && fuel != null && safety?.fuelEstimateUncertain == false)
            PositionedFuelRange(SharedFuelRange(r.userId, fuel, now, r.lastSeenEpochMs), r.lat, r.lng)
        ] else ...[
          if (r.fuelUsableKm != null) PositionedFuelRange(SharedFuelRange(r.userId, r.fuelUsableKm!, r.fuelUpdatedAt, r.lastSeenEpochMs), r.lat, r.lng)
        ]
      ], total: convoy.riders.length, now: now, route: convoy.route?.points ?? [],
      stations: service.upcoming, reliable: service.reliable && convoy.route?.approximate == false);

    final moving = widget.moving || (convoy?.riders[convoyService?.myUserId]?.speedKmh ?? 0) > 5;
    final upcoming = service.upcoming;
    final places = next100 ? upcoming.where((p) => p.aheadM(service.progressM) <= 100000).toList() : upcoming;
    final next = upcoming.firstOrNull;
    final following = upcoming.length > 1 ? upcoming[1] : null;
    final advice = fuelAdvice(usableKm: fuel, nextKm: next?.roadDistanceM(service.progressM) == null ? null : next!.roadDistanceM(service.progressM)! / 1000,
      followingKm: following?.roadDistanceM(service.progressM) == null ? null : following!.roadDistanceM(service.progressM)! / 1000,
      reliable: service.reliable && safety?.fuelEstimateUncertain == false);
    final adviceText = switch (advice) {
      FuelAdvice.unknown => 'Not enough current information to assess skipping a station.',
      FuelAdvice.withinEstimate => 'The following mapped station is within your estimate. Availability is unconfirmed.',
      FuelAdvice.consider => 'Consider refuelling. The following option is near the estimate limit or not mapped in this window.',
      FuelAdvice.recommended => 'Refuelling at the next mapped station is recommended.',
      FuelAdvice.rangeRisk => 'Your estimated usable range may not reach the next mapped station.',
    };
    final adviceWarn = advice == FuelAdvice.recommended || advice == FuelAdvice.rangeRisk;
    final adviceColor = switch (advice) {
      FuelAdvice.unknown => AppTheme.muted,
      FuelAdvice.withinEstimate => AppTheme.accentText,
      _ => AppTheme.warnText,
    };
    final adviceIcon = switch (advice) {
      FuelAdvice.unknown => Icons.help_outline_rounded,
      FuelAdvice.withinEstimate => Icons.check_rounded,
      FuelAdvice.consider => Icons.info_outline_rounded,
      _ => Icons.warning_amber_rounded,
    };
    final lowestName = lowest == null
        ? null
        : lowest.riderId == convoyService?.myUserId
            ? 'You'
            : (convoy?.riders[lowest.riderId]?.name.split(' ').first ?? 'A rider');
    final lowestInitials = lowest == null
        ? ''
        : lowest.riderId == convoyService?.myUserId
            ? 'ME'
            : _initials(convoy?.riders[lowest.riderId]?.name ?? '');
    final categoryLabel = essentialCategories[service.category] ?? 'Places';

    return ListView(shrinkWrap: true, children: [
      Wrap(spacing: Space.s8, runSpacing: Space.s4, children: [
        for (final e in essentialCategories.entries.take(more ? essentialCategories.length : 6))
          ChoiceChip(
            label: Text(e.value),
            selected: service.category == e.key,
            showCheckmark: false,
            selectedColor: AppTheme.brand,
            labelStyle: TextStyle(color: service.category == e.key ? Colors.white : AppTheme.text, fontWeight: FontWeight.w700, fontSize: 13),
            side: BorderSide(color: service.category == e.key ? AppTheme.brand : AppTheme.border, width: 2),
            onSelected: (_) => widget.refresh(e.key, false),
          ),
        ActionChip(label: Text(more ? 'Less' : 'More'), onPressed: () => setState(() => more = !more)),
      ]),
      const SizedBox(height: Space.s8),
      DsSwitchRow(label: 'Next 100 km', value: next100, divider: false, onChanged: (v) => setState(() => next100 = v)),
      if (service.category == 'FUEL') ...[
        const SizedBox(height: Space.s8),
        DsCard(
          radius: Radii.xl,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('YOUR USABLE RANGE', style: AppText.overline),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: fuel == null
                    ? Text('Fuel estimate not set', style: AppText.title.copyWith(fontSize: 20, color: AppTheme.muted))
                    : Text.rich(
                        TextSpan(
                          text: '${fuel.floor()} ',
                          style: TextStyle(
                            color: AppTheme.accentText,
                            fontSize: 44,
                            fontWeight: FontWeight.w800,
                            height: 1,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                          children: [
                            TextSpan(text: 'km', style: TextStyle(color: AppTheme.muted, fontSize: 18, fontWeight: FontWeight.w800)),
                          ],
                        ),
                        maxLines: 1,
                      ),
              ),
              if (safety?.fuelEstimateUncertain == true) ...[
                const SizedBox(height: 6),
                Text('Tracking gaps · update your estimate', style: AppText.label.copyWith(color: AppTheme.warnText, fontWeight: FontWeight.w700)),
              ],
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(adviceIcon, size: 18, color: adviceColor),
                  const SizedBox(width: Space.s8),
                  Expanded(
                    child: Text(adviceText, style: TextStyle(color: adviceWarn ? AppTheme.warnText : AppTheme.text, fontSize: 14, fontWeight: FontWeight.w700, height: 1.3)),
                  ),
                ],
              ),
              if (following != null && next != null) ...[
                const SizedBox(height: 6),
                Text('Next after this: ${formatDistanceRounded(following.routePositionM - next.routePositionM)} along the route', style: AppText.label),
              ],
              if (!moving && safety != null) ...[
                const SizedBox(height: Space.s12),
                DsButton(
                  tone: DsButtonTone.outline,
                  height: 48,
                  fontSize: 15,
                  icon: Icons.local_gas_station_rounded,
                  label: 'Update fuel',
                  onPressed: () => showFuelSheet(context),
                ),
              ],
            ],
          ),
        ),
        if (widget.leader && group.total > 0) ...[
          const SizedBox(height: Space.s12),
          DsCard(
            warning: true,
            color: AppTheme.warnTint,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (lowest != null) DsAvatar(lowestInitials, warning: true) else _IconDisc(Icons.local_gas_station_rounded, color: AppTheme.warnText),
                    const SizedBox(width: Space.s12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            lowest == null ? 'Group fuel' : '$lowestName ${lowest.riderId == convoyService?.myUserId ? 'have' : 'has'} the least range',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: AppTheme.warnText, fontSize: 15, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${group.lowestKm == null ? '' : 'About ${group.lowestKm!.floor()} km left · '}${group.contributors}/${group.total} current estimates',
                            style: AppText.label.copyWith(color: AppTheme.text2),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.s8),
                Text('Distances to a shared stop differ by rider.', style: AppText.caption),
                const SizedBox(height: 6),
                Text(groupStop == null
                  ? "No common station can be confirmed from all riders' current estimates and route positions."
                  : 'Common mapped stop: ${groupStop.station.name}. Smallest estimated usable range left after arrival: ${groupStop.smallestRemainingKm.floor()} km. Opening and fuel availability are unconfirmed.', style: AppText.label),
                if (groupStop != null)
                  for (final entry in groupStop.distanceKm.entries)
                    Text('${convoy?.riders[entry.key]?.name ?? 'Rider'}: ${entry.value.toStringAsFixed(1)} km to station', style: AppText.caption),
              ],
            ),
          ),
        ],
      ],
      if (snapshot != null) ...[
        const SizedBox(height: Space.s12),
        Text('${service.offline || !snapshot.freshAt(DateTime.now().millisecondsSinceEpoch) ? 'Cached · ' : ''}Updated ${DateTime.fromMillisecondsSinceEpoch(snapshot.fetchedAt).toLocal()}', style: AppText.caption),
        Text('Coverage: ${formatDistanceRounded(snapshot.fromM)}-${formatDistanceRounded(snapshot.toM)} into route. ${snapshot.complete ? 'Mapped results are not exhaustive.' : 'Partial results; other places may be missing.'}', style: AppText.caption),
      ],
      if (service.error != null) Padding(padding: const EdgeInsets.only(top: Space.s8), child: Text(service.error!, style: AppText.label.copyWith(color: AppTheme.warnText))),
      if (service.cacheSaveFailed) Padding(padding: const EdgeInsets.only(top: Space.s4), child: Text('Could not save places on this device.', style: AppText.label.copyWith(color: AppTheme.warnText))),
      if (service.loading) Padding(padding: const EdgeInsets.only(top: Space.s8), child: LinearProgressIndicator(color: AppTheme.brand, backgroundColor: AppTheme.map)),
      const SizedBox(height: 18),
      DsSectionHeader('$categoryLabel ahead on route'),
      const SizedBox(height: 10),
      if (places.isEmpty && !service.loading)
        DsCard(
          dashed: true,
          child: Text('No mapped options available in this view. This does not mean there are no services.', style: AppText.body.copyWith(color: AppTheme.text2)),
        ),
      for (var i = 0; i < places.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _PlaceCard(
            place: places[i],
            progressM: service.progressM,
            best: groupStop != null && groupStop.station.visitId == places[i].visitId,
            next: i == 0 && places[i].visitId == next?.visitId,
            action: widget.addStop == null || moving
                ? null
                : DsButton(
                    tone: sent.contains(places[i].visitId) ? DsButtonTone.outline : DsButtonTone.brand,
                    height: 48,
                    fontSize: 15,
                    icon: sent.contains(places[i].visitId) ? Icons.check_rounded : Icons.add_rounded,
                    label: sent.contains(places[i].visitId) ? 'Requested' : widget.leader ? 'Add stop' : 'Suggest stop',
                    onPressed: service.offline || sent.contains(places[i].visitId)
                        ? null
                        : () {
                            if (widget.addStop!(places[i])) setState(() => sent.add(places[i].visitId));
                          },
                  ),
          ),
        ),
      if (!moving) ...[
        const SizedBox(height: Space.s4),
        DsButton(
          tone: DsButtonTone.outline,
          icon: Icons.refresh_rounded,
          label: 'Refresh',
          onPressed: service.loading || service.offline ? null : () => widget.refresh(service.category, true),
        ),
      ],
      if (snapshot != null) Padding(padding: const EdgeInsets.only(top: Space.s12), child: Text(snapshot.attribution, textAlign: TextAlign.center, style: AppText.caption)),
    ]);
  });
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, parts.first.length >= 2 ? 2 : 1);
  return parts.first[0] + parts.last[0];
}

/// 44 px round icon on a card with a coloured ring (the group-fuel card
/// when no single rider stands out).
class _IconDisc extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _IconDisc(this.icon, {required this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(shape: BoxShape.circle, color: AppTheme.card, border: Border.all(color: color, width: 3)),
        child: Icon(icon, size: 22, color: color),
      );
}

/// A mapped place on the route: 48 px tinted icon square, name, how far
/// ahead and the detour, opening hours, and an optional stop button.
/// [best] marks the group's common stop (teal border + BEST), [next] the
/// nearest one ahead.
class _PlaceCard extends StatelessWidget {
  final RouteEssential place;
  final double progressM;
  final bool best;
  final bool next;
  final Widget? action;

  const _PlaceCard({required this.place, required this.progressM, this.best = false, this.next = false, this.action});

  @override
  Widget build(BuildContext context) {
    final p = place;
    final road = p.roadDistanceM(progressM);
    final a = action;
    return DsCard(
      accent: best,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: best ? AppTheme.tint : AppTheme.soft, borderRadius: BorderRadius.circular(14)),
                child: Icon(essentialIcon(p.category), size: 24, color: AppTheme.accentText),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
                    const SizedBox(height: 3),
                    Text(
                      '${formatDistanceRounded(p.aheadM(progressM))} ahead along route · ${formatDistanceRounded(p.detourDistanceM)} additional detour · ${(p.detourDurationS / 60).ceil()} min',
                      style: AppText.label,
                    ),
                    if (road != null) Text('Road distance to place: ${formatDistanceRounded(road)}', style: AppText.label),
                    const SizedBox(height: 3),
                    Text('Opening status unknown${p.openingHours == null ? '' : ' · Mapped hours: ${p.openingHours}'}', style: AppText.caption),
                  ],
                ),
              ),
              if (best || next) ...[
                const SizedBox(width: Space.s8),
                DsChip(best ? 'BEST' : 'NEXT'),
              ],
            ],
          ),
          if (a != null) ...[
            const SizedBox(height: Space.s12),
            a,
          ],
        ],
      ),
    );
  }
}

/// A separate controller keeps pre-ride inspection from replacing live-ride data.
class EssentialsPreview extends StatefulWidget {
  final RouteModel route;
  const EssentialsPreview({super.key, required this.route});
  @override
  State<EssentialsPreview> createState() => _EssentialsPreviewState();
}

class _EssentialsPreviewState extends State<EssentialsPreview> {
  RouteEssentialsService? service;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final api = context.read<ApiClient?>();
    if (api != null && service == null) service = RouteEssentialsService(api);
  }

  @override
  void dispose() { service?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final s = service;
    if (s == null) return const SizedBox.shrink();
    return EssentialsRow(service: s, onTap: () {
      final lowData = context.read<SettingsService?>()?.lowData ?? false;
      s.update(widget.route, fromM: 0, online: true, lowData: lowData);
      showEssentialsSheet(context, service: s, refresh: (c, force) => s.update(widget.route, fromM: 0, online: true, lowData: lowData, selectedCategory: c, force: force));
    });
  }
}
