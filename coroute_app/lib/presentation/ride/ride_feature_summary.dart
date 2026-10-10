import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/services/convoy_service.dart';

class RideFeatureSummary extends StatefulWidget {
  const RideFeatureSummary({super.key, required this.groupId});
  final String groupId;
  @override
  State<RideFeatureSummary> createState() => _RideFeatureSummaryState();
}

class _RideFeatureSummaryState extends State<RideFeatureSummary> {
  Timer? _age;
  @override
  void initState() {
    super.initState();
    _age = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _age?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ConvoyService>();
    final ride = service.allConvoys[widget.groupId];
    if (ride == null) return const SizedBox.shrink();
    final now = DateTime.now().millisecondsSinceEpoch;
    final fresh = ride.riders.values
        .where(
          (r) => r.lastSeenEpochMs <= now && now - r.lastSeenEpochMs < 120000,
        )
        .toList();
    final sharing = fresh
        .where(
          (r) =>
              r.fuelUsableKm != null &&
              r.fuelUpdatedAt > 0 &&
              r.fuelUpdatedAt <= now &&
              now - r.fuelUpdatedAt < 120000,
        )
        .length;
    final rows = <String, String>{
      'Connection': service.isOnline
          ? 'Live updates'
          : 'Offline; last received data',
      'Riders': '${fresh.length} current / ${ride.riders.length} total',
      'Fuel estimates': '$sharing fresh opt-in estimates',
      'Safety': '${ride.activeAlerts.length} active alerts',
      'Stops':
          '${ride.plannedStops.length} planned / ${ride.suggestedStops.length} suggested',
      'Route essentials': ride.featurePolicy.essentialsEnabled
          ? (ride.featurePolicy.autoDiscovery
                ? 'Automatic refresh allowed'
                : 'Manual refresh')
          : 'Disabled by lead',
      'Guardian': ride.featurePolicy.guardianEnabled
          ? 'Links allowed; ${ride.featurePolicy.guardianMaxHours} hour limit'
          : 'Disabled by lead',
      'Notification': ride.featurePolicy.notificationInsights
          ? 'Insights allowed; device permission required'
          : 'Standard ride view',
      'Power':
          '${fresh.where((r) => r.batteryLevel <= 15).length} riders reporting low battery',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Live ride analytics',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final row in rows.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text('${row.key}: ${row.value}'),
              ),
            const Text(
              'Sharing counts exclude stale estimates. Disabled features do not disable emergency actions.',
            ),
          ],
        ),
      ),
    );
  }
}
