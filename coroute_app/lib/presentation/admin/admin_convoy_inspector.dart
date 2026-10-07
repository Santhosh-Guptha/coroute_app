import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/telemetry_utils.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/models/convoy_model.dart';
import '../../data/services/convoy_service.dart';
import '../../core/theme/map_tiles.dart';
import '../timeline/live_timeline_screen.dart';
import '../report/replay_screen.dart';

class AdminConvoyInspector extends StatelessWidget {
  final ConvoyModel convoy;

  const AdminConvoyInspector({super.key, required this.convoy});

  Future<void> _confirmDissolveConvoy(BuildContext context, ConvoyService convoyService) async {
    final ok = await confirmAction(
      context,
      title: 'End this ride for everyone?',
      message: 'This ends "${convoy.name}" (code ${convoy.joinCode}) for all riders. Their live location sharing stops.',
      confirmLabel: 'End ride',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    convoyService.adminDissolveConvoy(convoy.groupId);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context); // close the inspector
    messenger.showSnackBar(SnackBar(content: Text('Ride ${convoy.name} ended.')));
  }

  @override
  Widget build(BuildContext context) {
    final convoyService = context.watch<ConvoyService>();
    final currentConvoy = convoyService.allConvoys[convoy.groupId] ?? convoy;
    final riders = currentConvoy.riders.values.toList();
    final metrics = TelemetryUtils.calculateConvoyMetrics(riders);

    final centerLat = riders.isNotEmpty ? riders.first.lat : (currentConvoy.destinationLat != 0.0 ? currentConvoy.destinationLat : 0.0);
    final centerLng = riders.isNotEmpty ? riders.first.lng : (currentConvoy.destinationLng != 0.0 ? currentConvoy.destinationLng : 0.0);

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: Text(currentConvoy.name),
        actions: [
          IconButton(
            tooltip: 'Live Timeline',
            icon: Icon(Icons.timeline_rounded, color: AppTheme.neonCyan),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => LiveTimelineScreen(groupId: currentConvoy.groupId)),
            ),
          ),
          IconButton(
            tooltip: 'Replay & Routes',
            icon: Icon(Icons.slow_motion_video_rounded, color: AppTheme.emeraldSafe),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ReplayScreen(groupId: currentConvoy.groupId, title: '${currentConvoy.name}: Replay')),
            ),
          ),
          IconButton(
            tooltip: 'Dissolve Convoy',
            icon: Icon(Icons.delete_forever, color: AppTheme.laserRed),
            onPressed: () => _confirmDissolveConvoy(context, convoyService),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Convoy Metric Banner
            GlassCard(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildMetricPill('Spread', '${metrics.spreadKm.toStringAsFixed(1)} km', AppTheme.neonCyan),
                  _buildMetricPill('Avg Speed', '${metrics.averageSpeedKmh.toStringAsFixed(0)} km/h', AppTheme.hyperAmber),
                  _buildMetricPill('Status', metrics.status, Color(metrics.statusColor)),
                  _buildMetricPill('Riders', '${riders.length}', AppTheme.emeraldSafe),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Live Inspector Map
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                height: 280,
                decoration: BoxDecoration(
                  border: Border.all(color: AppTheme.subtleBorder),
                ),
                child: FlutterMap(
                  options: MapOptions(
                    initialCenter: LatLng(centerLat, centerLng),
                    initialZoom: 14.5,
                  ),
                  children: [
                    TileLayer(
                      tileBuilder: mapTileBuilder,
                      urlTemplate: AppConstants.osmTileUrl,
                      userAgentPackageName: AppConstants.osmUserAgent,
                    ),
                    MarkerLayer(
                      markers: riders.map((r) {
                        return Marker(
                          point: LatLng(r.lat, r.lng),
                          width: 44,
                          height: 44,
                          child: Column(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.slateCard.withOpacity(0.9),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  r.name,
                                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Transform.rotate(
                                angle: r.heading * (3.14159 / 180.0),
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: r.role == 'LEAD' ? AppTheme.hyperAmber : AppTheme.neonCyan,
                                    border: Border.all(color: Colors.black, width: 2),
                                  ),
                                  child: const Icon(
                                    Icons.navigation,
                                    size: 14,
                                    color: Colors.black,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            // Riders List
            Text(
              'Roster & Telemetry Breakdown',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),

            ...riders.map((r) {
              final cardinal = TelemetryUtils.getCardinalDirection(r.heading);
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GlassCard(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: r.role == 'LEAD' ? AppTheme.hyperAmber.withOpacity(0.2) : AppTheme.neonCyan.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.two_wheeler,
                          color: r.role == 'LEAD' ? AppTheme.hyperAmber : AppTheme.neonCyan,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(child: Text(
                                  r.name,
                                  style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis)),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: r.role == 'LEAD' ? AppTheme.hyperAmber : AppTheme.slateCard,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    r.role,
                                    style: TextStyle(
                                      color: r.role == 'LEAD' ? Colors.black : AppTheme.textSecondary,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${r.vehicleType} · ${r.vehicleColor}',
                              style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${r.speedKmh.toStringAsFixed(0)} km/h',
                            style: TextStyle(color: AppTheme.neonCyan, fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            'Heading ${r.heading.round()}° $cardinal',
                            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricPill(String title, String value, Color color) {
    return Column(
      children: [
        Text(title, style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13),
        ),
      ],
    );
  }
}
