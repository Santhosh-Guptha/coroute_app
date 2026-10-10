import '../../data/models/rider_model.dart';
import '../../data/services/convoy_service.dart';

import '../../data/services/settings_service.dart';

import '../../domain/safety/group_fuel.dart';

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../core/ui/ui.dart';

import '../../data/models/route_essential.dart';

import '../../data/models/route_model.dart';

import '../../data/services/api_client.dart';

import '../../data/services/route_essentials_service.dart';

import '../../data/services/safety_service.dart';

import '../../domain/safety/fuel_profile.dart';

import 'fuel_sheet.dart';



const essentialCategories = {'FUEL': 'Fuel', 'FOOD': 'Food', 'HOSPITAL': 'Hospital', 'REPAIR': 'Repair', 'REST': 'Rest', 'STAY': 'Stay',

  'PHARMACY': 'Pharmacy', 'TYRE': 'Tyre repair', 'WASHROOM': 'Washroom', 'ATM': 'ATM', 'POLICE': 'Police', 'PARKING': 'Parking', 'SCENIC': 'Scenic'};



class EssentialsRow extends StatelessWidget {

  final RouteEssentialsService service;

  final VoidCallback onTap;

  const EssentialsRow({super.key, required this.service, required this.onTap});

  @override

  Widget build(BuildContext context) => ListenableBuilder(listenable: service, builder: (_, _) {

    final next = service.upcoming.firstOrNull;

    final s = service.snapshot;

    return ListTile(dense: true, contentPadding: const EdgeInsets.symmetric(horizontal: Space.s16),

      leading: const Icon(Icons.route_rounded), title: Text(next == null ? 'Route essentials' : '${essentialCategories[service.category]} · ${formatDistanceRounded(next.aheadM(service.progressM))} ahead', style: AppText.label),

      subtitle: Text(service.loading ? 'Checking mapped places…' : s == null ? (service.offline ? 'Offline · no saved places for this route' : service.error ?? 'Fuel, food, hospitals and more')

        : '${s.places.length} mapped · ${service.reliable ? 'View' : 'Cached or partial coverage'}', style: AppText.caption),

      onTap: onTap, trailing: const Icon(Icons.chevron_right_rounded));

  });

}



Future<void> showEssentialsSheet(BuildContext context, {required RouteEssentialsService service,

    required Future<void> Function(String category, bool force) refresh,

    bool Function(RouteEssential place)? addStop, bool leader = false, bool moving = false}) => showAppSheet<void>(context,

  title: 'Route essentials', isScrollControlled: true,

  builder: (_) => _EssentialsSheet(service: service, refresh: refresh, addStop: addStop, leader: leader, moving: moving));



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

    final group = GroupFuelSummary.calculate([

      for (final r in convoy?.riders.values ?? const <RiderModel>[])

        if (r.userId != convoyService?.myUserId && r.fuelUsableKm != null)

          SharedFuelRange(r.userId, r.fuelUsableKm!, r.fuelUpdatedAt, r.lastSeenEpochMs),

      if (convoyService?.myUserId != null && settings?.shareFuelEstimate == true && fuel != null && safety?.fuelEstimateUncertain == false)

        SharedFuelRange(convoyService!.myUserId!, fuel, now, convoy?.riders[convoyService.myUserId]?.lastSeenEpochMs ?? 0),

    ], total: convoy?.riders.length ?? 0, now: now);

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

    return ListView(shrinkWrap: true, children: [

      Wrap(spacing: Space.s8, runSpacing: Space.s4, children: [

        for (final e in essentialCategories.entries.take(more ? essentialCategories.length : 6))

          ChoiceChip(label: Text(e.value), selected: service.category == e.key, onSelected: (_) => widget.refresh(e.key, false)),

        ActionChip(label: Text(more ? 'Less' : 'More'), onPressed: () => setState(() => more = !more)),

      ]),

      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Next 100 km'), value: next100, onChanged: (v) => setState(() => next100 = v)),

      if (service.category == 'FUEL') ...[

        Text(fuel == null ? 'Fuel estimate not set' : 'Estimated usable range: ${fuel.floor()} km', style: AppText.title),

        if (safety?.fuelEstimateUncertain == true) Text('Tracking gaps · update your estimate', style: AppText.label),

        Text(adviceText, style: AppText.body),

        if (widget.leader && group.total > 0) Padding(padding: const EdgeInsets.symmetric(vertical: Space.s8),

          child: Text('Group fuel: ${group.contributors}/${group.total} current estimates${group.lowestKm == null ? '' : ' · lowest ${group.lowestKm!.floor()} km'}. Distances to a shared stop differ by rider.', style: AppText.label)),

        if (!moving && safety != null) TextButton(onPressed: () => showFuelSheet(context), child: const Text('Refuel / fuel profile')),

        if (following != null && next != null) Text('Next after this: ${formatDistanceRounded(following.routePositionM - next.routePositionM)} along the route', style: AppText.label),

      ],

      if (snapshot != null) ...[

        Text('${service.offline || !snapshot.freshAt(DateTime.now().millisecondsSinceEpoch) ? 'Cached · ' : ''}Updated ${DateTime.fromMillisecondsSinceEpoch(snapshot.fetchedAt).toLocal()}', style: AppText.caption),

        Text('Coverage: ${formatDistanceRounded(snapshot.fromM)}–${formatDistanceRounded(snapshot.toM)} into route. ${snapshot.complete ? 'Mapped results are not exhaustive.' : 'Partial results; other places may be missing.'}', style: AppText.caption),

      ],

      if (service.error != null) Text(service.error!, style: AppText.label),

      if (service.cacheSaveFailed) Text('Could not save places on this device.', style: AppText.label),

      if (service.loading) const LinearProgressIndicator(),

      if (places.isEmpty && !service.loading) Padding(padding: const EdgeInsets.symmetric(vertical: Space.s16), child: Text('No mapped options available in this view. This does not mean there are no services.', style: AppText.body)),

      for (final p in places) Padding(padding: const EdgeInsets.symmetric(vertical: Space.s12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        Text(p.name, style: AppText.title),

        Text('${formatDistanceRounded(p.aheadM(service.progressM))} ahead along route · ${formatDistanceRounded(p.detourDistanceM)} additional detour · ${(p.detourDurationS / 60).ceil()} min', style: AppText.body),

        if (p.roadDistanceM(service.progressM) case final distance?) Text('Road distance to place: ${formatDistanceRounded(distance)}', style: AppText.label),

        Text('Opening status unknown${p.openingHours == null ? '' : ' · Mapped hours: ${p.openingHours}'}', style: AppText.caption),

        if (widget.addStop != null && !moving) OutlinedButton(onPressed: service.offline || sent.contains(p.visitId) ? null : () {

          if (widget.addStop!(p)) setState(() => sent.add(p.visitId));

        }, child: Text(sent.contains(p.visitId) ? 'Requested' : widget.leader ? 'Add stop' : 'Suggest stop')),

      ])),

      if (!moving) OutlinedButton(onPressed: service.loading || service.offline ? null : () => widget.refresh(service.category, true), child: const Text('Refresh')),

      if (snapshot != null) Text(snapshot.attribution, style: AppText.caption),

    ]);

  });

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

