import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/map_tiles.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/explore_service.dart';
import '../../core/ui/coroute_logo.dart';
import '../../domain/explore/destinations.dart';
import '../../domain/explore/explore_config.dart';
import '../home/ride_start_view.dart';
import '../ride/navigate_to.dart';
import '../trip_planner/trip_planner_screen.dart';
import 'explore_screen.dart';

/// v3.58 ride detail: photo or illustration, ~km / ~time / category, a route preview, what CoRoute riders' road
/// intel says about the way (hazard hotspots, rough road, twistiness, where riders stop, risky times, fuel), and
/// three ways to go: Ride solo, Plan group ride (the planner with the destination filled in) and Navigate.
///
/// v3.59: "Ridden by CoRoute riders": the routes real riders chose to share to this place (opt-in, first and last km
/// left out), drawn on the map with their username, day, distance, riding time and tip. With none yet, an invitation
/// to be the first to guide others.
class RideDetailScreen extends StatefulWidget {
  final RankedDestination ranked;
  final (double, double)? from;

  /// Shared routes known from the Explore list (0 = none known; the screen still asks the server).
  final int routeCount;
  const RideDetailScreen({super.key, required this.ranked, this.from, this.routeCount = 0});

  static Future<void> open(BuildContext context, RankedDestination r, {(double, double)? from, int routeCount = 0}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RideDetailScreen(ranked: r, from: from, routeCount: routeCount)));

  @override
  State<RideDetailScreen> createState() => _RideDetailScreenState();
}

class _RideDetailScreenState extends State<RideDetailScreen> {
  DestinationIntel? _intel;
  bool _intelLoading = true;
  List<RiderRoute>? _routes;
  bool _routesLoading = true;
  int _selected = 0;

  Destination get _d => widget.ranked.destination;

  @override
  void initState() {
    super.initState();
    _routes = ExploreService.cachedRoutes(_d.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadIntel();
      _loadRoutes();
    });
  }

  Future<void> _loadRoutes() async {
    final api = context.read<ApiClient?>();
    if (api == null || !api.hasToken) {
      setState(() => _routesLoading = false);
      return;
    }
    final list = await ExploreService(api).routesFor(_d.id);
    if (!mounted) return;
    setState(() {
      _routes = list;
      _routesLoading = false;
      if (_selected >= list.length) _selected = 0;
    });
  }

  Future<void> _loadIntel() async {
    final api = context.read<ApiClient?>();
    if (api == null) {
      setState(() => _intelLoading = false);
      return;
    }
    final i = await ExploreService(api).intelFor(_d, fromLat: widget.from?.$1, fromLng: widget.from?.$2);
    if (mounted) {
      setState(() {
        _intel = i;
        _intelLoading = false;
      });
    }
  }

  /// The planner opens with the destination's coordinates in its search box (3.56 "Share to CoRoute" path).
  Future<void> _planGroup() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'map/planner'),
      builder: (_) => TripPlannerScreen(sharedText: '${_d.lat.toStringAsFixed(5)}, ${_d.lng.toStringAsFixed(5)}'),
    ));
  }

  Future<void> _navigate() async {
    final ok = await navigateTo(_d.lat, _d.lng, label: _d.name, startLat: widget.from?.$1, startLng: widget.from?.$2);
    if (!ok && mounted) showAppToast(context, 'No maps app could open this place.', error: true);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.ranked;
    final api = context.read<ApiClient?>();
    final photo = api == null ? null : ExploreService(api).photoUrl(_d);
    final meta = destinationMeta(r, eachWay: true);
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: CustomScrollView(
        physics: AppScrollBehavior.physics,
        slivers: [
          SliverToBoxAdapter(
            child: LayoutBuilder(builder: (context, box) {
              final w = box.maxWidth;
              final h = (w * 0.66).clamp(220.0, 360.0);
              final top = MediaQuery.paddingOf(context).top;
              return SizedBox(
                height: h,
                child: Stack(
                  children: [
                    DestinationImage(destination: _d, photoUrl: photo, headers: api?.authHeaders, width: w, height: h, borderRadius: BorderRadius.zero, scrim: true),
                    Positioned(
                      left: 16,
                      top: top + 8,
                      child: DsRoundButton(icon: Icons.chevron_left_rounded, label: 'Back', size: 48, onTap: () => Navigator.maybePop(context)),
                    ),
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: 18,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(header: true, child: Text(_d.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700, height: 1.15))),
                          if (_d.region.isNotEmpty) Text(_d.region, style: const TextStyle(color: DsHeroCard.secondary, fontSize: 15)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
          SliverToBoxAdapter(
            child: ContentWidth(
              maxWidth: 680,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        InfoPill(icon: categoryIcon(_d.category), text: _d.category.rideLabel, color: AppTheme.accentText, background: AppTheme.tint),
                        for (final t in _d.tags) InfoPill(icon: categoryIcon(t), text: t.label),
                        if (meta.isNotEmpty) InfoPill(icon: Icons.straighten_rounded, text: meta),
                      ],
                    ),
                    if (_d.description.isNotEmpty) ...[
                      const SizedBox(height: Space.s12),
                      Text(_d.description, style: AppText.body),
                    ],
                    const SizedBox(height: Space.s24),
                    RoadSectionHeader((_routes ?? const []).isNotEmpty ? 'The way riders went' : 'Route preview'),
                    const SizedBox(height: Space.s8),
                    _RoutePreview(dest: _d, from: widget.from, routes: _routes ?? const [], selected: _selected),
                    const SizedBox(height: 6),
                    Text(
                      (_routes ?? const []).isNotEmpty
                          ? 'A route a CoRoute rider shared (the first and last kilometre are left out). The planner finds the road from you.'
                          : widget.from == null
                              ? 'Turn on location to see the way from you. The planner finds the road.'
                              : 'Straight guide line from you. The planner and your maps app find the road; ~km is an estimate.',
                      style: AppText.caption,
                    ),
                    const SizedBox(height: Space.s24),
                    const RoadSectionHeader('Ridden by CoRoute riders', subtitle: 'Routes riders chose to share after their ride.'),
                    const SizedBox(height: Space.s8),
                    _RiderRoutes(
                      routes: _routes,
                      loading: _routesLoading && _routes == null,
                      selected: _selected,
                      onSelect: (i) => setState(() => _selected = i),
                      onPlan: _planGroup,
                    ),
                    const SizedBox(height: Space.s24),
                    const RoadSectionHeader('Road intel on the way'),
                    const SizedBox(height: 2),
                    Text('From CoRoute riders, anonymous and only where enough riders passed.', style: AppText.caption),
                    const SizedBox(height: Space.s8),
                    _IntelCard(intel: _intel, loading: _intelLoading, onRetry: () {
                      setState(() => _intelLoading = true);
                      _loadIntel();
                    }),
                    const SizedBox(height: Space.s24),
                    DsCard(
                      tinted: true,
                      child: Row(
                        children: [
                          Icon(Icons.shield_outlined, color: AppTheme.accentText),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'On this ride: crash detection, SOS that works without data, hazard and twisty-road warnings, and a live link your family can follow.',
                              style: AppText.label.copyWith(color: AppTheme.text),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomActionBar(
        children: [
          Row(
            children: [
              Expanded(child: DsButton(key: const Key('detail_solo'), label: 'Ride solo', icon: Icons.person_outline_rounded, tone: DsButtonTone.outline, height: 52, fontSize: 15, onPressed: () => RideStartView.startRide(context))),
              const SizedBox(width: Space.s8),
              Expanded(child: DsButton(key: const Key('detail_group'), label: 'Plan group ride', icon: Icons.groups_rounded, height: 52, fontSize: 15, onPressed: _planGroup)),
            ],
          ),
          TextButton.icon(
            key: const Key('detail_navigate'),
            onPressed: _navigate,
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: const Icon(Icons.navigation_outlined),
            label: const Text('Navigate in your maps app'),
          ),
        ],
      ),
    );
  }
}

class _RoutePreview extends StatelessWidget {
  final Destination dest;
  final (double, double)? from;
  final List<RiderRoute> routes;
  final int selected;
  const _RoutePreview({required this.dest, this.from, this.routes = const [], this.selected = 0});

  @override
  Widget build(BuildContext context) {
    final to = LatLng(dest.lat, dest.lng);
    final sel = routes.isEmpty ? null : routes[selected.clamp(0, routes.length - 1)];
    final start = sel != null ? null : (from == null ? null : LatLng(from!.$1, from!.$2));
    final selPts = sel == null ? const <LatLng>[] : [for (final p in sel.points) LatLng(p.$1, p.$2)];
    final bounds = sel != null ? LatLngBounds.fromPoints([...selPts, to]) : (start == null ? null : LatLngBounds.fromPoints([start, to]));
    return ClipRRect(
      borderRadius: Radii.lgAll,
      child: SizedBox(
        height: sel != null ? 230 : 190,
        child: Semantics(
          label: sel != null ? 'Map of the route @${sel.username} took to ${dest.name}' : (start == null ? 'Map of ${dest.name}' : 'Map from your position to ${dest.name}'),
          image: true,
          excludeSemantics: true,
          child: AbsorbPointer(
            // A preview: the map does not take the page's scroll gestures.
            child: FlutterMap(
              options: MapOptions(
                initialCenter: to,
                initialZoom: start == null ? 10 : 8,
                initialCameraFit: bounds == null ? null : CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(36)),
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
              ),
              children: [
                appTileLayer(),
                if (sel != null)
                  PolylineLayer(polylines: [
                    for (final r in routes)
                      if (r != sel) Polyline(points: [for (final p in r.points) LatLng(p.$1, p.$2)], strokeWidth: 3, color: AppTheme.primary.withValues(alpha: 0.28)),
                    Polyline(points: selPts, strokeWidth: 6, color: AppTheme.primaryFill, borderStrokeWidth: 2, borderColor: Colors.white),
                  ]),
                if (start != null)
                  PolylineLayer(polylines: [
                    Polyline(points: [start, to], strokeWidth: 4, color: AppTheme.primary, pattern: StrokePattern.dashed(segments: const [12, 10])),
                  ]),
                MarkerLayer(markers: [
                  if (start != null)
                    Marker(point: start, width: 22, height: 22, child: Container(decoration: BoxDecoration(color: AppTheme.primary, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3)))),
                  Marker(point: to, width: 40, height: 40, alignment: Alignment.topCenter, child: Icon(Icons.location_on_rounded, color: AppTheme.accent, size: 40)),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IntelCard extends StatelessWidget {
  final DestinationIntel? intel;
  final bool loading;
  final VoidCallback onRetry;
  const _IntelCard({required this.intel, required this.loading, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (loading) return const SkeletonCard(lines: 3);
    final i = intel;
    if (i == null || i.isEmpty) {
      return DsCard(
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, color: AppTheme.text2),
            const SizedBox(width: 12),
            Expanded(child: Text('Not enough rider data on this way yet. Hazard, rough road and twisty warnings still speak up during the ride.', style: AppText.label)),
            IconButton(tooltip: 'Try again', onPressed: onRetry, constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: Icon(Icons.refresh_rounded, color: AppTheme.text2)),
          ],
        ),
      );
    }
    final rows = <(IconData, String, String, bool)>[
      (Icons.warning_amber_rounded, 'Hazard hotspots', i.hazardSpots == 0 ? 'None known' : '${i.hazardSpots}${i.highHazardSpots > 0 ? ' (${i.highHazardSpots} high)' : ''}', i.highHazardSpots > 0),
      (Icons.add_road_rounded, 'Rough road', i.roughSpots == 0 ? 'None known' : '${i.roughSpots} stretches', false),
      (Icons.turn_sharp_right_rounded, 'Twistiness', i.twistiness == 0 ? 'Gentle' : '${i.twistiness}/100${i.ghat ? ' · ghat' : ''}', false),
      (Icons.local_cafe_outlined, 'Where riders stop', i.stops.isEmpty ? 'No usual stop yet' : i.stops.join(', '), false),
      (Icons.local_gas_station_outlined, 'Fuel', 'The planner checks fuel gaps on your route', false),
      if (i.riskyTimes != null) (Icons.schedule_rounded, 'Risky times', i.riskyTimes!, true),
    ];
    return DsCard(
      key: const Key('detail_intel'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Column(
        children: [
          for (var k = 0; k < rows.length; k++)
            Container(
              constraints: const BoxConstraints(minHeight: 52),
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(border: k < rows.length - 1 ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(rows[k].$1, size: 22, color: rows[k].$4 ? AppTheme.warnText : AppTheme.accentText),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(rows[k].$2, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                        Text(rows[k].$3, style: AppText.label.copyWith(color: rows[k].$4 ? AppTheme.warnText : AppTheme.text2)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The shared routes: one card each (username, day, distance, time, tip, a small drawing). Tap to show it on the map.
class _RiderRoutes extends StatelessWidget {
  final List<RiderRoute>? routes;
  final bool loading;
  final int selected;
  final ValueChanged<int> onSelect;
  final VoidCallback onPlan;
  const _RiderRoutes({required this.routes, required this.loading, required this.selected, required this.onSelect, required this.onPlan});

  @override
  Widget build(BuildContext context) {
    if (loading) return const SkeletonCard(lines: 2);
    final list = routes ?? const <RiderRoute>[];
    if (list.isEmpty) {
      return DsCard(
        key: const Key('detail_be_first'),
        dashed: true,
        child: Row(
          children: [
            const RoadStripe(width: 6, height: 64),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('No rider has shared a route here yet', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
                  const SizedBox(height: 4),
                  Text('Ride it and be the first to guide others: after the ride, share your route from the trip report.', maxLines: 4, overflow: TextOverflow.ellipsis, style: AppText.label),
                  const SizedBox(height: 8),
                  TextButton.icon(onPressed: onPlan, style: TextButton.styleFrom(minimumSize: const Size(48, 44), padding: EdgeInsets.zero), icon: const Icon(Icons.route_outlined), label: const Text('Plan this ride')),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      key: const Key('detail_rider_routes'),
      children: [
        for (var i = 0; i < list.length; i++) ...[
          if (i > 0) const SizedBox(height: Space.s8),
          _RouteCard(route: list[i], selected: i == selected, onTap: () => onSelect(i)),
        ],
      ],
    );
  }
}

class _RouteCard extends StatelessWidget {
  final RiderRoute route;
  final bool selected;
  final VoidCallback onTap;
  const _RouteCard({required this.route, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final facts = [
      '${route.distanceKm.toStringAsFixed(route.distanceKm < 100 ? 1 : 0)} km',
      if (route.durationLabel.isNotEmpty) route.durationLabel,
      if (route.dayLabel.isNotEmpty) route.dayLabel,
    ].join(' · ');
    return Semantics(
      button: true,
      selected: selected,
      label: 'Route by @${route.username}: $facts.${route.note.isEmpty ? '' : ' Tip: ${route.note}'} ${selected ? 'Shown on the map.' : 'Show on the map.'}',
      excludeSemantics: true,
      child: Material(
        color: selected ? AppTheme.tint : AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: selected ? AppTheme.primaryFill : AppTheme.border, width: selected ? 1.5 : 1)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 72, child: RouteSparkline(points: route.points, height: 56, color: selected ? AppTheme.primaryFill : AppTheme.primary)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('@${route.username}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                      Text(facts, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label),
                      if (route.bike.isNotEmpty) Text(route.bike, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                      if (route.note.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.tips_and_updates_outlined, size: 16, color: CoRouteBrand.amber),
                            const SizedBox(width: 6),
                            Expanded(child: Text(route.note, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: AppTheme.text))),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
