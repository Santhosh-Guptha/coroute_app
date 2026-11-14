import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/map_tiles.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/explore_service.dart';
import '../../domain/explore/destinations.dart';
import '../home/ride_start_view.dart';
import '../ride/navigate_to.dart';
import '../trip_planner/trip_planner_screen.dart';
import 'explore_screen.dart';

/// v3.58 ride detail: photo or illustration, ~km / ~time / category, a route preview, what CoRoute riders' road
/// intel says about the way (hazard hotspots, rough road, twistiness, where riders stop, risky times, fuel), and
/// three ways to go: Ride solo, Plan group ride (the planner with the destination filled in) and Navigate.
class RideDetailScreen extends StatefulWidget {
  final RankedDestination ranked;
  final (double, double)? from;
  const RideDetailScreen({super.key, required this.ranked, this.from});

  static Future<void> open(BuildContext context, RankedDestination r, {(double, double)? from}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RideDetailScreen(ranked: r, from: from)));

  @override
  State<RideDetailScreen> createState() => _RideDetailScreenState();
}

class _RideDetailScreenState extends State<RideDetailScreen> {
  DestinationIntel? _intel;
  bool _intelLoading = true;

  Destination get _d => widget.ranked.destination;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadIntel());
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
                    const SectionTitle('Route preview'),
                    const SizedBox(height: Space.s8),
                    _RoutePreview(dest: _d, from: widget.from),
                    const SizedBox(height: 6),
                    Text(
                      widget.from == null
                          ? 'Turn on location to see the way from you. The planner finds the road.'
                          : 'Straight guide line from you. The planner and your maps app find the road; ~km is an estimate.',
                      style: AppText.caption,
                    ),
                    const SizedBox(height: Space.s24),
                    const SectionTitle('Road intel on the way'),
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
  const _RoutePreview({required this.dest, this.from});

  @override
  Widget build(BuildContext context) {
    final to = LatLng(dest.lat, dest.lng);
    final start = from == null ? null : LatLng(from!.$1, from!.$2);
    final bounds = start == null ? null : LatLngBounds.fromPoints([start, to]);
    return ClipRRect(
      borderRadius: Radii.lgAll,
      child: SizedBox(
        height: 190,
        child: Semantics(
          label: start == null ? 'Map of ${dest.name}' : 'Map from your position to ${dest.name}',
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
