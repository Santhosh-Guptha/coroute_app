import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/map_tiles.dart';
import '../../core/ui/coroute_logo.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/explore_service.dart';
import '../../data/services/public_ride_service.dart';
import '../../data/services/safety_service.dart';
import '../../domain/explore/destinations.dart';
import '../../domain/explore/explore_config.dart';
import '../engagement/rate_and_feedback.dart';
import '../home/ride_start_view.dart';
import 'ride_detail_screen.dart';

/// Icon for a destination category (outline, matches the chips). Custom admin categories use the route icon.
IconData categoryIcon(DestinationCategory c) => switch (c) {
      DestinationCategory.all => Icons.explore_outlined,
      DestinationCategory.breakfast => Icons.free_breakfast_outlined,
      DestinationCategory.night => Icons.nightlight_outlined,
      DestinationCategory.oneDay => Icons.wb_sunny_outlined,
      DestinationCategory.weekend => Icons.hotel_outlined,
      DestinationCategory.twisty => Icons.turn_sharp_right_rounded,
      DestinationCategory.ghats => Icons.terrain_outlined,
    };

IconData categoryIconOf(String id) => switch (id) {
      'all' => Icons.explore_outlined,
      'breakfast' => Icons.free_breakfast_outlined,
      'night' => Icons.nightlight_outlined,
      'one_day' => Icons.wb_sunny_outlined,
      'weekend' => Icons.hotel_outlined,
      'twisty' => Icons.turn_sharp_right_rounded,
      'ghats' => Icons.terrain_outlined,
      _ => Icons.alt_route_rounded,
    };

/// v3.59 Explore, laid out by the admin (web console or in-app admin: sections, their order and titles,
/// categories, featured places) and built around roads:
///  * a live map strip of every place (tap for the full map),
///  * "Picked for you" postcards, "Ridden by CoRoute riders" (places with routes real riders shared),
///  * "Rides near you" as route tickets (a road edge with the distance, never a rank number),
///  * category chips and a "suggest a place" card.
/// Distances are worked out on this phone from the rider's last position (never sent anywhere).
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  static const String title = 'Explore';

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  final _search = TextEditingController();
  ExploreData? _data = SwrCache.shared.peek<ExploreData>(ExploreService.dataKey);
  String _cat = 'all';
  bool _loading = true;
  bool _failed = false;
  (double, double)? _fix;

  @override
  void initState() {
    super.initState();
    // A list cached by v3.58 (destinations only) shows at once with the built-in layout.
    final legacy = SwrCache.shared.peek<List<Destination>>(ExploreService.cacheKey);
    if (_data == null && legacy != null) _data = ExploreData(ExploreConfig.fallback, legacy, const {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final f = context.read<SafetyService?>()?.lastFix;
    if (f != null) _fix = (f.lat, f.lng);
    final api = context.read<ApiClient?>();
    final cached = await ExploreService.cachedData();
    final legacy = cached == null ? await ExploreService.cached() : null;
    if (!mounted) return;
    setState(() {
      _data ??= cached ?? (legacy == null ? null : ExploreData(ExploreConfig.fallback, legacy, const {}));
      _loading = true;
      _failed = false;
    });
    if (_fix == null) {
      try {
        final p = await Geolocator.getLastKnownPosition();
        if (p != null) _fix = (p.latitude, p.longitude);
      } catch (_) {}
    }
    try {
      if (api == null) throw StateError('offline');
      final d = await ExploreService(api).loadData();
      if (mounted) setState(() => _data = d);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    final choice = await showAppSheet<String>(
      context,
      title: 'Add',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DsListRow(icon: Icons.route_outlined, label: 'Plan your own ride', onTap: () => Navigator.pop(ctx, 'plan')),
          DsListRow(icon: Icons.add_location_alt_outlined, label: 'Suggest a destination', divider: false, onTap: () => Navigator.pop(ctx, 'suggest')),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'plan') await RideStartView.startRide(context);
    if (choice == 'suggest' && mounted) await _suggest();
  }

  Future<void> _suggest() => RateAndFeedback.openFeedback(context, category: FeedbackCategory.other);

  void _open(RankedDestination r) => RideDetailScreen.open(context, r, from: _fix, routeCount: _data?.routeCounts[r.destination.id] ?? 0);

  void _openMap(List<RankedDestination> all) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ExploreMapScreen(places: all, from: _fix, onOpen: (r) => _open(r)),
      ));

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final cfg = data?.config ?? ExploreConfig.fallback;
    final all = data?.destinations;
    final query = _search.text.trim();
    final filtering = query.isNotEmpty || _cat != 'all';
    final ranked = all == null ? const <RankedDestination>[] : ExploreRanking.rank(all, lat: _fix?.$1, lng: _fix?.$2, categoryId: _cat, query: query);
    final everyPlace = all == null ? const <RankedDestination>[] : ExploreRanking.rank(all, lat: _fix?.$1, lng: _fix?.$2);
    final byId = {for (final r in everyPlace) r.destination.id: r};
    // Chips: the admin's categories that at least one place uses, in the admin's order.
    final chips = <ExploreCategory>[
      const ExploreCategory('all', 'All'),
      for (final c in cfg.categories)
        if ((all ?? const <Destination>[]).any((d) => d.fitsKey(c.id))) c,
    ];
    final api = context.read<ApiClient?>();
    final explore = api == null ? null : ExploreService(api);
    final publicRides = context.watch<PublicRideService?>();
    final liveNear = publicRides != null && publicRides.available ? publicRides.rides : const [];
    String? photo(Destination d) => explore?.photoUrl(d);

    final sections = <Widget>[];
    void gap([double h = Space.s24]) => sections.add(SizedBox(height: h));

    if (all == null && _loading) {
      sections.add(const Column(key: Key('explore_skeleton'), children: [SkeletonCard(media: true, lines: 2), SizedBox(height: 12), SkeletonRows(count: 4, trailing: true)]));
    } else if (all == null && _failed) {
      sections.add(SizedBox(height: 360, child: ErrorState(title: 'Could not load rides', onRetry: _load)));
    } else if (filtering) {
      // Searching or a chip: one list of matching places, nearest first.
      if (ranked.isEmpty) {
        sections.add(SizedBox(
          height: 320,
          child: EmptyState(
            icon: Icons.travel_explore_rounded,
            title: query.isNotEmpty ? 'No place matches "$query"' : 'No ${cfg.labelOf(_cat).toLowerCase()} yet',
            message: 'Try another type, or suggest a place riders should know.',
            primaryLabel: 'Show all',
            onPrimary: () => setState(() {
              _cat = 'all';
              _search.clear();
            }),
          ),
        ));
      } else {
        sections.add(DestinationPostcard(key: const Key('explore_hero'), ranked: ranked.first, photoUrl: photo(ranked.first.destination), headers: api?.authHeaders, routeCount: data?.routeCounts[ranked.first.destination.id] ?? 0, wide: true, onTap: () => _open(ranked.first)));
        if (ranked.length > 1) {
          gap(Space.s12);
          sections.add(_TicketList(key: const Key('explore_list'), items: ranked.skip(1).toList(), photo: photo, headers: api?.authHeaders, counts: data?.routeCounts ?? const {}, onOpen: _open));
        }
      }
    } else {
      var heroUsed = false;
      for (final s in cfg.sections) {
        switch (s.id) {
          case ExploreSectionId.featured:
            final picks = [for (final id in cfg.featured) ?byId[id]];
            if (picks.isEmpty) break;
            gap();
            sections.add(RoadSectionHeader(s.title));
            gap(Space.s12);
            final isFirstHero = !heroUsed;
            heroUsed = true;
            sections.add(SizedBox(
              height: 248,
              child: ListView.separated(
                key: const Key('explore_featured'),
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                itemCount: picks.length,
                separatorBuilder: (_, _) => const SizedBox(width: Space.s12),
                itemBuilder: (_, i) => SizedBox(
                  width: 220,
                  child: DestinationPostcard(
                    key: isFirstHero && i == 0 ? const Key('explore_hero') : null,
                    ranked: picks[i],
                    photoUrl: photo(picks[i].destination),
                    headers: api?.authHeaders,
                    routeCount: data?.routeCounts[picks[i].destination.id] ?? 0,
                    onTap: () => _open(picks[i]),
                  ),
                ),
              ),
            ));
          case ExploreSectionId.riderRoutes:
            if (!cfg.routesEnabled) break;
            final ridden = [for (final r in everyPlace) if ((data?.routeCounts[r.destination.id] ?? 0) > 0) r]
              ..sort((a, b) => (data!.routeCounts[b.destination.id] ?? 0).compareTo(data.routeCounts[a.destination.id] ?? 0));
            gap();
            sections.add(RoadSectionHeader(s.title, subtitle: ridden.isEmpty ? 'Share your next ride to a place here and guide the riders after you.' : 'Real routes riders chose to share, with their tips.'));
            gap(Space.s12);
            if (ridden.isEmpty) {
              sections.add(_BeFirstCard(onPlan: () => RideStartView.startRide(context)));
            } else {
              sections.add(Column(key: const Key('explore_ridden'), children: [
                for (var i = 0; i < ridden.length && i < 5; i++) ...[
                  if (i > 0) const SizedBox(height: Space.s8),
                  _RiddenCard(ranked: ridden[i], count: data!.routeCounts[ridden[i].destination.id] ?? 0, photoUrl: photo(ridden[i].destination), headers: api?.authHeaders, onTap: () => _open(ridden[i])),
                ],
              ]));
            }
          case ExploreSectionId.nearYou:
            if (everyPlace.isEmpty) break;
            gap();
            sections.add(RoadSectionHeader(s.title, subtitle: _fix == null ? 'Turn on location to sort them by distance from you' : 'Nearest first, worked out on your phone'));
            gap(Space.s12);
            final list = heroUsed ? everyPlace : everyPlace.skip(1).toList();
            if (!heroUsed) {
              sections.add(DestinationPostcard(key: const Key('explore_hero'), ranked: everyPlace.first, photoUrl: photo(everyPlace.first.destination), headers: api?.authHeaders, routeCount: data?.routeCounts[everyPlace.first.destination.id] ?? 0, wide: true, onTap: () => _open(everyPlace.first)));
              heroUsed = true;
              if (list.isNotEmpty) gap(Space.s12);
            }
            if (list.isNotEmpty) sections.add(_TicketList(key: const Key('explore_list'), items: list, photo: photo, headers: api?.authHeaders, counts: data?.routeCounts ?? const {}, onOpen: _open));
          case ExploreSectionId.categories:
            // The chips sit under the search; this section adds big type tiles.
            if (chips.length <= 2) break;
            gap();
            sections.add(RoadSectionHeader(s.title));
            gap(Space.s12);
            sections.add(Wrap(spacing: Space.s8, runSpacing: Space.s8, children: [
              for (final c in chips.skip(1))
                _TypeTile(category: c, count: (all ?? const <Destination>[]).where((d) => d.fitsKey(c.id)).length, onTap: () => setState(() => _cat = c.id)),
            ]));
          case ExploreSectionId.suggest:
            gap();
            sections.add(_SuggestCard(title: s.title, onSuggest: _suggest));
        }
      }
      if (!heroUsed && everyPlace.isNotEmpty) {
        // Every list section is switched off: still show one place so the tab is never empty.
        gap();
        sections.add(DestinationPostcard(key: const Key('explore_hero'), ranked: everyPlace.first, photoUrl: photo(everyPlace.first.destination), headers: api?.authHeaders, wide: true, onTap: () => _open(everyPlace.first)));
      }
    }

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: ContentWidth(
          maxWidth: 680,
          child: AppRefresh(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 112),
              physics: AppScrollBehavior.physics,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                Semantics(header: true, child: Text(cfg.headline, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.headline.copyWith(fontSize: 28, height: 1.15))),
                if (cfg.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(cfg.subtitle, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.label),
                ],
                const SizedBox(height: Space.s16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('explore_search'),
                        controller: _search,
                        textInputAction: TextInputAction.search,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: 'Search places',
                          prefixIcon: const Icon(Icons.search_rounded),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(tooltip: 'Clear search', icon: const Icon(Icons.close_rounded), onPressed: () => setState(_search.clear)),
                        ),
                      ),
                    ),
                    const SizedBox(width: Space.s8),
                    Semantics(
                      button: true,
                      label: 'Add: plan your own ride or suggest a place',
                      excludeSemantics: true,
                      child: Material(
                        key: const Key('explore_add'),
                        color: AppTheme.primaryFill,
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(onTap: _add, child: SizedBox(width: 56, height: 56, child: Icon(Icons.add_road_rounded, color: AppTheme.onPrimary))),
                      ),
                    ),
                  ],
                ),
                if (everyPlace.isNotEmpty && !_underTest) ...[
                  const SizedBox(height: Space.s16),
                  _MapStrip(places: everyPlace, from: _fix, onTap: () => _openMap(everyPlace)),
                ],
                if (chips.length > 1) ...[
                  const SizedBox(height: Space.s16),
                  SizedBox(
                    height: 48,
                    // A plain scrolling Row (not a lazy list) so every chip is built and reachable, as in 10030.
                    child: SingleChildScrollView(
                      key: const Key('explore_chips'),
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var i = 0; i < chips.length; i++) ...[
                            if (i > 0) const SizedBox(width: Space.s8),
                            _CategoryChip(
                              category: chips[i],
                              selected: chips[i].id == _cat,
                              onTap: () {
                                AppHaptics.selection();
                                setState(() => _cat = chips[i].id);
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
                if (_failed && all != null) ...[
                  const SizedBox(height: Space.s8),
                  Text('Offline: showing the list saved on your phone.', style: AppText.caption),
                ],
                FadeThroughSwitcher(
                  child: KeyedSubtree(
                    key: ValueKey('$_cat|$query|${all == null}|${ranked.length}'),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [if (filtering) const SizedBox(height: Space.s16), ...sections]),
                  ),
                ),
                if (liveNear.isNotEmpty) ...[
                  const SizedBox(height: Space.s24),
                  const RoadSectionHeader('Public groups riding near you'),
                  const SizedBox(height: Space.s8),
                  DsCard(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    child: Column(
                      children: [
                        for (var i = 0; i < liveNear.length && i < 5; i++)
                          DsListRow(
                            icon: Icons.groups_outlined,
                            label: liveNear[i].label,
                            value: '${liveNear[i].riders} riders · ${liveNear[i].distanceKm} km',
                            divider: i < liveNear.length - 1 && i < 4,
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final ExploreCategory category;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryChip({required this.category, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: category.id == 'all' ? 'All places' : category.label,
      excludeSemantics: true,
      child: Material(
        color: selected ? AppTheme.primaryFill : AppTheme.card,
        // Square-ish chips with a road edge when selected: our own shape, not the usual pills.
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: selected ? AppTheme.primaryFill : AppTheme.border2)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('chip_${category.id}'),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (category.id != 'all') ...[
                    Icon(categoryIconOf(category.id), size: 18, color: selected ? AppTheme.onPrimary : AppTheme.text2),
                    const SizedBox(width: 6),
                  ],
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(category.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: selected ? AppTheme.onPrimary : AppTheme.text2, fontWeight: FontWeight.w600, fontSize: 14)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Widget tests have no network: the map strip (OpenStreetMap tiles) is left out there.
bool get _underTest {
  if (kIsWeb) return false;
  try {
    return Platform.environment['FLUTTER_TEST'] == 'true';
  } catch (_) {
    return false;
  }
}

/// Every place on a small live map; tap opens the full map.
class _MapStrip extends StatelessWidget {
  final List<RankedDestination> places;
  final (double, double)? from;
  final VoidCallback onTap;
  const _MapStrip({required this.places, required this.from, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pts = [for (final p in places) LatLng(p.destination.lat, p.destination.lng), if (from != null) LatLng(from!.$1, from!.$2)];
    final bounds = pts.length >= 2 ? LatLngBounds.fromPoints(pts) : null;
    return Semantics(
      button: true,
      label: 'Map of ${places.length} places. Open the full map.',
      excludeSemantics: true,
      child: Pressable(
        key: const Key('explore_map_strip'),
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            height: 150,
            child: Stack(
              children: [
                AbsorbPointer(
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: pts.first,
                      initialZoom: 7,
                      initialCameraFit: bounds == null ? null : CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(28)),
                      interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                    ),
                    children: [
                      appTileLayer(),
                      MarkerLayer(markers: [
                        for (final p in places) Marker(point: LatLng(p.destination.lat, p.destination.lng), width: 18, height: 18, child: const _Pin()),
                        if (from != null) Marker(point: LatLng(from!.$1, from!.$2), width: 18, height: 18, child: const _YouDot()),
                      ]),
                    ],
                  ),
                ),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(color: AppTheme.card, borderRadius: BorderRadius.circular(12), boxShadow: dsFloatingShadow()),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.map_outlined, size: 18, color: AppTheme.primary),
                      const SizedBox(width: 6),
                      Text('Open map', style: AppText.label.copyWith(color: AppTheme.text, fontWeight: FontWeight.w600)),
                    ]),
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

class _Pin extends StatelessWidget {
  const _Pin();
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: CoRouteBrand.amber, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3)),
      );
}

class _YouDot extends StatelessWidget {
  const _YouDot();
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: AppTheme.primary, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3)),
      );
}

/// Full-screen map of every place; tap a pin for its card.
class ExploreMapScreen extends StatefulWidget {
  final List<RankedDestination> places;
  final (double, double)? from;
  final ValueChanged<RankedDestination> onOpen;
  const ExploreMapScreen({super.key, required this.places, this.from, required this.onOpen});

  @override
  State<ExploreMapScreen> createState() => _ExploreMapScreenState();
}

class _ExploreMapScreenState extends State<ExploreMapScreen> {
  RankedDestination? _sel;

  @override
  Widget build(BuildContext context) {
    final pts = [for (final p in widget.places) LatLng(p.destination.lat, p.destination.lng), if (widget.from != null) LatLng(widget.from!.$1, widget.from!.$2)];
    final bounds = pts.length >= 2 ? LatLngBounds.fromPoints(pts) : null;
    final sel = _sel;
    return Scaffold(
      appBar: AppBar(title: const Text('Places on the map')),
      body: Stack(
        children: [
          FlutterMap(
            options: MapOptions(
              initialCenter: pts.first,
              initialZoom: 7,
              initialCameraFit: bounds == null ? null : CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(48)),
              onTap: (_, _) => setState(() => _sel = null),
            ),
            children: [
              appTileLayer(),
              MarkerLayer(markers: [
                for (final p in widget.places)
                  Marker(
                    point: LatLng(p.destination.lat, p.destination.lng),
                    width: 48,
                    height: 48,
                    child: Semantics(
                      button: true,
                      label: p.destination.name,
                      child: GestureDetector(onTap: () => setState(() => _sel = p), child: Center(child: SizedBox(width: 22, height: 22, child: const _Pin()))),
                    ),
                  ),
                if (widget.from != null) Marker(point: LatLng(widget.from!.$1, widget.from!.$2), width: 20, height: 20, child: const _YouDot()),
              ]),
            ],
          ),
          if (sel != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16 + MediaQuery.paddingOf(context).bottom,
              child: DsCard(
                onTap: () => widget.onOpen(sel),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(sel.destination.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
                          Text(destinationMeta(sel, region: true), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Photo (admin-uploaded, our gateway only) or our own illustration.
class DestinationImage extends StatelessWidget {
  final Destination destination;
  final String? photoUrl;
  final Map<String, String>? headers;
  final double width;
  final double height;
  final BorderRadius borderRadius;
  final bool scrim;
  const DestinationImage({super.key, required this.destination, this.photoUrl, this.headers, required this.width, required this.height, this.borderRadius = Radii.mdAll, this.scrim = false});

  @override
  Widget build(BuildContext context) {
    final art = PlaceArt(seed: destination.name, night: destination.category == DestinationCategory.night, width: width, height: height, borderRadius: borderRadius, scrim: scrim);
    final url = photoUrl;
    if (url == null) return art;
    return Stack(
      children: [
        AppNetworkImage(url, width: width, height: height, headers: headers, borderRadius: borderRadius, fallback: art, semanticLabel: destination.name),
        if (scrim)
          IgnorePointer(
            child: Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black.withValues(alpha: 0), Colors.black.withValues(alpha: 0.6)], stops: const [0.3, 1]),
              ),
            ),
          ),
      ],
    );
  }
}

String destinationMeta(RankedDestination r, {bool region = false, bool eachWay = false}) => [
      if (region && r.destination.region.isNotEmpty) r.destination.region,
      if (r.roadKm != null) ExploreRanking.kmLabel(r.roadKm),
      if (r.rideTime != null) '${ExploreRanking.timeLabel(r.rideTime)}${eachWay ? ' each way' : ''}',
    ].join(' · ');

/// A place as a postcard: photo with a stamp-like corner (rider route count) and a road strip along the bottom
/// edge. [wide] = full width (the first match / nearest place).
class DestinationPostcard extends StatelessWidget {
  final RankedDestination ranked;
  final String? photoUrl;
  final Map<String, String>? headers;
  final int routeCount;
  final bool wide;
  final VoidCallback onTap;
  const DestinationPostcard({super.key, required this.ranked, this.photoUrl, this.headers, this.routeCount = 0, this.wide = false, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = ranked.destination;
    final meta = destinationMeta(ranked, region: true, eachWay: wide);
    final routes = routeCount == 1 ? '1 rider route' : '$routeCount rider routes';
    return Semantics(
      button: true,
      label: '${d.name}. $meta${routeCount > 0 ? '. $routes' : ''}',
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        child: LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth;
          final h = wide ? (w * 0.56).clamp(190.0, 300.0) : (box.maxHeight.isFinite ? box.maxHeight : 248.0);
          return SizedBox(
            height: h,
            child: Container(
              decoration: BoxDecoration(color: AppTheme.card, borderRadius: BorderRadius.circular(22), border: Border.all(color: AppTheme.border), boxShadow: dsFloatingShadow()),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(child: LayoutBuilder(builder: (_, b) => DestinationImage(destination: d, photoUrl: photoUrl, headers: headers, width: b.maxWidth, height: b.maxHeight, borderRadius: BorderRadius.zero, scrim: true))),
                        if (routeCount > 0)
                          Positioned(
                            right: 10,
                            top: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(color: CoRouteBrand.amber, borderRadius: BorderRadius.circular(8)),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                const Icon(Icons.alt_route_rounded, size: 14, color: CoRouteBrand.ink),
                                const SizedBox(width: 4),
                                Text('$routeCount', style: const TextStyle(color: CoRouteBrand.ink, fontWeight: FontWeight.w800, fontSize: 13)),
                              ]),
                            ),
                          ),
                        Positioned(
                          left: 14,
                          right: 14,
                          bottom: 12,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Icon(categoryIconOf(d.catId), color: Colors.white, size: 15),
                                const SizedBox(width: 4),
                                Flexible(child: Text(d.category.rideLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600))),
                              ]),
                              const SizedBox(height: 2),
                              Text(d.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: wide ? 24 : 19, fontWeight: FontWeight.w800, height: 1.15)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const RoadStripe(axis: Axis.horizontal, width: 6),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                    child: Text(meta.isEmpty ? (d.description.isEmpty ? d.region : d.description) : meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// "Rides near you": route tickets. A road edge on the left with the distance, a thumbnail, the name and the
/// type; no rank numbers.
class _TicketList extends StatelessWidget {
  final List<RankedDestination> items;
  final String? Function(Destination) photo;
  final Map<String, String>? headers;
  final Map<String, int> counts;
  final ValueChanged<RankedDestination> onOpen;
  const _TicketList({super.key, required this.items, required this.photo, required this.headers, required this.counts, required this.onOpen});

  @override
  Widget build(BuildContext context) => Column(children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(height: Space.s8),
          RouteTicket(ranked: items[i], photoUrl: photo(items[i].destination), headers: headers, routeCount: counts[items[i].destination.id] ?? 0, onTap: () => onOpen(items[i])),
        ],
      ]);
}

class RouteTicket extends StatelessWidget {
  final RankedDestination ranked;
  final String? photoUrl;
  final Map<String, String>? headers;
  final int routeCount;
  final VoidCallback onTap;
  const RouteTicket({super.key, required this.ranked, this.photoUrl, this.headers, this.routeCount = 0, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = ranked.destination;
    final km = ExploreRanking.kmLabel(ranked.roadKm).replaceFirst('~', '');
    final time = ExploreRanking.timeLabel(ranked.rideTime);
    final kind = d.category.rideLabel;
    return Semantics(
      button: true,
      label: '${d.name}. $kind${km.isEmpty ? '' : ', about $km, $time'}${routeCount > 0 ? ', $routeCount rider routes' : ''}',
      excludeSemantics: true,
      child: Material(
        color: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: AppTheme.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The ticket stub: distance over a short road.
                Container(
                  width: 64,
                  color: AppTheme.tint,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (km.isNotEmpty) ...[
                        FittedBox(fit: BoxFit.scaleDown, child: Text(km.replaceAll(' km', ''), style: AppText.title.copyWith(fontWeight: FontWeight.w800, color: AppTheme.accentText))),
                        Text('km', style: AppText.caption),
                      ] else
                        Icon(categoryIconOf(d.catId), color: AppTheme.accentText),
                      const SizedBox(height: 6),
                      const RoadStripe(width: 5, height: 22),
                    ],
                  ),
                ),
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 84),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                      child: Row(
                        children: [
                          DestinationImage(destination: d, photoUrl: photoUrl, headers: headers, width: 56, height: 56, borderRadius: BorderRadius.circular(12)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(d.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
                                const SizedBox(height: 2),
                                Text([kind, if (time.isNotEmpty) time].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label),
                                if (routeCount > 0) ...[
                                  const SizedBox(height: 2),
                                  Row(children: [
                                    const Icon(Icons.alt_route_rounded, size: 14, color: CoRouteBrand.amber),
                                    const SizedBox(width: 4),
                                    Expanded(child: Text(routeCount == 1 ? '1 rider route' : '$routeCount rider routes', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption)),
                                  ]),
                                ],
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
                        ],
                      ),
                    ),
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

class _RiddenCard extends StatelessWidget {
  final RankedDestination ranked;
  final int count;
  final String? photoUrl;
  final Map<String, String>? headers;
  final VoidCallback onTap;
  const _RiddenCard({required this.ranked, required this.count, this.photoUrl, this.headers, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = ranked.destination;
    final label = count == 1 ? '1 rider shared their route' : '$count riders shared their routes';
    return DsCard(
      onTap: onTap,
      semanticsLabel: '${d.name}. $label',
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          DestinationImage(destination: d, photoUrl: photoUrl, headers: headers, width: 64, height: 64, borderRadius: BorderRadius.circular(14)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Icons.alt_route_rounded, size: 16, color: CoRouteBrand.amber),
                  const SizedBox(width: 6),
                  Expanded(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label)),
                ]),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
        ],
      ),
    );
  }
}

class _BeFirstCard extends StatelessWidget {
  final VoidCallback onPlan;
  const _BeFirstCard({required this.onPlan});

  @override
  Widget build(BuildContext context) => DsCard(
        key: const Key('explore_be_first'),
        dashed: true,
        child: Row(
          children: [
            const RoadStripe(width: 6, height: 56),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Be the first to guide others', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
                  const SizedBox(height: 2),
                  Text('After your next ride to one of these places, share your route from the trip report.', maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.label),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(tooltip: 'Start a ride', onPressed: onPlan, constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.two_wheeler_rounded)),
          ],
        ),
      );
}

class _TypeTile extends StatelessWidget {
  final ExploreCategory category;
  final int count;
  final VoidCallback onTap;
  const _TypeTile({required this.category, required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: '${category.label}, $count places',
        excludeSemantics: true,
        child: SizedBox(
          width: 148,
          child: DsCard(
            onTap: onTap,
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(categoryIconOf(category.id), color: AppTheme.accentText),
                const SizedBox(height: 8),
                Text(category.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                Text(count == 1 ? '1 place' : '$count places', style: AppText.caption),
              ],
            ),
          ),
        ),
      );
}

class _SuggestCard extends StatelessWidget {
  final String title;
  final VoidCallback onSuggest;
  const _SuggestCard({required this.title, required this.onSuggest});

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    final isLargeText = scale > 1.4;
    return DsCard(
      tinted: true,
      child: isLargeText
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.add_location_alt_outlined, color: AppTheme.accentText, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text('Tell us the place; we add the good ones for every rider.', maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.label),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(onPressed: onSuggest, style: TextButton.styleFrom(minimumSize: const Size(64, 48)), child: const Text('Suggest')),
                ),
              ],
            )
          : Row(
              children: [
                Icon(Icons.add_location_alt_outlined, color: AppTheme.accentText, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
                      Text('Tell us the place; we add the good ones for every rider.', maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.label),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(onPressed: onSuggest, style: TextButton.styleFrom(minimumSize: const Size(64, 48)), child: const Text('Suggest')),
              ],
            ),
    );
  }
}
