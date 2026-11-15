import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/coroute_logo.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/explore_service.dart';
import '../../domain/explore/destinations.dart';
import '../../domain/explore/explore_config.dart';

/// v3.59 trip report card: "Guide other riders to (place)". Shown only when this ride reached one of the Explore
/// destinations and rider routes are on. Nothing is shared until the rider ticks the consent box and taps Share.
/// The phone leaves out the first and last kilometre (the gateway checks again), and the rider can delete the
/// route any time (My shared routes).
class ShareRouteCard extends StatefulWidget {
  /// This rider's own recorded track (lat, lng), from the phone.
  final List<(double, double)> track;
  final DateTime? endedAt;
  final int? durationMin;
  final String bike;
  const ShareRouteCard({super.key, required this.track, this.endedAt, this.durationMin, this.bike = ''});

  @override
  State<ShareRouteCard> createState() => _ShareRouteCardState();
}

class _ShareRouteCardState extends State<ShareRouteCard> {
  List<Destination> _reached = const [];
  bool _enabled = false;
  Destination? _dest;
  bool _consent = false;
  bool _busy = false;
  String? _done;
  String? _error;
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _find());
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    if (widget.track.length < 2 || RouteSharing.trimEnds(widget.track).length < 2) return;
    final api = context.read<ApiClient?>();
    ExploreData? data = await ExploreService.cachedData();
    if (data == null && api != null) {
      try {
        data = await ExploreService(api).loadData();
      } catch (_) {}
    }
    if (!mounted || data == null) return;
    final reached = RouteSharing.reached(widget.track, data.destinations);
    setState(() {
      _enabled = data!.config.routesEnabled;
      _reached = reached;
      _dest = reached.isEmpty ? null : reached.first;
    });
  }

  Future<void> _share() async {
    final api = context.read<ApiClient?>();
    final d = _dest;
    if (api == null || d == null || !_consent) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final (_, first) = await ExploreService(api).shareRoute(destId: d.id, track: widget.track, durationMin: widget.durationMin, endedAt: widget.endedAt, note: _note.text, bike: widget.bike);
      if (!mounted) return;
      AppHaptics.medium();
      setState(() => _done = first
          ? 'Shared. You are the first rider to guide others to ${d.name}.'
          : 'Shared. Riders heading to ${d.name} can now see the way you went.');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not share right now. Try again when you have signal.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _dest;
    if (!_enabled || d == null) return const SizedBox.shrink();
    final done = _done;
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: DsCard(
        key: const Key('share_route_card'),
        tinted: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.alt_route_rounded, color: CoRouteBrand.amber, size: 26)),
                const SizedBox(width: 10),
                Expanded(child: Text(done == null ? 'Guide other riders to ${d.name}' : 'Thank you for guiding other riders', maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.title)),
              ],
            ),
            const SizedBox(height: 6),
            if (done != null) ...[
              Text(done, style: AppText.body),
              const SizedBox(height: 4),
              TextButton(onPressed: () => MySharedRoutesScreen.open(context), style: TextButton.styleFrom(minimumSize: const Size(48, 44), padding: EdgeInsets.zero), child: const Text('My shared routes')),
            ] else ...[
              Text('Your route shows on ${d.name} in Explore, so the next riders know the way.', style: AppText.label),
              if (_reached.length > 1) ...[
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: d.id,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Place'),
                  items: [for (final r in _reached) DropdownMenuItem(value: r.id, child: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis))],
                  onChanged: (v) => setState(() => _dest = _reached.firstWhere((r) => r.id == v, orElse: () => d)),
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                controller: _note,
                maxLength: 140,
                maxLines: 2,
                minLines: 1,
                decoration: const InputDecoration(labelText: 'A tip for other riders (optional)', hintText: 'Fuel after the toll, go before 6 am'),
              ),
              CheckboxListTile(
                key: const Key('share_route_consent'),
                value: _consent,
                onChanged: _busy ? null : (v) => setState(() => _consent = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text('Share this route to guide other riders', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                subtitle: Text('Your username shows with it. The first and last kilometre are left out and no time of day is shown. Delete it any time.', style: AppText.caption),
              ),
              if (_error != null) ...[
                Text(_error!, style: AppText.label.copyWith(color: AppTheme.warnText)),
                const SizedBox(height: 6),
              ],
              SizedBox(
                width: double.infinity,
                child: DsButton(
                  key: const Key('share_route_button'),
                  label: _busy ? 'Sharing…' : 'Share route',
                  icon: Icons.alt_route_rounded,
                  height: 52,
                  onPressed: _consent && !_busy ? _share : null,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The routes I shared: see where they show, delete any.
class MySharedRoutesScreen extends StatefulWidget {
  const MySharedRoutesScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MySharedRoutesScreen()));

  @override
  State<MySharedRoutesScreen> createState() => _MySharedRoutesScreenState();
}

class _MySharedRoutesScreenState extends State<MySharedRoutesScreen> {
  List<RiderRoute>? _routes;
  Map<String, String> _names = const {};
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final api = context.read<ApiClient?>();
    if (api == null) return;
    try {
      final svc = ExploreService(api);
      final list = await svc.myRoutes();
      final data = await ExploreService.cachedData();
      if (!mounted) return;
      setState(() {
        _routes = list;
        _names = {for (final d in data?.destinations ?? const <Destination>[]) d.id: d.name};
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load your routes.');
    }
  }

  Future<void> _delete(RiderRoute r) async {
    final ok = await confirmAction(context, title: 'Delete this route?', message: 'Riders will no longer see it on ${_names[r.destId] ?? 'Explore'}.', confirmLabel: 'Delete', destructive: true);
    if (!ok || !mounted) return;
    final api = context.read<ApiClient?>();
    try {
      await ExploreService(api!).deleteRoute(r.id);
      await _load();
      if (mounted) showAppToast(context, 'Route deleted');
    } catch (_) {
      if (mounted) showAppToast(context, 'Could not delete. Try again.', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _routes;
    return Scaffold(
      appBar: AppBar(title: const Text('My shared routes')),
      body: list == null
          ? (_error != null ? ErrorState(title: _error!, onRetry: _load) : const Padding(padding: EdgeInsets.all(20), child: SkeletonRows(count: 3)))
          : list.isEmpty
              ? const EmptyState(icon: Icons.alt_route_rounded, title: 'No shared routes', message: 'After a ride to an Explore place, the trip report lets you share your route to guide other riders.')
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final r = list[i];
                    return DsCard(
                      child: Row(
                        children: [
                          SizedBox(width: 64, child: RouteSparkline(points: r.points, height: 52)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_names[r.destId] ?? 'Explore place', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
                                Text([r.dayLabel, '${r.distanceKm.toStringAsFixed(1)} km', if (r.status == 'hidden') 'hidden by a moderator'].where((s) => s.isNotEmpty).join(' · '),
                                    maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label),
                              ],
                            ),
                          ),
                          IconButton(tooltip: 'Delete route', onPressed: () => _delete(r), constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: Icon(Icons.delete_outline_rounded, color: AppTheme.text2)),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
