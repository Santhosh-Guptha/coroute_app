import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/explore_service.dart';
import '../../data/services/public_ride_service.dart';
import '../../data/services/safety_service.dart';
import '../../domain/explore/destinations.dart';
import '../engagement/rate_and_feedback.dart';
import '../home/ride_start_view.dart';
import 'ride_detail_screen.dart';

/// Icon for a destination category (outline, matches the chips).
IconData categoryIcon(DestinationCategory c) => switch (c) {
      DestinationCategory.all => Icons.explore_outlined,
      DestinationCategory.breakfast => Icons.free_breakfast_outlined,
      DestinationCategory.night => Icons.nightlight_outlined,
      DestinationCategory.oneDay => Icons.wb_sunny_outlined,
      DestinationCategory.weekend => Icons.hotel_outlined,
      DestinationCategory.twisty => Icons.turn_sharp_right_rounded,
      DestinationCategory.ghats => Icons.terrain_outlined,
    };

/// v3.58 Explore: search + Add, "Rides near you" with category chips, the nearest place as a hero card and the
/// rest as a ranked list (thumbnail, category, ~km, ~time). Distances are worked out on this phone from the
/// rider's last position (never sent anywhere). Cached list first, then the fresh one.
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  static const String title = 'Explore';

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  final _search = TextEditingController();
  List<Destination>? _all = SwrCache.shared.peek<List<Destination>>(ExploreService.cacheKey);
  DestinationCategory _cat = DestinationCategory.all;
  bool _loading = true;
  bool _failed = false;
  (double, double)? _fix;

  @override
  void initState() {
    super.initState();
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
    final cached = await ExploreService.cached();
    if (!mounted) return;
    setState(() {
      _all ??= cached;
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
      final list = await ExploreService(api).load();
      if (mounted) setState(() => _all = list);
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
    if (choice == 'suggest' && mounted) await RateAndFeedback.openFeedback(context, category: FeedbackCategory.other);
  }

  void _open(RankedDestination r) => RideDetailScreen.open(context, r, from: _fix);

  @override
  Widget build(BuildContext context) {
    final all = _all;
    final ranked = all == null ? const <RankedDestination>[] : ExploreRanking.rank(all, lat: _fix?.$1, lng: _fix?.$2, category: _cat, query: _search.text);
    final chips = ExploreRanking.chipsFor(all ?? const []);
    final api = context.read<ApiClient?>();
    final explore = api == null ? null : ExploreService(api);
    final publicRides = context.watch<PublicRideService?>();
    final liveNear = publicRides != null && publicRides.available ? publicRides.rides : const [];

    Widget content;
    if (all == null && _loading) {
      content = const Column(key: Key('explore_skeleton'), children: [SkeletonCard(media: true, lines: 2), SizedBox(height: 12), SkeletonRows(count: 4, trailing: true)]);
    } else if (all == null && _failed) {
      content = SizedBox(height: 360, child: ErrorState(title: 'Could not load rides', onRetry: _load));
    } else if (ranked.isEmpty) {
      content = SizedBox(
        height: 320,
        child: EmptyState(
          icon: Icons.travel_explore_rounded,
          title: _search.text.trim().isNotEmpty ? 'No place matches "${_search.text.trim()}"' : 'No ${_cat.label.toLowerCase()} rides yet',
          message: 'Try another chip, or suggest a place riders should know.',
          primaryLabel: 'Show all',
          onPrimary: () => setState(() {
            _cat = DestinationCategory.all;
            _search.clear();
          }),
        ),
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DestinationHeroCard(key: const Key('explore_hero'), ranked: ranked.first, photoUrl: explore?.photoUrl(ranked.first.destination), headers: api?.authHeaders, onTap: () => _open(ranked.first)),
          if (ranked.length > 1) ...[
            const SizedBox(height: Space.s12),
            DsCard(
              key: const Key('explore_list'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Column(
                children: [
                  for (var i = 1; i < ranked.length; i++)
                    DestinationRow(ranked: ranked[i], photoUrl: explore?.photoUrl(ranked[i].destination), headers: api?.authHeaders, divider: i < ranked.length - 1, onTap: () => _open(ranked[i])),
                ],
              ),
            ),
          ],
        ],
      );
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
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              physics: AppScrollBehavior.physics,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                Semantics(header: true, child: Text(ExploreScreen.title, style: AppText.headline.copyWith(fontSize: 28))),
                const SizedBox(height: Space.s12),
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
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(tooltip: 'Clear search', icon: const Icon(Icons.close_rounded), onPressed: () => setState(_search.clear)),
                        ),
                      ),
                    ),
                    const SizedBox(width: Space.s8),
                    FilledButton.icon(
                      key: const Key('explore_add'),
                      onPressed: _add,
                      style: FilledButton.styleFrom(minimumSize: const Size(56, 56), shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll)),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add'),
                    ),
                  ],
                ),
                const SizedBox(height: Space.s24),
                Semantics(header: true, child: Text('Rides near you', style: AppText.title.copyWith(fontSize: 18))),
                const SizedBox(height: 2),
                Text(
                  _fix == null ? 'Turn on location to rank them by distance from you' : 'Nearest first, worked out on your phone',
                  style: AppText.label,
                ),
                const SizedBox(height: Space.s12),
                SizedBox(
                  height: 48,
                  child: SingleChildScrollView(
                    key: const Key('explore_chips'),
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < chips.length; i++) ...[
                          if (i > 0) const SizedBox(width: Space.s8),
                          _CategoryChip(
                            category: chips[i],
                            selected: chips[i] == _cat,
                            onTap: () {
                              AppHaptics.selection();
                              setState(() => _cat = chips[i]);
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Space.s16),
                if (_failed && all != null) ...[
                  Text('Offline: showing the list saved on your phone.', style: AppText.caption),
                  const SizedBox(height: Space.s8),
                ],
                FadeThroughSwitcher(child: KeyedSubtree(key: ValueKey('${_cat.key}|${all == null}|${ranked.length}'), child: content)),
                if (liveNear.isNotEmpty) ...[
                  const SizedBox(height: Space.s24),
                  Semantics(header: true, child: Text('Public groups riding near you', style: AppText.title.copyWith(fontSize: 18))),
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
  final DestinationCategory category;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryChip({required this.category, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${category.label} rides',
      excludeSemantics: true,
      child: Material(
        color: selected ? AppTheme.primarySoft : AppTheme.card,
        shape: StadiumBorder(side: BorderSide(color: selected ? AppTheme.primary : AppTheme.border2, width: selected ? 1.5 : 1)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('chip_${category.key}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (category != DestinationCategory.all) ...[
                  Icon(categoryIcon(category), size: 18, color: selected ? AppTheme.primary : AppTheme.text2),
                  const SizedBox(width: 6),
                ],
                Text(category.label, style: TextStyle(color: selected ? AppTheme.text : AppTheme.text2, fontWeight: selected ? FontWeight.w600 : FontWeight.w500, fontSize: 14)),
              ],
            ),
          ),
        ),
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
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black.withValues(alpha: 0), Colors.black.withValues(alpha: 0.55)], stops: const [0.35, 1]),
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

/// The nearest place, large: rank badge, category pill, name, "region · ~km · time each way", one line.
class DestinationHeroCard extends StatelessWidget {
  final RankedDestination ranked;
  final String? photoUrl;
  final Map<String, String>? headers;
  final VoidCallback onTap;
  const DestinationHeroCard({super.key, required this.ranked, this.photoUrl, this.headers, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = ranked.destination;
    final meta = destinationMeta(ranked, region: true, eachWay: true);
    return Semantics(
      button: true,
      label: 'Number ${ranked.rank}: ${d.name}, ${d.category.rideLabel}. $meta',
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            final h = (w * 0.62).clamp(200.0, 320.0);
            return SizedBox(
              height: h,
              child: Stack(
                children: [
                  DestinationImage(destination: d, photoUrl: photoUrl, headers: headers, width: w, height: h, borderRadius: Radii.xlAll, scrim: true),
                  Positioned(
                    left: 14,
                    top: 14,
                    right: 14,
                    child: Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                          child: Text('${ranked.rank}', style: TextStyle(color: AppTheme.primaryFill, fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.38), borderRadius: BorderRadius.circular(999)),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(categoryIcon(d.category), color: Colors.white, size: 16),
                                const SizedBox(width: 6),
                                Flexible(child: Text(d.category.rideLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500))),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 14,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(d.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700, height: 1.15)),
                        if (meta.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: DsHeroCard.secondary, fontSize: 14)),
                        ],
                        if (d.description.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(d.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 14)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A ranked list row: number, thumbnail, name, "category · ~km · time", chevron. 72 dp tall at least.
class DestinationRow extends StatelessWidget {
  final RankedDestination ranked;
  final String? photoUrl;
  final Map<String, String>? headers;
  final bool divider;
  final VoidCallback onTap;
  const DestinationRow({super.key, required this.ranked, this.photoUrl, this.headers, this.divider = true, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = ranked.destination;
    final meta = [d.category.label, destinationMeta(ranked)].where((s) => s.isNotEmpty).join(' · ');
    return Semantics(
      button: true,
      label: 'Number ${ranked.rank}: ${d.name}. $meta',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 84),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
          child: Row(
            children: [
              SizedBox(width: 28, child: Text('${ranked.rank}', textAlign: TextAlign.center, style: AppText.title.copyWith(color: AppTheme.text2))),
              const SizedBox(width: 8),
              DestinationImage(destination: d, photoUrl: photoUrl, headers: headers, width: 64, height: 64),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(categoryIcon(d.category), size: 15, color: AppTheme.text2),
                        const SizedBox(width: 4),
                        Expanded(child: Text(meta, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label)),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
            ],
          ),
        ),
      ),
    );
  }
}
