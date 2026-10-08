import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/outbox_item.dart';
import '../../data/models/stop_point_model.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/geo_service.dart';
import '../../domain/tracking/geo_math.dart';
import '../map_picker/map_picker_screen.dart';
import '../ride/incident_sheet.dart';

/// The route during a ride: start, stops (with suggestions from members),
/// destination and the route summary. The lead can add, reorder, skip and
/// remove stops and change the destination; everyone else can suggest a stop.
///
/// Trip progress (ticks and "You are here") is shown in the ride sheet; this
/// panel is where the route is managed.
class RouteStopsPanel extends StatelessWidget {
  final ConvoyModel convoy;
  final bool shrinkWrap;
  const RouteStopsPanel({super.key, required this.convoy, this.shrinkWrap = false});

  /// Kept for one release for older callers; new code uses [StopKind].
  static const Map<String, IconData> categoryIcons = {
    'FUEL': Icons.local_gas_station_rounded,
    'FOOD': Icons.restaurant_rounded,
    'REST': Icons.airline_seat_recline_normal_rounded,
    'SCENIC': Icons.landscape_rounded,
    'TOLL': Icons.toll_rounded,
    'OTHER': Icons.place_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ConvoyService>();
    final lead = service.canEditRoute;
    final me = service.myUserId != null ? convoy.riders[service.myUserId] : null;
    final meLat = me?.lat ?? 0.0, meLng = me?.lng ?? 0.0;
    final hasMe = meLat != 0 || meLng != 0;
    final planned = convoy.plannedStops;
    final skipped = convoy.stopPoints.where((s) => s.isSkipped).toList();
    final suggestions = convoy.suggestedStops;
    final route = convoy.route;
    // Visited ticks set without signal wait in the outbox ("Waiting for signal" under the stop).
    final queuedVisits = <String, OutboxItem>{
      for (final o in service.outbox)
        if (o.type == 'STOP_VISITED' && o.groupId == convoy.groupId && o.payload['stopId'] != null) o.payload['stopId'].toString(): o,
    };

    // Who has reached a stop (with the time), who rode past, who is still coming.
    final hhmm = DateFormat('HH:mm');
    String arrivalsLine(Map<String, StopArrival> arrivals) {
      if (convoy.riders.isEmpty || arrivals.isEmpty) return '';
      final reached = <String>[], passed = <String>[], waiting = <String>[];
      convoy.riders.forEach((uid, r) {
        final a = arrivals[uid];
        final first = r.name.split(' ').first;
        if (a != null && a.reached) {
          reached.add('$first ${hhmm.format(DateTime.fromMillisecondsSinceEpoch(a.arrivedAt))}');
        } else if (a != null && a.passed) {
          passed.add(first);
        } else {
          waiting.add(first);
        }
      });
      if (waiting.isEmpty && passed.isEmpty) return 'Everyone reached: ${reached.join(', ')}';
      return [
        '${reached.length} of ${convoy.riders.length} reached${reached.isEmpty ? '' : ': ${reached.join(', ')}'}',
        if (passed.isNotEmpty) 'rode past: ${passed.join(', ')}',
        if (waiting.isNotEmpty) 'waiting for ${waiting.join(', ')}',
      ].join(', ');
    }

    String fromMe(double lat, double lng) => hasMe ? formatDistanceRounded(GeoMath.haversine(meLat, meLng, lat, lng)) : '';

    Future<void> addOrSuggest() async {
      final p = await MapPickerScreen.pick(
        context,
        title: lead ? 'Add a stop' : 'Suggest a stop',
        forStop: true,
        confirmLabel: lead ? 'Add stop' : 'Send suggestion',
        initial: hasMe ? PickedPlace(lat: meLat, lng: meLng) : null,
      );
      if (p == null) return;
      final ok = lead ? service.addStop(p) : service.suggestStop(p);
      if (ok && !lead && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Suggestion sent to the lead.')));
      }
    }

    Future<void> changeDestination() async {
      final p = await MapPickerScreen.pick(
        context,
        title: 'Destination',
        initial: (convoy.destinationLat != 0 || convoy.destinationLng != 0)
            ? PickedPlace(lat: convoy.destinationLat, lng: convoy.destinationLng, name: convoy.destinationName)
            : null,
      );
      if (p != null) service.setDestination(p);
    }

    void move(int from, int to) {
      if (!lead || to < 0 || to >= planned.length || from == to) return;
      final ids = planned.map((s) => s.stopId).toList();
      final id = ids.removeAt(from);
      ids.insert(to, id);
      service.reorderStops(ids);
    }

    final children = <Widget>[
      if (route != null) ...[
        RouteSummary(
          distanceKm: route.distanceM / 1000,
          duration: Duration(seconds: route.durationS),
          stops: planned.length,
          riders: convoy.riders.length,
        ),
        if (route.approximate)
          Padding(
            padding: const EdgeInsets.only(top: Space.s8),
            child: Text('Straight-line estimate: the road route is not available right now.', style: AppText.caption),
          ),
        const SizedBox(height: Space.s16),
      ],
      _EndRow(
        icon: Icons.trip_origin_rounded,
        color: StatusColors.success,
        title: convoy.startLocationName.isNotEmpty ? convoy.startLocationName : 'Start',
        subtitle: 'Start',
      ),
      const SizedBox(height: Space.s8),
      if (planned.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.s8),
          child: Text('No stops planned.', style: AppText.body.copyWith(color: AppTheme.textSecondary)),
        )
      else
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          // The lead can long-press a stop to drag it; the menu also has Move up / Move down.
          buildDefaultDragHandles: lead,
          itemCount: planned.length,
          onReorder: (from, to) => move(from, to > from ? to - 1 : to),
          itemBuilder: (_, i) {
            final s = planned[i];
            return _StopTile(
              key: ValueKey(s.stopId),
              stop: s,
              index: i,
              count: planned.length,
              lead: lead,
              distance: s.isVisited ? '' : fromMe(s.lat, s.lng),
              arrivals: arrivalsLine(s.arrivals),
              queued: queuedVisits[s.stopId],
              online: service.isOnline,
              onVisited: (v) => service.toggleStopVisited(s.stopId, v),
              onSkip: () => service.skipStop(s.stopId),
              onRemove: () => service.removeStop(s.stopId),
              onMove: (to) => move(i, to),
            );
          },
        ),
      for (final s in skipped)
        Padding(
          padding: const EdgeInsets.only(bottom: Space.s8),
          child: StopCard(kind: StopKind.fromCategory(s.category), name: s.name, subtitle: 'Skipped'),
        ),
      _EndRow(
        icon: Icons.sports_score_rounded,
        color: StatusColors.critical,
        title: convoy.destinationName.isNotEmpty ? convoy.destinationName : 'No destination set',
        subtitle: [
          (convoy.destinationLat != 0 || convoy.destinationLng != 0)
              ? ['Destination', if (fromMe(convoy.destinationLat, convoy.destinationLng).isNotEmpty) fromMe(convoy.destinationLat, convoy.destinationLng)].join(', ')
              : 'Destination',
          if (arrivalsLine(convoy.destinationArrivals).isNotEmpty) arrivalsLine(convoy.destinationArrivals),
        ].join('\n'),
        trailing: lead
            ? IconButton(tooltip: 'Change destination', icon: Icon(Icons.edit_location_alt_rounded, color: AppTheme.textSecondary), onPressed: changeDestination)
            : null,
      ),
      const SizedBox(height: Space.s12),
      OutlinedButton.icon(
        onPressed: planned.length + suggestions.length >= 20 ? null : addOrSuggest,
        icon: Icon(lead ? Icons.add_location_alt_rounded : Icons.add_comment_rounded),
        label: Text(lead ? 'Add a stop' : 'Suggest a stop'),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ),
      if (suggestions.isNotEmpty) ...[
        const SizedBox(height: Space.s24),
        Semantics(
          header: true,
          child: Text(lead ? 'Suggested by the group' : 'Suggestions waiting for the lead', style: AppText.label),
        ),
        const SizedBox(height: Space.s8),
        for (final s in suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StopCard(
                  kind: StopKind.fromCategory(s.category),
                  name: s.name,
                  subtitle: [
                    if (s.suggestedByName.isNotEmpty) 'From ${s.suggestedByName}',
                    if (fromMe(s.lat, s.lng).isNotEmpty) fromMe(s.lat, s.lng),
                  ].join(', '),
                ),
                if (lead) ...[
                  const SizedBox(height: Space.s8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                          onPressed: () => service.declineStop(s.stopId),
                          icon: const Icon(Icons.close_rounded),
                          label: const Text('Decline', maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                      const SizedBox(width: Space.s8),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                          onPressed: () => service.acceptStop(s.stopId),
                          icon: const Icon(Icons.check_rounded),
                          label: const Text('Add to route', maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
      ],
    ];

    return ListView(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.symmetric(vertical: Space.s8),
      children: children,
    );
  }
}

/// Start or destination row.
class _EndRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final Widget? trailing;

  const _EndRow({required this.icon, required this.color, required this.title, required this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    final tr = trailing;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: [
          SizedBox(width: 40, child: Icon(icon, color: color, size: 24)),
          const SizedBox(width: Space.s12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                if (subtitle.isNotEmpty) Text(subtitle, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.caption),
              ],
            ),
          ),
          ?tr,
        ],
      ),
    );
  }
}

class _StopTile extends StatelessWidget {
  final StopPointModel stop;
  final int index;
  final int count;
  final bool lead;
  final String distance;
  final String arrivals;
  final OutboxItem? queued;
  final bool online;
  final ValueChanged<bool> onVisited;
  final VoidCallback onSkip;
  final VoidCallback onRemove;
  final ValueChanged<int> onMove;

  const _StopTile({
    super.key,
    required this.stop,
    required this.index,
    required this.count,
    required this.lead,
    required this.distance,
    this.arrivals = '',
    this.queued,
    this.online = true,
    required this.onVisited,
    required this.onSkip,
    required this.onRemove,
    required this.onMove,
  });

  @override
  Widget build(BuildContext context) {
    final s = stop;
    final q = queued;
    final details = [
      s.isVisited ? 'Visited' : 'Stop ${index + 1}',
      if (distance.isNotEmpty) distance,
      if (s.plannedDwellMin > 0) 'stay ${s.plannedDwellMin} min',
      if (s.suggestedByName.isNotEmpty) 'added by ${s.suggestedByName}',
    ].join(', ');
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StopCard(
            kind: StopKind.fromCategory(s.category),
            name: s.name,
            subtitle: details,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // One tick control: tap to mark visited, tap again to undo.
                IconButton(
                  tooltip: s.isVisited ? 'Mark as not visited' : 'Mark as visited',
                  icon: Icon(
                    s.isVisited ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                    color: s.isVisited ? StatusColors.success : AppTheme.textSecondary,
                  ),
                  onPressed: () => onVisited(!s.isVisited),
                ),
                if (lead)
                  PopupMenuButton<String>(
                    tooltip: 'Stop options',
                    icon: Icon(Icons.more_vert_rounded, color: AppTheme.textSecondary),
                    color: AppTheme.elevatedCard,
                    onSelected: (v) {
                      switch (v) {
                        case 'up':
                          onMove(index - 1);
                          break;
                        case 'down':
                          onMove(index + 1);
                          break;
                        case 'skip':
                          onSkip();
                          break;
                        default:
                          onRemove();
                      }
                    },
                    itemBuilder: (_) => [
                      if (index > 0) const PopupMenuItem(value: 'up', child: Text('Move up')),
                      if (index < count - 1) const PopupMenuItem(value: 'down', child: Text('Move down')),
                      const PopupMenuItem(value: 'skip', child: Text('Skip this stop')),
                      const PopupMenuItem(value: 'remove', child: Text('Remove from the route')),
                    ],
                  ),
              ],
            ),
          ),
          if (arrivals.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.s12, Space.s4, Space.s12, 0),
              child: Text(arrivals, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
            ),
          if (q != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.s12, Space.s4, Space.s12, 0),
              child: QueuedLine(what: 'Visited mark', failed: q.state == OutboxState.failed, sending: online),
            ),
        ],
      ),
    );
  }
}
