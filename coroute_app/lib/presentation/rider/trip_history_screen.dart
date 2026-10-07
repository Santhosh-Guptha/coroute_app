import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/settings_service.dart';
import '../../data/services/trip_storage_service.dart';
import '../../data/services/auth_service.dart';
import '../../domain/timeline/timeline_text.dart';
import '../report/trip_report_screen.dart';
import '../../core/theme/map_tiles.dart';

class TripHistoryScreen extends StatefulWidget {
  const TripHistoryScreen({super.key});

  @override
  State<TripHistoryScreen> createState() => _TripHistoryScreenState();
}

class _TripHistoryScreenState extends State<TripHistoryScreen> {
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _triggerSync();
    });
  }

  Future<void> _triggerSync() async {
    if (!mounted) return;
    setState(() => _isSyncing = true);
    final auth = context.read<AuthService>();
    final tripStorage = context.read<TripStorageService>();
    final count = await tripStorage.syncWithCloud(userId: auth.currentUserId);
    if (mounted) {
      setState(() => _isSyncing = false);
      if (count > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Synchronized $count new journeys from Cloud!'),
            backgroundColor: AppTheme.emeraldSafe,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tripStorage = context.watch<TripStorageService>();
    final trips = tripStorage.trips;

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: const Text('Trip History & Replay'),
        actions: [
          if (_isSyncing)
            Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.neonCyan),
              ),
            )
          else
            IconButton(
              tooltip: 'Sync with cloud',
              icon: Icon(Icons.cloud_sync, color: AppTheme.neonCyan),
              onPressed: _triggerSync,
            ),
        ],
      ),
      body: trips.isEmpty
          ? Center(
              child: Text(
                'No recorded trips yet.\nStart a ride to automatically capture full telemetry.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textMuted),
              ),
            )
          : RefreshIndicator(
              color: AppTheme.neonCyan,
              onRefresh: _triggerSync,
              child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              itemCount: trips.length,
              itemBuilder: (ctx, index) {
                final trip = trips[index];
                final dateStr = DateFormat('dd MMM yyyy, hh:mm a').format(
                  DateTime.fromMillisecondsSinceEpoch(trip.startTimeEpochMs),
                );

                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: GlassCard(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => trip.hasReport ? TripReportScreen(trip: trip) : TripReplayDetailScreen(trip: trip),
                        ),
                      );
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: AppTheme.neonCyan.withOpacity(0.15),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.two_wheeler, color: AppTheme.neonCyan, size: 20),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    trip.tripName,
                                    style: TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                  ),
                                  Text(
                                    dateStr,
                                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Delete this trip',
                              icon: Icon(Icons.delete_outline, color: AppTheme.textMuted, size: 20),
                              onPressed: () => _confirmDelete(trip, tripStorage),
                            ),
                          ],
                        ),
                        if (trip.startLocationName.isNotEmpty || trip.destinationName.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            '${trip.startLocationName.isEmpty ? 'Start' : trip.startLocationName}  to  ${trip.destinationName.isEmpty ? 'destination' : trip.destinationName}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                          ),
                        ],
                        const SizedBox(height: 14),
                        if (trip.isEstimate)
                          Text(
                            'The exact report (distance, every rider\'s route and waits) is being prepared from the recorded routes. Pull to refresh in a minute.',
                            style: TextStyle(color: AppTheme.hyperAmber, fontSize: 12),
                          )
                        else
                          Wrap(
                            alignment: WrapAlignment.spaceAround,
                            spacing: 18,
                            runSpacing: 10,
                            children: [
                              _buildTripStat('Distance', TimelineText.distance(trip.totalDistanceKm * 1000), AppTheme.neonCyan),
                              if (trip.movingMs > 0)
                                _buildTripStat('Riding', TimelineText.duration(Duration(milliseconds: trip.movingMs)), AppTheme.emeraldSafe)
                              else
                                _buildTripStat('Duration', TimelineText.duration(Duration(minutes: trip.durationMinutes)), AppTheme.hyperAmber),
                              if (trip.movingMs > 0) _buildTripStat('Stopped', '${TimelineText.duration(Duration(milliseconds: trip.restMs))}, ${trip.stopCount}x', AppTheme.hyperAmber),
                              _buildTripStat('Top speed', '${trip.topSpeedKmh.toStringAsFixed(0)} km/h', AppTheme.speedWarning),
                              if (trip.riderCount > 1) _buildTripStat('Riders', '${trip.riderCount}', AppTheme.textSecondary),
                            ],
                          ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Flexible(
                              child: Text(
                                trip.hasReport ? 'Report, map of every rider and replay' : 'View the route',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: AppTheme.neonCyan, fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                            ),
                            Icon(Icons.chevron_right, color: AppTheme.neonCyan, size: 16),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            ),
    );
  }

  Future<void> _confirmDelete(TripHistoryModel trip, TripStorageService storage) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.slateCard,
        title: Text('Delete this trip?', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          '"${trip.tripName}" is removed from your history on all your devices. The other riders keep their own copy.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: AppTheme.textMuted))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Delete', style: TextStyle(color: AppTheme.laserRed))),
        ],
      ),
    );
    if (ok == true) await storage.deleteTrip(trip.tripId);
  }

  Widget _buildTripStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(label, style: TextStyle(color: AppTheme.textMuted, fontSize: 10)),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold),
        ),
      ],
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
        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.neonCyan)),
        const SizedBox(width: 10),
        Text('Loading the route...', style: TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
      ]);
    } else if (_loadError != null) {
      child = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_loadError!, textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
        TextButton(onPressed: _loadRoute, child: Text('Try again', style: TextStyle(color: AppTheme.neonCyan))),
      ]);
    } else {
      child = ElevatedButton.icon(onPressed: _loadRoute, icon: const Icon(Icons.download_rounded), label: const Text('Load route'));
    }
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(color: AppTheme.slateCard.withOpacity(0.95), borderRadius: BorderRadius.circular(12)),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final points = trip.breadcrumbTrail.where((p) => p.lat != 0 || p.lng != 0).map((p) => LatLng(p.lat, p.lng)).toList();
    final bounds = points.length >= 2 ? LatLngBounds.fromPoints(points) : null;
    final center = points.isNotEmpty ? points.first : const LatLng(AppConstants.defaultMapLat, AppConstants.defaultMapLng);

    final details = Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.slateCard,
        borderRadius: const BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              trip.tripName,
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text('${trip.startLocationName} to ${trip.destinationName}', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            const SizedBox(height: 18),
            Wrap(
              alignment: WrapAlignment.spaceAround,
              spacing: 24,
              runSpacing: 12,
              children: [
                _buildSummaryItem(Icons.straighten, 'Total distance', TimelineText.distance(trip.totalDistanceKm * 1000)),
                _buildSummaryItem(Icons.speed, 'Top speed', '${trip.topSpeedKmh.toStringAsFixed(0)} km/h'),
                _buildSummaryItem(Icons.timer, 'Duration', TimelineText.duration(Duration(minutes: trip.durationMinutes))),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: points.isEmpty ? null : () => _share(context),
                icon: const Icon(Icons.share),
                label: const Text('Share the route (GPX)'),
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
          options: MapOptions(
            initialCenter: center,
            initialZoom: points.isEmpty ? 5 : 13.0,
            initialCameraFit: bounds == null ? null : CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(40)),
          ),
          children: [
            TileLayer(
              tileBuilder: mapTileBuilder,
              urlTemplate: AppConstants.osmTileUrl,
              userAgentPackageName: AppConstants.osmUserAgent,
            ),
            if (points.length >= 2)
              PolylineLayer(polylines: [Polyline(points: points, strokeWidth: 5.0, color: AppTheme.neonCyan)]),
            if (points.isNotEmpty)
              MarkerLayer(
                markers: [
                  Marker(point: points.first, width: 32, height: 32, alignment: Alignment.topCenter, child: Icon(Icons.location_on, color: AppTheme.emeraldSafe, size: 30)),
                  Marker(point: points.last, width: 32, height: 32, alignment: Alignment.topCenter, child: Icon(Icons.flag, color: AppTheme.hyperAmber, size: 28)),
                ],
              ),
          ],
        );
        final notice = _routeNotice();
        final mapArea = notice == null ? map : Stack(children: [map, notice]);
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

  Widget _buildSummaryItem(IconData icon, String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: AppTheme.neonCyan, size: 22),
        const SizedBox(height: 6),
        Text(value, style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.bold)),
        Text(label, style: TextStyle(color: AppTheme.textMuted, fontSize: 10)),
      ],
    );
  }
}
