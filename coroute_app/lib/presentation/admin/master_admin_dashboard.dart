import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/devmonks_branding.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../auth/access_gate_screen.dart';
import 'admin_convoy_inspector.dart';

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
    if (count == 0) return const LatLng(20.5937, 78.9629); // India center as neutral default
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
          title: const Row(
            children: [
              Icon(Icons.campaign, color: AppTheme.hyperAmber),
              SizedBox(width: 8),
              Text('Global Safety Broadcast', style: TextStyle(color: Colors.white, fontSize: 18)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This alert will be broadcasted to all active convoys immediately on their map HUD.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _broadcastController,
                maxLines: 2,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'e.g. Heavy rain alert on NH-48. Reduce speed and regroup.',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
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
    final isOnline = convoyService.isOnline;
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
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.devmonksPurple,
              ),
              child: const Icon(Icons.shield, color: Colors.white, size: 16),
            ),
            const SizedBox(width: 8),
            const Text(
              'Master Admin Console',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Safety Broadcast',
            icon: const Icon(Icons.campaign, color: AppTheme.hyperAmber),
            onPressed: () => _showBroadcastDialog(context, convoyService),
          ),
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout, color: AppTheme.textMuted),
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
            // Admin Identity & devmonks.space banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.elevatedCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.devmonksPurple.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.admin_panel_settings, color: AppTheme.neonCyan, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Root Access: ${auth.currentUserEmail}',
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const DevMonksBadge(isCompact: true),
                ],
              ),
            ),

            const SizedBox(height: 10),

            // Gateway / Oracle Autonomous Database status card
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.slateCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isOnline
                      ? AppTheme.emeraldSafe.withOpacity(0.6)
                      : AppTheme.hyperAmber.withOpacity(0.4),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isOnline ? AppTheme.emeraldSafe : AppTheme.hyperAmber,
                      boxShadow: [
                        BoxShadow(
                          color: (isOnline ? AppTheme.emeraldSafe : AppTheme.hyperAmber)
                              .withOpacity(0.6),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'CoRoute Gateway · Oracle Autonomous DB',
                          style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          isOnline
                              ? 'Realtime link up · fleet updates pushed live'
                              : 'Reconnecting to gateway…',
                          style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.devmonksPurple.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

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
            const Text(
              'Global Fleet Radar',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
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
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.5),
                                    blurRadius: 4,
                                  ),
                                ],
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
                const Text(
                  'Active Convoys',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  '${convoys.length} live sessions',
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (convoys.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No active convoys running currently.',
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
                              child: const Icon(Icons.group_work, color: AppTheme.neonCyan, size: 20),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    convoy.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                  ),
                                  Text(
                                    'Code: ${convoy.joinCode} · Lead: ${convoy.createdByUserName}',
                                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
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
                                  const Icon(Icons.people, size: 12, color: AppTheme.emeraldSafe),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${convoy.riders.length}',
                                    style: const TextStyle(
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
                            Text(
                              'Destination: ${convoy.destinationName.ifEmpty ? 'Open Highway' : convoy.destinationName}',
                              style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                            ),
                            const Row(
                              children: [
                                Text(
                                  'Inspect Telemetry',
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
                    style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: const TextStyle(
                      color: Colors.white,
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
