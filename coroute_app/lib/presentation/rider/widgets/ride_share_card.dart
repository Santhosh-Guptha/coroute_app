import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../domain/garage/bike_profile.dart';

/// A high-impact, tactical ride summary share card designed for motorcyclists.
class RideShareCard extends StatelessWidget {
  final String rideTitle;
  final String? convoyCode;
  final DateTime startTime;
  final double distanceKm;
  final Duration duration;
  final double avgSpeedKmh;
  final double topSpeedKmh;
  final double? elevationGainM;
  final BikeProfile? bike;
  final VoidCallback? onShareCard;
  final VoidCallback? onExportGpx;

  const RideShareCard({
    super.key,
    required this.rideTitle,
    this.convoyCode,
    required this.startTime,
    required this.distanceKm,
    required this.duration,
    required this.avgSpeedKmh,
    required this.topSpeedKmh,
    this.elevationGainM,
    this.bike,
    this.onShareCard,
    this.onExportGpx,
  });

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final mins = d.inMinutes.remainder(60);
    if (hours > 0) {
      return '${hours}h ${mins}m';
    }
    return '${mins}m';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.elevatedCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.subtleBorder, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: Brand & Convoy Code
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: AppTheme.slateCard,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
              border: Border(
                bottom: BorderSide(color: AppTheme.subtleBorder, width: 1),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.two_wheeler, color: AppTheme.neonCyan, size: 22),
                const SizedBox(width: 10),
                Text(
                  'COROUTE TACTICAL',
                  style: TextStyle(
                    color: AppTheme.neonCyan,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
                const Spacer(),
                if (convoyCode != null && convoyCode!.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.neonCyan.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.neonCyan.withOpacity(0.4)),
                    ),
                    child: Text(
                      'PACK #$convoyCode',
                      style: TextStyle(
                        color: AppTheme.neonCyan,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Ride Title & Date
                Text(
                  rideTitle,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${startTime.day}/${startTime.month}/${startTime.year} · ${_formatDuration(duration)} on the road',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                  ),
                ),

                const SizedBox(height: 18),

                // Core Stats Grid (2x2)
                Row(
                  children: [
                    Expanded(
                      child: _StatTile(
                        label: 'DISTANCE',
                        value: distanceKm.toStringAsFixed(1),
                        unit: 'km',
                        icon: Icons.alt_route,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatTile(
                        label: 'TOP SPEED',
                        value: topSpeedKmh.round().toString(),
                        unit: 'km/h',
                        icon: Icons.speed,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _StatTile(
                        label: 'AVG SPEED',
                        value: avgSpeedKmh.round().toString(),
                        unit: 'km/h',
                        icon: Icons.timeline,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatTile(
                        label: elevationGainM != null ? 'ELEVATION' : 'DURATION',
                        value: elevationGainM != null
                            ? elevationGainM!.round().toString()
                            : _formatDuration(duration),
                        unit: elevationGainM != null ? 'm' : '',
                        icon: elevationGainM != null ? Icons.terrain : Icons.timer,
                      ),
                    ),
                  ],
                ),

                // Active Bike Banner (if present)
                if (bike != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.darkCanvas,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.subtleBorder),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.motorcycle, color: AppTheme.textSecondary, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                bike!.name,
                                style: TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                '${bike!.tankCapacityL.toStringAsFixed(1)}L Tank · ${bike!.expectedMileageKmL.toStringAsFixed(0)} km/L Base',
                                style: TextStyle(
                                  color: AppTheme.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Action Buttons
                if (onShareCard != null || onExportGpx != null) ...[
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      if (onExportGpx != null)
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: onExportGpx,
                            icon: const Icon(Icons.file_download, size: 18),
                            label: const Text('Export GPX'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.textPrimary,
                              side: BorderSide(color: AppTheme.subtleBorder),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      if (onShareCard != null && onExportGpx != null)
                        const SizedBox(width: 12),
                      if (onShareCard != null)
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: onShareCard,
                            icon: const Icon(Icons.share, size: 18),
                            label: const Text('Share Summary'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.neonCyan,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final IconData icon;

  const _StatTile({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.darkCanvas,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.subtleBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppTheme.textMuted, size: 16),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'monospace',
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(
                  unit,
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
