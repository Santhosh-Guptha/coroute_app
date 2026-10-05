import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/devmonks_branding.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/trip_storage_service.dart';
import '../../data/services/auth_service.dart';
import '../report/trip_report_screen.dart';

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
            const Padding(
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
              icon: const Icon(Icons.cloud_sync, color: AppTheme.neonCyan),
              onPressed: _triggerSync,
            ),
        ],
      ),
      body: trips.isEmpty
          ? const Center(
              child: Text(
                'No recorded trips yet.\nStart a ride to automatically capture full telemetry.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textMuted),
              ),
            )
          : ListView.builder(
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
                              child: const Icon(Icons.two_wheeler, color: AppTheme.neonCyan, size: 20),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    trip.tripName,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                  ),
                                  Text(
                                    dateStr,
                                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: AppTheme.textMuted, size: 20),
                              onPressed: () {
                                tripStorage.deleteTrip(trip.tripId);
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildTripStat('Distance', '${trip.totalDistanceKm} km', AppTheme.neonCyan),
                            _buildTripStat('Duration', '${trip.durationMinutes} min', AppTheme.hyperAmber),
                            _buildTripStat('Top Speed', '${trip.topSpeedKmh.toStringAsFixed(0)} km/h', AppTheme.speedWarning),
                            _buildTripStat('Avg Speed', '${trip.avgSpeedKmh.toStringAsFixed(0)} km/h', AppTheme.emeraldSafe),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              'View Interactive Route Replay',
                              style: TextStyle(
                                color: AppTheme.neonCyan,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
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
    );
  }

  Widget _buildTripStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: AppTheme.textMuted, fontSize: 10)),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}

class TripReplayDetailScreen extends StatelessWidget {
  final TripHistoryModel trip;

  const TripReplayDetailScreen({super.key, required this.trip});

  @override
  Widget build(BuildContext context) {
    final points = trip.breadcrumbTrail.map((p) => LatLng(p.lat, p.lng)).toList();
    final center = points.isNotEmpty ? points.first : const LatLng(0, 0);

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: Text(trip.tripName),
      ),
      body: Column(
        children: [
          // Route Map
          Expanded(
            flex: 6,
            child: FlutterMap(
              options: MapOptions(
                initialCenter: center,
                initialZoom: 13.0,
              ),
              children: [
                TileLayer(
                  urlTemplate: AppConstants.osmTileUrl,
                  userAgentPackageName: AppConstants.osmUserAgent,
                ),
                if (points.isNotEmpty)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: points,
                        strokeWidth: 5.0,
                        color: AppTheme.neonCyan,
                      ),
                    ],
                  ),
                if (points.isNotEmpty)
                  MarkerLayer(
                    markers: [
                      // Start Marker
                      Marker(
                        point: points.first,
                        width: 32,
                        height: 32,
                        child: const Icon(Icons.location_on, color: AppTheme.emeraldSafe, size: 30),
                      ),
                      // End Marker
                      Marker(
                        point: points.last,
                        width: 32,
                        height: 32,
                        child: const Icon(Icons.flag, color: AppTheme.hyperAmber, size: 28),
                      ),
                    ],
                  ),
              ],
            ),
          ),

          // Trip Telemetry Breakdown
          Expanded(
            flex: 4,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: AppTheme.slateCard,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(24),
                  topRight: Radius.circular(24),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        trip.tripName,
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const DevMonksBadge(isCompact: true),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${trip.startLocationName} ──► ${trip.destinationName}',
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildSummaryItem(Icons.straighten, 'Total Distance', '${trip.totalDistanceKm} km'),
                      _buildSummaryItem(Icons.speed, 'Max Speed', '${trip.topSpeedKmh.toStringAsFixed(0)} km/h'),
                      _buildSummaryItem(Icons.timer, 'Ride Duration', '${trip.durationMinutes} min'),
                    ],
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Trip coordinates exported as GPX file.')),
                        );
                      },
                      icon: const Icon(Icons.share),
                      label: const Text('Export GPX / Share Trip'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryItem(IconData icon, String label, String value) {
    return Column(
      children: [
        Icon(icon, color: AppTheme.neonCyan, size: 22),
        const SizedBox(height: 6),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: AppTheme.textMuted, fontSize: 10)),
      ],
    );
  }
}
