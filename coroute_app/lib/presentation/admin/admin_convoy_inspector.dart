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
    messenger.clearSnackBars();
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
      isScrollControlled: true,
      builder: (ctx) => SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                RiderAvatar(name: r.name, color: color, status: status, size: 48),
                const SizedBox(width: 12),
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
            const SizedBox(height: 12),
            Align(alignment: AlignmentDirectional.centerStart, child: RiderStatusChip(status: status, detail: detail)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: DsStatCell(label: 'Speed', value: '${r.speedKmh.toStringAsFixed(0)} km/h')),
                const SizedBox(width: 8),
                Expanded(child: DsStatCell(label: 'Heading', value: '${r.heading.round()}° ${TelemetryUtils.getCardinalDirection(r.heading)}')),
                const SizedBox(width: 8),
                Expanded(child: DsStatCell(label: r.isCharging ? 'Battery, charging' : 'Battery', value: '${r.batteryLevel}%')),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              r.lastSeenEpochMs > 0 ? 'Last update ${formatAgo(Duration(milliseconds: now - r.lastSeenEpochMs))}' : 'No update yet',
              style: AppText.label,
            ),
            if (reason.isNotEmpty) Text('Said: $reason', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label),
            if (vehicle.isNotEmpty) Text(vehicle, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
            if (hasFix) ...[
              const SizedBox(height: 16),
              DsButton(
                label: 'Show on map',
                icon: Icons.my_location_rounded,
                onPressed: () {
                  Navigator.pop(ctx);
                  _focus(r.lat, r.lng);
                },
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
          padding: const EdgeInsets.only(bottom: 10),
          child: RideAlert(
            tier: AlertTier.critical,
            title: 'SOS: ${a.userName.isEmpty ? 'a rider' : a.userName} needs help',
            message: '${adminCapitalize(TimelineText.reason(a.alertType))}, ${formatAgo(Duration(milliseconds: math.max(0, now - a.timestamp)))}',
            actionLabel: (a.lat != 0 || a.lng != 0) ? 'Show on map' : null,
            onAction: (a.lat != 0 || a.lng != 0) ? () => _focus(a.lat, a.lng) : null,
          ),
        ),
    ];

    final map = DsCard(
      padding: EdgeInsets.zero,
      child: SizedBox.expand(
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

    final spreadColor = metrics.spreadKm >= 6
        ? AppTheme.sos
        : metrics.spreadKm >= 3
            ? AppTheme.warnText
            : AppTheme.accentText;
    final facts = [
      if (current.joinCode.isNotEmpty) 'Code ${current.joinCode}',
      if (current.createdByUserName.isNotEmpty) 'lead ${current.createdByUserName}',
      if (current.destinationName.trim().isNotEmpty) 'to ${current.destinationName}',
    ].join(', ');
    final numbers = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdminKpiGrid(
          tiles: [
            AdminKpiTile(label: 'Riders', value: '${riders.length}', delta: '${metrics.movingRiderCount} moving'),
            AdminKpiTile(label: 'Spread', value: formatDistance(metrics.spreadKm * 1000), valueColor: spreadColor, delta: metrics.status, deltaColor: spreadColor),
            AdminKpiTile(label: 'Avg speed', value: '${metrics.averageSpeedKmh.toStringAsFixed(0)} km/h', delta: 'Top ${metrics.maxSpeedKmh.toStringAsFixed(0)} km/h'),
          ],
        ),
        const SizedBox(height: 12),
        DsCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StatusLine(icon: Icons.groups_rounded, text: 'Formation: ${metrics.status}', color: AppTheme.text),
              if (facts.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(facts, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
              ],
            ],
          ),
        ),
      ],
    );

    final roster = <Widget>[
      AdminSectionLabel('Riders (${riders.length})'),
      AdminTable(
        columns: const ['Rider', 'Status'],
        empty: Text('Nobody has joined yet.', style: AppText.body.copyWith(color: AppTheme.text2)),
        rows: [
          for (var i = 0; i < riders.length; i++)
            AdminRow(
              key: ValueKey(riders[i].userId),
              leading: RiderAvatar(name: riders[i].name, color: colors[riders[i].userId], status: status[riders[i].userId]),
              title: riders[i].name.isEmpty ? 'Rider' : riders[i].name,
              subtitle: [adminRoleLabel(riders[i].role), riders[i].vehicleType].where((s) => s.isNotEmpty).join(', '),
              detail: '${riders[i].speedKmh.toStringAsFixed(0)} km/h, heading ${riders[i].heading.round()}° ${TelemetryUtils.getCardinalDirection(riders[i].heading)}',
              status: RiderStatusChip(
                status: status[riders[i].userId] ?? RiderStatus.offline,
                detail: riderStatusDetail(riders[i], status[riders[i].userId] ?? RiderStatus.offline, nowMs: now),
              ),
              divider: i < riders.length - 1,
              onTap: () => _showRider(riders[i], status[riders[i].userId] ?? RiderStatus.offline, colors[riders[i].userId]),
            ),
        ],
      ),
    ];

    final more = PopupMenuButton<String>(
      tooltip: 'More options',
      color: AppTheme.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: AppTheme.border, width: 2)),
      onSelected: (v) {
        if (v == 'end') _confirmDissolveConvoy(context, convoyService, current);
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          value: 'end',
          height: 48,
          child: Row(children: [
            Icon(Icons.stop_circle_rounded, color: AppTheme.sos),
            const SizedBox(width: 12),
            Flexible(child: Text('End ride for everyone', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700))),
          ]),
        ),
      ],
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(shape: BoxShape.circle, color: AppTheme.card, border: Border.all(color: AppTheme.border, width: 2)),
        child: Icon(Icons.more_horiz_rounded, color: AppTheme.text, size: 22),
      ),
    );

    return AdminShell(
      title: current.name.isEmpty ? 'Ride' : current.name,
      subtitle: facts.isEmpty ? 'Live ride' : facts,
      onBack: () => Navigator.maybePop(context),
      actions: [
        AdminIconAction(
          icon: Icons.timeline_rounded,
          label: 'Live timeline',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => LiveTimelineScreen(groupId: current.groupId)),
          ),
        ),
        AdminIconAction(
          icon: Icons.slow_motion_video_rounded,
          label: 'Replay and routes',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ReplayScreen(groupId: current.groupId, title: '${current.name}: Replay')),
          ),
        ),
        more,
      ],
      body: LayoutBuilder(builder: (context, c) {
        if (c.maxWidth >= adminWideBreakpoint) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: adminMaxContentWidth),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(24, 8, 0, 32), child: map)),
                  SizedBox(
                    width: (c.maxWidth * 0.4).clamp(360.0, 480.0).toDouble(),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 24, 32),
                      children: [...alerts, numbers, ...roster],
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        final mapHeight = (c.maxHeight * 0.45).clamp(200.0, 320.0).toDouble();
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: adminMaxContentWidth),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
              children: [
                ...alerts,
                SizedBox(height: mapHeight, child: map),
                const SizedBox(height: 16),
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
