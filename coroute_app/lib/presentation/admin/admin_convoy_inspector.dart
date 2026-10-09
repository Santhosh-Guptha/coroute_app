import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/telemetry_utils.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/map_tiles.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/convoy_service.dart';
import '../../domain/timeline/timeline_text.dart';
import '../report/replay_screen.dart';
import '../ride/riders_ladder.dart';
import '../timeline/live_timeline_screen.dart';
import '../timeline/member_colors.dart';
import 'admin_ui.dart';

/// Master admin: one live ride. Open SOS first, then the map, the group
/// numbers and every rider with their status. Tapping a rider (row or map
/// marker) opens a short rider card in a sheet. On a wide screen the map and
/// the list sit side by side.
class AdminConvoyInspector extends StatefulWidget {
  final ConvoyModel convoy;

  const AdminConvoyInspector({super.key, required this.convoy});

  @override
  State<AdminConvoyInspector> createState() => _AdminConvoyInspectorState();
}

class _AdminConvoyInspectorState extends State<AdminConvoyInspector> {
  final _map = MapController();

  Future<void> _confirmDissolveConvoy(BuildContext context, ConvoyService convoyService, ConvoyModel convoy) async {
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

  void _focus(double lat, double lng) {
    if (lat == 0 && lng == 0) return;
    try {
      _map.move(LatLng(lat, lng), math.max(_map.camera.zoom, 15.0));
    } catch (_) {
      // The map is not laid out yet.
    }
  }

  void _showRider(RiderModel r, RiderStatus status, Color? color) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final detail = riderStatusDetail(r, status, nowMs: now);
    final reason = riderReasonText(r);
    final vehicle = [r.vehicleType, r.vehicleColor, r.vehicleNo].where((s) => s.trim().isNotEmpty).join(', ');
    final hasFix = r.lat != 0 || r.lng != 0;
    showAppSheet<void>(
      context,
      builder: (ctx) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                RiderAvatar(name: r.name, color: color, status: status, size: 48),
                const SizedBox(width: Space.s12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.name.isEmpty ? 'Rider' : r.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
                      Text(adminRoleLabel(r.role), style: AppText.label),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.s12),
            Align(alignment: AlignmentDirectional.centerStart, child: RiderStatusChip(status: status, detail: detail)),
            const SizedBox(height: Space.s16),
            Row(
              children: [
                Expanded(child: RideMetric(value: r.speedKmh.toStringAsFixed(0), unit: 'km/h', label: 'Speed')),
                Expanded(
                  child: RideMetric(value: '${r.heading.round()}°', unit: TelemetryUtils.getCardinalDirection(r.heading), label: 'Heading'),
                ),
                Expanded(child: RideMetric(value: '${r.batteryLevel}', unit: '%', label: r.isCharging ? 'Battery, charging' : 'Battery')),
              ],
            ),
            const SizedBox(height: Space.s16),
            Text(
              r.lastSeenEpochMs > 0 ? 'Last update ${formatAgo(Duration(milliseconds: now - r.lastSeenEpochMs))}' : 'No update yet',
              style: AppText.label,
            ),
            if (reason.isNotEmpty) Text('Said: $reason', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label),
            if (vehicle.isNotEmpty) Text(vehicle, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
            if (hasFix) ...[
              const SizedBox(height: Space.s16),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _focus(r.lat, r.lng);
                },
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                icon: const Icon(Icons.my_location_rounded),
                label: const Text('Show on map'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final convoyService = context.watch<ConvoyService>();
    final current = convoyService.allConvoys[widget.convoy.groupId] ?? widget.convoy;
    final now = DateTime.now().millisecondsSinceEpoch;
    final colors = MemberColors.assign(current.riders.keys);
    final status = <String, RiderStatus>{
      for (final r in current.riders.values) r.userId: riderStatusOf(r, current, isMe: false, nowMs: now),
    };
    final riders = current.riders.values.toList()
      ..sort((a, b) {
        final p = (status[b.userId]?.priority ?? 0).compareTo(status[a.userId]?.priority ?? 0);
        return p != 0 ? p : a.name.compareTo(b.name);
      });
    final sos = current.activeAlerts.where((a) => !a.resolved).toList()..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final metrics = TelemetryUtils.calculateConvoyMetrics(riders);

    final located = riders.where((r) => r.lat != 0 || r.lng != 0).toList();
    final LatLng center;
    if (located.isNotEmpty) {
      center = LatLng(located.first.lat, located.first.lng);
    } else if (current.destinationLat != 0.0 || current.destinationLng != 0.0) {
      center = LatLng(current.destinationLat, current.destinationLng);
    } else {
      center = const LatLng(AppConstants.defaultMapLat, AppConstants.defaultMapLng);
    }

    final alerts = <Widget>[
      for (final a in sos)
        Padding(
          padding: const EdgeInsets.only(bottom: Space.s8),
          child: RideAlert(
            tier: AlertTier.critical,
            title: 'SOS: ${a.userName.isEmpty ? 'a rider' : a.userName} needs help',
            message: '${adminCapitalize(TimelineText.reason(a.alertType))}, ${formatAgo(Duration(milliseconds: math.max(0, now - a.timestamp)))}',
            actionLabel: (a.lat != 0 || a.lng != 0) ? 'Show on map' : null,
            onAction: (a.lat != 0 || a.lng != 0) ? () => _focus(a.lat, a.lng) : null,
          ),
        ),
    ];

    final map = ClipRRect(
      borderRadius: Radii.mdAll,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(borderRadius: Radii.mdAll, border: Border.all(color: AppTheme.subtleBorder)),
        child: FlutterMap(
          mapController: _map,
          options: MapOptions(initialCenter: center, initialZoom: located.isEmpty ? 5 : 14.5),
          children: [
            appTileLayer(),
            MarkerLayer(
              markers: [
                for (final r in located)
                  Marker(
                    point: LatLng(r.lat, r.lng),
                    width: 48,
                    height: 48,
                    child: RiderAvatar(
                      name: r.name,
                      color: colors[r.userId],
                      status: status[r.userId],
                      size: 40,
                      onTap: () => _showRider(r, status[r.userId] ?? RiderStatus.offline, colors[r.userId]),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );

    final dist = formatDistance(metrics.spreadKm * 1000);
    final cut = dist.lastIndexOf(' ');
    final facts = [
      if (current.joinCode.isNotEmpty) 'Code ${current.joinCode}',
      if (current.createdByUserName.isNotEmpty) 'lead ${current.createdByUserName}',
      if (current.destinationName.trim().isNotEmpty) 'to ${current.destinationName}',
    ].join(', ');
    final numbers = AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: RideMetric(value: '${riders.length}', label: 'Riders')),
              Expanded(
                child: cut > 0
                    ? RideMetric(value: dist.substring(0, cut), unit: dist.substring(cut + 1), label: 'Spread')
                    : RideMetric(value: dist, label: 'Spread'),
              ),
              Expanded(child: RideMetric(value: metrics.averageSpeedKmh.toStringAsFixed(0), unit: 'km/h', label: 'Avg speed')),
            ],
          ),
          const SizedBox(height: Space.s12),
          StatusLine(icon: Icons.groups_rounded, text: 'Formation: ${metrics.status}'),
          if (facts.isNotEmpty) ...[
            const SizedBox(height: Space.s4),
            Text(facts, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
          ],
        ],
      ),
    );

    final roster = <Widget>[
      AdminSectionLabel('Riders (${riders.length})'),
      if (riders.isEmpty) Text('Nobody has joined yet.', style: AppText.body.copyWith(color: AppTheme.textSecondary)),
      for (final r in riders)
        Padding(
          padding: const EdgeInsets.only(bottom: Space.s8),
          child: AdminRow(
            key: ValueKey(r.userId),
            leading: RiderAvatar(name: r.name, color: colors[r.userId], status: status[r.userId]),
            title: r.name.isEmpty ? 'Rider' : r.name,
            subtitle: [adminRoleLabel(r.role), r.vehicleType].where((s) => s.isNotEmpty).join(', '),
            detail: '${r.speedKmh.toStringAsFixed(0)} km/h, heading ${r.heading.round()}° ${TelemetryUtils.getCardinalDirection(r.heading)}',
            status: RiderStatusChip(
              status: status[r.userId] ?? RiderStatus.offline,
              detail: riderStatusDetail(r, status[r.userId] ?? RiderStatus.offline, nowMs: now),
            ),
            onTap: () => _showRider(r, status[r.userId] ?? RiderStatus.offline, colors[r.userId]),
          ),
        ),
    ];

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: Text(current.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Live timeline',
            icon: const Icon(Icons.timeline_rounded),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => LiveTimelineScreen(groupId: current.groupId)),
            ),
          ),
          IconButton(
            tooltip: 'Replay and routes',
            icon: const Icon(Icons.slow_motion_video_rounded),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ReplayScreen(groupId: current.groupId, title: '${current.name}: Replay')),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'More options',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (v) {
              if (v == 'end') _confirmDissolveConvoy(context, convoyService, current);
            },
            itemBuilder: (_) => [
              PopupMenuItem<String>(
                value: 'end',
                height: 48,
                child: Row(children: [
                  Icon(Icons.stop_circle_rounded, color: StatusColors.critical),
                  const SizedBox(width: Space.s12),
                  const Flexible(child: Text('End ride for everyone', maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
              ),
            ],
          ),
        ],
      ),
      body: LayoutBuilder(builder: (context, c) {
        if (c.maxWidth >= adminWideBreakpoint) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: Padding(padding: const EdgeInsets.all(Space.s16), child: map)),
              SizedBox(
                width: (c.maxWidth * 0.4).clamp(340.0, 460.0).toDouble(),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(0, Space.s16, Space.s16, Space.s32),
                  children: [...alerts, numbers, ...roster],
                ),
              ),
            ],
          );
        }
        final mapHeight = (c.maxHeight * 0.45).clamp(200.0, 320.0).toDouble();
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Space.s16, Space.s16, Space.s16, Space.s32),
              children: [
                ...alerts,
                SizedBox(height: mapHeight, child: map),
                const SizedBox(height: Space.s16),
                numbers,
                ...roster,
              ],
            ),
          ),
        );
      }),
    );
  }
}
