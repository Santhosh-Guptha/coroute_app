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
    String? subtitle;
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
      subtitle = '${formatDistance(totals.km * 1000)} · ${totals.rides} ${totals.rides == 1 ? 'ride' : 'rides'}';
      content = ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        itemCount: trips.length + 1,
        itemBuilder: (ctx, index) {
          if (index == 0) return _TotalsHeader(rides: totals.rides, km: totals.km, ridingMs: totals.ridingMs);
          final trip = trips[index - 1];
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
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
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: DsScreenHeader(
                title: 'Trips',
                subtitle: subtitle ?? 'Every ride you finish is saved here',
                onBack: widget.embedded ? null : () => Navigator.maybePop(context),
                trailing: _NewRideButton(onTap: () => RiderHomeScreen.selectTab(context, HomeTab.ride)),
              ),
            ),
            Expanded(
              child: LoadingState(
                loading: _isSyncing,
                hasData: trips.isNotEmpty,
                child: RefreshIndicator(
                  color: AppTheme.accentText,
                  onRefresh: _triggerSync,
                  child: content,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Round solid-teal "+" in the header (canvas: plan a new trip). Here it
/// opens the Ride tab, where a ride is started.
class _NewRideButton extends StatelessWidget {
  final VoidCallback onTap;
  const _NewRideButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return DsRoundButton(
      icon: Icons.add_rounded,
      label: 'Start a ride',
      onTap: onTap,
      size: 48,
      background: AppTheme.brand,
      borderColor: AppTheme.brand,
      iconColor: Colors.white,
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
      padding: const EdgeInsets.only(bottom: 16),
      child: DsCard(
        padding: const EdgeInsets.all(16),
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

/// One trip in the list: a small route glyph, name, date, "142 km · 3 h 10 min
/// riding", and a menu with Delete. The same card for every trip.
class _TripRow extends StatelessWidget {
  final TripHistoryModel trip;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _TripRow({super.key, required this.trip, required this.onTap, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('EEE d MMM yyyy, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(trip.startTimeEpochMs));
    final riders = trip.riderCount > 1 ? '${trip.riderCount} riders' : 'solo';
    final riding = trip.movingMs > 0
        ? '${formatDuration(Duration(milliseconds: trip.movingMs))} riding'
        : formatDuration(Duration(minutes: trip.durationMinutes));
    final facts = '${formatDistance(trip.totalDistanceKm * 1000)} · $riding';
    return DsCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      onTap: onTap,
      child: Row(children: [
        _RouteGlyph(trip: trip),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(trip.tripName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 15)),
              const SizedBox(height: 2),
              Text('$date · $riders', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
              const SizedBox(height: 2),
              Text(facts, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
              if (trip.isEstimate)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(children: [
                    Icon(Icons.hourglass_top_rounded, size: 14, color: AppTheme.warnText),
                    const SizedBox(width: Space.s4),
                    Flexible(
                      child: Text('Exact report being prepared',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.warnText, fontWeight: FontWeight.w700)),
                    ),
                  ]),
                ),
            ],
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'More options',
          icon: Icon(Icons.more_vert_rounded, color: AppTheme.muted),
          onSelected: (v) {
            if (v == 'delete') onDelete();
          },
          itemBuilder: (_) => [
            PopupMenuItem<String>(
              value: 'delete',
              child: Row(children: [
                Icon(Icons.delete_outline_rounded, color: AppTheme.sos),
                const SizedBox(width: Space.s12),
                const Flexible(child: Text('Delete trip', maxLines: 1, overflow: TextOverflow.ellipsis)),
              ]),
            ),
          ],
        ),
      ]),
    );
  }
}

/// The trip's route as a small teal line (canvas: the sparkline in each past
/// trip row). Drawn from the saved trail; a plain curve when the trail is
/// still on the server.
class _RouteGlyph extends StatelessWidget {
  final TripHistoryModel trip;
  const _RouteGlyph({required this.trip});

  @override
  Widget build(BuildContext context) {
    final pts = trip.breadcrumbTrail.where((p) => p.lat != 0 || p.lng != 0).toList();
    return ExcludeSemantics(
      child: SizedBox(
        width: 56,
        height: 40,
        child: CustomPaint(painter: _RouteGlyphPainter(points: pts, color: AppTheme.brand, seed: trip.tripId.hashCode)),
      ),
    );
  }
}

class _RouteGlyphPainter extends CustomPainter {
  final List<TripBreadcrumbPoint> points;
  final Color color;
  final int seed;
  _RouteGlyphPainter({required this.points, required this.color, required this.seed});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    if (points.length >= 2) {
      double minLat = points.first.lat, maxLat = points.first.lat, minLng = points.first.lng, maxLng = points.first.lng;
      for (final p in points) {
        if (p.lat < minLat) minLat = p.lat;
        if (p.lat > maxLat) maxLat = p.lat;
        if (p.lng < minLng) minLng = p.lng;
        if (p.lng > maxLng) maxLng = p.lng;
      }
      final spanLat = (maxLat - minLat).abs() < 1e-9 ? 1e-9 : maxLat - minLat;
      final spanLng = (maxLng - minLng).abs() < 1e-9 ? 1e-9 : maxLng - minLng;
      const inset = 3.0;
      final w = size.width - inset * 2, h = size.height - inset * 2;
      // At most ~24 samples so the glyph stays smooth and cheap.
      final step = (points.length / 24).ceil().clamp(1, points.length);
      var first = true;
      for (var i = 0; i < points.length; i += step) {
        final p = points[i];
        final x = inset + (p.lng - minLng) / spanLng * w;
        final y = inset + h - (p.lat - minLat) / spanLat * h;
        if (first) {
          path.moveTo(x, y);
          first = false;
        } else {
          path.lineTo(x, y);
        }
      }
      final last = points.last;
      path.lineTo(inset + (last.lng - minLng) / spanLng * w, inset + h - (last.lat - minLat) / spanLat * h);
    } else {
      // No trail on this phone: a gentle rising curve, varied a little per trip.
      final k = (seed % 5) * 0.08;
      final w = size.width, h = size.height;
      path.moveTo(4, h - 6);
      path.cubicTo(w * (0.3 + k), h * 0.75, w * 0.4, h * (0.3 + k), w * 0.58, h * 0.3);
      path.cubicTo(w * 0.75, h * (0.15 + k), w * 0.85, h * 0.25, w - 4, 4 + h * k);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_RouteGlyphPainter old) => old.points != points || old.color != color || old.seed != seed;
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
        const SizedBox(height: Space.s12),
        DsButton(label: 'Try again', tone: DsButtonTone.outline, height: 48, fontSize: 15, onPressed: _loadRoute),
      ]);
    } else {
      child = DsButton(label: 'Load route', icon: Icons.download_rounded, height: 48, fontSize: 15, onPressed: _loadRoute);
    }
    return Center(
      child: Container(
        margin: const EdgeInsets.all(Space.s24),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: Radii.lgAll,
          border: Border.all(color: AppTheme.border, width: 2),
          boxShadow: dsFloatingShadow(),
        ),
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
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: Radii.sheetTop,
        border: Border(top: BorderSide(color: AppTheme.border, width: 2)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 5,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(color: AppTheme.border2, borderRadius: BorderRadius.circular(3)),
              ),
            ),
            Text(trip.tripName, style: AppText.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (trip.startLocationName.isNotEmpty || trip.destinationName.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Space.s4),
                child: Text(
                  '${trip.startLocationName.isEmpty ? 'Start' : trip.startLocationName} to ${trip.destinationName.isEmpty ? 'destination' : trip.destinationName}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.label,
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
            DsButton(
              label: 'Share the route (GPX)',
              icon: Icons.share_rounded,
              onPressed: points.isEmpty ? null : () => _share(context),
            ),
          ],
        ),
      ),
    );

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        title: Text(trip.tripName, overflow: TextOverflow.ellipsis),
      ),
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
              PolylineLayer(polylines: [Polyline(points: points, strokeWidth: 5.0, color: AppTheme.brand)]),
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
                    child: Semantics(label: 'Finish', child: Icon(Icons.flag_rounded, color: AppTheme.sos, size: 28)),
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
