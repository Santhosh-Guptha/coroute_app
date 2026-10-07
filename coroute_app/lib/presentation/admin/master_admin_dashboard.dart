import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../auth/access_gate_screen.dart';
import 'admin_convoy_inspector.dart';
import 'admin_insights_screen.dart';
import 'admin_ride_history_screen.dart';
import 'admin_users_screen.dart';
import '../../core/theme/map_tiles.dart';

class MasterAdminDashboard extends StatefulWidget {
  const MasterAdminDashboard({super.key});

  @override
  State<MasterAdminDashboard> createState() => _MasterAdminDashboardState();
}

class _MasterAdminDashboardState extends State<MasterAdminDashboard> {
  final _broadcastController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Live fleet overview is pushed by the gateway (read-only, no audio).
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<ConvoyService>().startAdminFleetWatch());
  }

  LatLng _computeFleetCenter(List<dynamic> convoys) {
    double totalLat = 0;
    double totalLng = 0;
    int count = 0;
    for (final c in convoys) {
      for (final r in c.riders.values) {
        if (r.lat != 0.0 || r.lng != 0.0) {
          totalLat += r.lat;
          totalLng += r.lng;
          count++;
        }
      }
    }
    if (count == 0) return const LatLng(AppConstants.defaultMapLat, AppConstants.defaultMapLng); // India center as neutral default
    return LatLng(totalLat / count, totalLng / count);
  }

  @override
  void dispose() {
    _broadcastController.dispose();
    super.dispose();
  }

  void _showBroadcastDialog(BuildContext context, ConvoyService convoyService) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppTheme.slateCard,
          title: Row(
            children: [
              Icon(Icons.campaign, color: AppTheme.hyperAmber),
              SizedBox(width: 8),
              Flexible(child: Text('Global Safety Broadcast', style: TextStyle(color: AppTheme.textPrimary, fontSize: 18))),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This alert will be broadcasted to all active convoys immediately on their map HUD.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _broadcastController,
                maxLines: 2,
                style: TextStyle(color: AppTheme.textPrimary),
                decoration: const InputDecoration(
                  hintText: 'e.g. Heavy rain alert on NH-48. Reduce speed and regroup.',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.hyperAmber),
              onPressed: () {
                final msg = _broadcastController.text.trim();
                if (msg.isNotEmpty) {
                  convoyService.adminBroadcastSafetyAlert(msg);
                  _broadcastController.clear();
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Safety alert broadcasted across all convoys!')),
                  );
                }
              },
              child: const Text('Send to Fleet', style: TextStyle(color: Colors.black)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final convoyService = context.watch<ConvoyService>();
    final convoys = convoyService.allConvoys.values.toList();

    int totalRiders = 0;
    int totalAlerts = 0;
    for (final c in convoys) {
      totalRiders += c.riders.length;
      totalAlerts += c.activeAlerts.length;
    }

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.infoBlue,
              ),
              child: const Icon(Icons.shield, color: Colors.white, size: 16),
            ),
            const SizedBox(width: 8),
            Flexible(child: const Text(
              'Master Admin Console',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Safety Broadcast',
            icon: Icon(Icons.campaign, color: AppTheme.hyperAmber),
            onPressed: () => _showBroadcastDialog(context, convoyService),
          ),
          IconButton(
            tooltip: 'Groups & Retention',
            icon: Icon(Icons.history_rounded, color: AppTheme.emeraldSafe),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminRideHistoryScreen())),
          ),
          IconButton(
            tooltip: 'Feedback & analytics',
            icon: Icon(Icons.insights_rounded, color: AppTheme.neonCyan),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminInsightsScreen())),
          ),
          IconButton(
            tooltip: 'Registered Users',
            icon: Icon(Icons.people_alt_rounded, color: AppTheme.infoBlue),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminUsersScreen())),
          ),
          IconButton(
            tooltip: 'Logout',
            icon: Icon(Icons.logout, color: AppTheme.textMuted),
            onPressed: () async {
              await auth.logout();
              if (context.mounted) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => const AccessGateScreen()),
                );
              }
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Management Hub
            Row(
              children: [
                Expanded(
                  child: GlassCard(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminRideHistoryScreen())),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppTheme.emeraldSafe.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.history_rounded, color: AppTheme.emeraldSafe, size: 20),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Groups & Retention',
                                style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Active rides & policy',
                                style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted, size: 18),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GlassCard(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminUsersScreen())),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppTheme.neonCyan.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.people_alt_rounded, color: AppTheme.neonCyan, size: 20),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Registered Users',
                                style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Hold, block & trips',
                                style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted, size: 18),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

            // KPI Grid
            Row(
              children: [
                _buildKpiCard(
                  title: 'Active Convoys',
                  value: convoys.length.toString(),
                  icon: Icons.groups_rounded,
                  accentColor: AppTheme.neonCyan,
                ),
                const SizedBox(width: 10),
                _buildKpiCard(
                  title: 'Riders Online',
                  value: totalRiders.toString(),
                  icon: Icons.two_wheeler,
                  accentColor: AppTheme.emeraldSafe,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _buildKpiCard(
                  title: 'Emergency SOS',
                  value: totalAlerts.toString(),
                  icon: Icons.warning_amber_rounded,
                  accentColor: totalAlerts > 0 ? AppTheme.laserRed : AppTheme.textMuted,
                ),
                const SizedBox(width: 10),
                _buildKpiCard(
                  title: 'Fleet Status',
                  value: totalAlerts > 0 ? 'Alerts Active' : (totalRiders > 0 ? 'All Clear' : 'No Riders'),
                  icon: Icons.check_circle_outline,
                  accentColor: totalAlerts > 0 ? AppTheme.laserRed : (totalRiders > 0 ? AppTheme.emeraldSafe : AppTheme.textMuted),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // Fleet Radar Map
            Text(
              'Global Fleet Radar',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                height: 220,
                decoration: BoxDecoration(
                  border: Border.all(color: AppTheme.subtleBorder),
                ),
                child: FlutterMap(
                  options: MapOptions(
                    initialCenter: _computeFleetCenter(convoys),
                    initialZoom: totalRiders > 0 ? 10.0 : 3.0,
                  ),
                  children: [
                    TileLayer(
                      tileBuilder: mapTileBuilder,
                      urlTemplate: AppConstants.osmTileUrl,
                      userAgentPackageName: AppConstants.osmUserAgent,
                    ),
                    MarkerLayer(
                      markers: convoys.expand((c) {
                        return c.riders.values.map((r) {
                          return Marker(
                            point: LatLng(r.lat, r.lng),
                            width: 36,
                            height: 36,
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: r.role == 'LEAD' ? AppTheme.hyperAmber : AppTheme.neonCyan,
                                border: Border.all(color: Colors.black, width: 2),
                              ),
                              child: const Icon(
                                Icons.two_wheeler,
                                color: Colors.black,
                                size: 18,
                              ),
                            ),
                          );
                        });
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Convoys Management List
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Active Convoys',
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  '${convoys.length} live sessions',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (convoys.isEmpty)
              Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No convoys on the road right now. Finished rides are in Ride history.',
                    style: TextStyle(color: AppTheme.textMuted),
                  ),
                ),
              )
            else
              ...convoys.map((convoy) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: GlassCard(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AdminConvoyInspector(convoy: convoy),
                        ),
                      );
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: AppTheme.neonCyan.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(Icons.group_work, color: AppTheme.neonCyan, size: 20),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    convoy.name,
                                    style: TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                  ),
                                  Text(
                                    'Code: ${convoy.joinCode} · Lead: ${convoy.createdByUserName}',
                                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppTheme.emeraldSafe.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.people, size: 12, color: AppTheme.emeraldSafe),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${convoy.riders.length}',
                                    style: TextStyle(
                                      color: AppTheme.emeraldSafe,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(child: Text(
                              'Destination: ${convoy.destinationName.ifEmpty ? 'Open Highway' : convoy.destinationName}',
                              style: TextStyle(color: AppTheme.textMuted, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis)),
                            Row(
                              children: [
                                Text(
                                  'Inspect Telemetry',
                                  style: TextStyle(
                                    color: AppTheme.neonCyan,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Icon(Icons.chevron_right, color: AppTheme.neonCyan, size: 16),
                              ],
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
        ),
      ),
    );
  }

  Widget _buildKpiCard({
    required String title,
    required String value,
    required IconData icon,
    required Color accentColor,
  }) {
    return Expanded(
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: accentColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: accentColor, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension StringExtension on String {
  bool get ifEmpty => trim().isEmpty;
}
