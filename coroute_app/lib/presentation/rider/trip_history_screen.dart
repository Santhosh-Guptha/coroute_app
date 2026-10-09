import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/settings_service.dart';
import '../../data/services/trip_storage_service.dart';
import '../../data/services/auth_service.dart';
import '../report/trip_report_screen.dart';
import '../../core/theme/map_tiles.dart';
import 'rider_home_screen.dart';

/// The Trips tab: ride totals on top, then one clean row per trip (name,
/// date, distance, riding time). Tapping a trip opens its report. Pull down
/// to sync; a quiet sync also runs when the list opens. Never blocks: the
/// saved trips stay visible while syncing.
class TripHistoryScreen extends StatefulWidget {
  /// True when shown as a tab of the home shell (no back button).
  final bool embedded;

  const TripHistoryScreen({super.key, this.embedded = false});

  @override
  State<TripHistoryScreen> createState() => _TripHistoryScreenState();
}

class _TripHistoryScreenState extends State<TripHistoryScreen> {
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _triggerSync());
  }

  Future<void> _triggerSync() async {
    if (!mounted || _isSyncing) return;
    setState(() => _isSyncing = true);
    final auth = context.read<AuthService>();
    final tripStorage = context.read<TripStorageService>();
    try {
      await tripStorage.syncWithCloud(userId: auth.currentUserId);
    } catch (_) {
      // Offline or the server is busy: the saved trips stay as they are.
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  /// Rides and distance from [HomeAnalytics]; riding time is the moving time,
  /// or the whole duration for trips saved without it. One pass, cheap.
  static ({int rides, double km, int ridingMs}) _totalsOf(List<TripHistoryModel> trips) {
    final a = HomeAnalytics.of(trips);
    var riding = 0;
    for (final t in trips) {
      riding += t.movingMs > 0 ? t.movingMs : t.durationMinutes * 60000;
    }
    return (rides: a.rides, km: a.totalDistanceKm, ridingMs: riding);
  }

  void _open(TripHistoryModel trip) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => trip.hasReport ? TripReportScreen(trip: trip) : TripReplayDetailScreen(trip: trip)),
    );
  }

  Future<void> _confirmDelete(TripHistoryModel trip, TripStorageService storage) async {
    final ok = await confirmAction(
      context,
      title: 'Delete trip?',
      message: '"${trip.tripName}" is removed from your history on all your devices. The other riders keep their own copy.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (ok) await storage.deleteTrip(trip.tripId);
  }

  @override
  Widget build(BuildContext context) {
    final tripStorage = context.watch<TripStorageService>();
    final trips = tripStorage.trips;

    final Widget content;
    if (trips.isEmpty) {
      content = LayoutBuilder(
        builder: (context, c) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: c.maxHeight,
              child: EmptyState(
                icon: Icons.route_rounded,
                title: 'No trips yet',
                message: 'Your rides are saved here when they end, with the route, stops and replay.',
                primaryLabel: 'Start Ride',
                onPrimary: () => RiderHomeScreen.selectTab(context, HomeTab.ride),
              ),
            ),
          ],
        ),
      );
    } else {
      final totals = _totalsOf(trips);
      content = ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(Space.s16, Space.s16, Space.s16, Space.s32),
        itemCount: trips.length + 1,
        itemBuilder: (ctx, index) {
          if (index == 0) return _TotalsHeader(rides: totals.rides, km: totals.km, ridingMs: totals.ridingMs);
          final trip = trips[index - 1];
          return Padding(
            padding: const EdgeInsets.only(bottom: Space.s8),
            child: _TripRow(
              key: ValueKey(trip.tripId),
              trip: trip,
              onTap: () => _open(trip),
              onDelete: () => _confirmDelete(trip, tripStorage),
            ),
          );
        },
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: const Text('Trips'),
        automaticallyImplyLeading: !widget.embedded,
      ),
      body: LoadingState(
        loading: _isSyncing,
        hasData: trips.isNotEmpty,
        child: RefreshIndicator(
          color: AppTheme.neonCyan,
          onRefresh: _triggerSync,
          child: content,
        ),
      ),
    );
  }
}

/// Totals over every saved trip: rides, distance, riding time.
class _TotalsHeader extends StatelessWidget {
  final int rides;
  final double km;
  final int ridingMs;
  const _TotalsHeader({required this.rides, required this.km, required this.ridingMs});

  @override
  Widget build(BuildContext context) {
    final dist = formatDistance(km * 1000);
    final cut = dist.lastIndexOf(' ');
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s16),
      child: Container(
        padding: const EdgeInsets.all(Space.s16),
        decoration: BoxDecoration(color: AppTheme.slateCard, borderRadius: Radii.mdAll, border: Border.all(color: AppTheme.subtleBorder)),
        child: Row(children: [
          Expanded(child: RideMetric(value: '$rides', label: rides == 1 ? 'Ride' : 'Rides')),
          Expanded(
            child: cut > 0
                ? RideMetric(value: dist.substring(0, cut), unit: dist.substring(cut + 1), label: 'Distance')
                : RideMetric(value: dist, label: 'Distance'),
          ),
          Expanded(child: RideMetric(value: formatDuration(Duration(milliseconds: ridingMs)), label: 'Riding time')),
        ]),
      ),
    );
  }
}

/// One trip in the list: name, date, "142 km · 3 h 10 min riding", a menu
/// with Delete, and a chevron. The same card for every trip.
class _TripRow extends StatelessWidget {
  final TripHistoryModel trip;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _TripRow({super.key, required this.trip, required this.onTap, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('EEE d MMM yyyy, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(trip.startTimeEpochMs));
    final riding = trip.movingMs > 0
        ? '${formatDuration(Duration(milliseconds: trip.movingMs))} riding'
        : formatDuration(Duration(minutes: trip.durationMinutes));
    final facts = '${formatDistance(trip.totalDistanceKm * 1000)} · $riding';
    return Material(
      color: AppTheme.slateCard,
      shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: AppTheme.subtleBorder)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.s12, Space.s8, 0, Space.s8),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: AppTheme.neonCyan.withOpacity(0.14), shape: BoxShape.circle),
                child: Icon(Icons.two_wheeler_rounded, color: AppTheme.neonCyan, size: 22),
              ),
              const SizedBox(width: Space.s12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(trip.tripName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                    Text(date, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                    const SizedBox(height: 2),
                    Text(facts, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
                    if (trip.isEstimate)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(children: [
                          Icon(Icons.hourglass_top_rounded, size: 14, color: StatusColors.warning),
                          const SizedBox(width: Space.s4),
                          Flexible(
                            child: Text('Exact report being prepared',
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: StatusColors.warning)),
                          ),
                        ]),
                      ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More options',
                icon: Icon(Icons.more_vert_rounded, color: AppTheme.textSecondary),
                onSelected: (v) {
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (_) => [
                  PopupMenuItem<String>(
                    value: 'delete',
                    child: Row(children: [
                      Icon(Icons.delete_outline_rounded, color: StatusColors.critical),
                      const SizedBox(width: Space.s12),
                      const Flexible(child: Text('Delete trip', maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ]),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: Space.s8),
                child: Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class TripReplayDetailScreen extends StatefulWidget {
  final TripHistoryModel trip;

  const TripReplayDetailScreen({super.key, required this.trip});

  /// GPX 1.1 of this trip's saved route, for other map and fitness apps.
  static String gpx(TripHistoryModel trip) {
    String esc(String v) => v.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
    final pts = trip.breadcrumbTrail
        .where((p) => p.lat != 0 || p.lng != 0)
        .map((p) => '    <trkpt lat="${p.lat.toStringAsFixed(6)}" lon="${p.lng.toStringAsFixed(6)}">'
            '${p.timestamp > 0 ? '<time>${DateTime.fromMillisecondsSinceEpoch(p.timestamp, isUtc: true).toIso8601String()}</time>' : ''}</trkpt>')
        .join('\n');
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<gpx version="1.1" creator="CoRoute" xmlns="http://www.topografix.com/GPX/1/1">\n'
        '  <metadata><name>${esc(trip.tripName)}</name></metadata>\n'
        '  <trk><name>${esc(trip.tripName)}</name><trkseg>\n$pts\n  </trkseg></trk>\n</gpx>\n';
  }

  @override
  State<TripReplayDetailScreen> createState() => _TripReplayDetailScreenState();
}

class _TripReplayDetailScreenState extends State<TripReplayDetailScreen> {
  // A new map is built when a trail arrives (see the map key), so it gets a new controller too.
  MapController _map = MapController();
  late TripHistoryModel trip;
  bool _loading = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    trip = widget.trip;
    if (trip.trailOnServerOnly) {
      final cached = context.read<TripStorageService>().cachedFull(trip.tripId);
      if (cached != null) {
        trip = cached;
      } else if (!_waitForTap()) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _loadRoute());
      }
    }
  }

  /// In data saver mode the route is downloaded only when the rider asks for it.
  bool _waitForTap() {
    try {
      return context.read<SettingsService>().lowData;
    } on ProviderNotFoundException catch (_) {
      return false;
    }
  }

  Future<void> _loadRoute() async {
    if (_loading || !mounted) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final full = await context.read<TripStorageService>().loadFull(trip.tripId);
      if (!mounted) return;
      setState(() {
        trip = full;
        _map = MapController();
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e.isOffline ? 'Route not available offline.' : 'Could not load the route. Try again later.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Could not load the route. Try again later.';
      });
    }
  }

  Future<void> _share(BuildContext context) async {
    final safe = trip.tripName.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim().replaceAll(RegExp(r'\s+'), '_');
    try {
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(utf8.encode(TripReplayDetailScreen.gpx(trip)), mimeType: 'application/gpx+xml', name: '${safe.isEmpty ? 'coroute_trip' : safe}.gpx')],
        subject: 'CoRoute trip: ${trip.tripName}',
      ));
    } catch (_) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not share the route.')));
    }
  }

  /// Shown over the map while the route is missing on this phone.
  Widget? _routeNotice() {
    if (!trip.trailOnServerOnly) return null;
    final Widget child;
    if (_loading) {
      child = Row(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(width: 20, height: 20, child: LoadingSpinner()),
        const SizedBox(width: Space.s12),
        Flexible(child: Text('Loading the route...', style: AppText.body)),
      ]);
    } else if (_loadError != null) {
      child = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_loadError!, textAlign: TextAlign.center, style: AppText.body),
        const SizedBox(height: Space.s8),
        OutlinedButton(onPressed: _loadRoute, child: const Text('Try again')),
      ]);
    } else {
      child = FilledButton.icon(onPressed: _loadRoute, icon: const Icon(Icons.download_rounded), label: const Text('Load route'));
    }
    return Center(
      child: Container(
        margin: const EdgeInsets.all(Space.s24),
        padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s12),
        decoration: BoxDecoration(color: AppTheme.slateCard, borderRadius: Radii.mdAll, border: Border.all(color: AppTheme.subtleBorder)),
        child: child,
      ),
    );
  }

  void _showWhole(LatLngBounds? bounds, LatLng center) {
    try {
      if (bounds != null) {
        _map.fitCamera(CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(40)));
      } else {
        _map.move(center, _map.camera.zoom);
      }
    } catch (_) {
      // The map is not laid out yet.
    }
  }

  @override
  Widget build(BuildContext context) {
    final points = trip.breadcrumbTrail.where((p) => p.lat != 0 || p.lng != 0).map((p) => LatLng(p.lat, p.lng)).toList();
    final bounds = points.length >= 2 ? LatLngBounds.fromPoints(points) : null;
    final center = points.isNotEmpty ? points.first : const LatLng(AppConstants.defaultMapLat, AppConstants.defaultMapLng);

    final details = Container(
      padding: const EdgeInsets.all(Space.s16),
      decoration: BoxDecoration(color: AppTheme.slateCard, borderRadius: Radii.sheetTop),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(trip.tripName, style: AppText.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (trip.startLocationName.isNotEmpty || trip.destinationName.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Space.s4),
                child: Text(
                  '${trip.startLocationName.isEmpty ? 'Start' : trip.startLocationName} to ${trip.destinationName.isEmpty ? 'destination' : trip.destinationName}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(color: AppTheme.textSecondary),
                ),
              ),
            const SizedBox(height: Space.s16),
            RouteSummary(
              distanceKm: trip.totalDistanceKm,
              duration: Duration(minutes: trip.durationMinutes),
              stops: trip.stopCount,
              riders: trip.riderCount,
            ),
            if (trip.topSpeedKmh > 0)
              Padding(
                padding: const EdgeInsets.only(top: Space.s12),
                child: Text('Top speed ${trip.topSpeedKmh.round()} km/h', style: AppText.label),
              ),
            const SizedBox(height: Space.s16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: points.isEmpty ? null : () => _share(context),
                icon: const Icon(Icons.share_rounded),
                label: const Text('Share the route (GPX)', maxLines: 1, overflow: TextOverflow.ellipsis),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              ),
            ),
          ],
        ),
      ),
    );

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(title: Text(trip.tripName, overflow: TextOverflow.ellipsis)),
      body: LayoutBuilder(builder: (context, c) {
        final map = FlutterMap(
          // A new map (and camera fit) once a trail loaded on demand arrives.
          key: ValueKey('trail-${points.length}'),
          mapController: _map,
          options: MapOptions(
            initialCenter: center,
            initialZoom: points.isEmpty ? 5 : 13.0,
            initialCameraFit: bounds == null ? null : CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(40)),
          ),
          children: [
            appTileLayer(),
            if (points.length >= 2)
              PolylineLayer(polylines: [Polyline(points: points, strokeWidth: 5.0, color: AppTheme.neonCyan)]),
            if (points.isNotEmpty)
              MarkerLayer(
                markers: [
                  Marker(
                    point: points.first,
                    width: 32,
                    height: 32,
                    alignment: Alignment.topCenter,
                    child: Semantics(label: 'Start', child: Icon(Icons.location_on_rounded, color: StatusColors.success, size: 30)),
                  ),
                  Marker(
                    point: points.last,
                    width: 32,
                    height: 32,
                    alignment: Alignment.topCenter,
                    child: Semantics(label: 'Finish', child: Icon(Icons.flag_rounded, color: StatusColors.critical, size: 28)),
                  ),
                ],
              ),
          ],
        );
        final notice = _routeNotice();
        final mapArea = Stack(children: [
          Positioned.fill(child: map),
          if (notice != null) Positioned.fill(child: notice),
          Positioned(
            top: Space.s8,
            right: Space.s8,
            child: MapControl(
              icon: Icons.zoom_out_map_rounded,
              tooltip: 'Show the whole route',
              onPressed: points.isEmpty ? null : () => _showWhole(bounds, center),
            ),
          ),
        ]);
        if (c.maxWidth > c.maxHeight && c.maxWidth > 700) {
          return Row(children: [Expanded(child: mapArea), SizedBox(width: 360, child: SingleChildScrollView(child: details))]);
        }
        return Column(children: [
          Expanded(child: mapArea),
          ConstrainedBox(constraints: BoxConstraints(maxHeight: c.maxHeight * 0.5), child: SingleChildScrollView(child: details)),
        ]);
      }),
    );
  }
}
