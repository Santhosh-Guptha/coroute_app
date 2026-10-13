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
import '../ride/navigate_to.dart';

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

    final hasDestination = convoy.destinationLat != 0 || convoy.destinationLng != 0;
    final destinationDistance = hasDestination ? fromMe(convoy.destinationLat, convoy.destinationLng) : '';
    final destinationArrivals = arrivalsLine(convoy.destinationArrivals);

    final children = <Widget>[
      if (route != null) ...[
        Row(
          children: [
            Expanded(child: DsStatCell(label: 'Distance', value: formatDistance(route.distanceM))),
            const SizedBox(width: 10),
            Expanded(child: DsStatCell(label: 'Time', value: formatDuration(Duration(seconds: route.durationS)))),
            const SizedBox(width: 10),
            Expanded(child: DsStatCell(label: planned.length == 1 ? 'Stop' : 'Stops', value: '${planned.length}')),
          ],
        ),
        if (route.approximate)
          Padding(
            padding: const EdgeInsets.only(top: Space.s8),
            child: Text('Straight-line estimate: the road route is not available right now.', style: AppText.caption),
          ),
        const SizedBox(height: Space.s16),
      ],
      _TimelineRow(
        ring: AppTheme.accentText,
        title: convoy.startLocationName.isNotEmpty ? convoy.startLocationName : 'Start',
        subtitle: 'Start',
      ),
      if (planned.isEmpty)
        _TimelineRow(
          ring: AppTheme.border2,
          title: 'No stops planned.',
          titleColor: AppTheme.text2,
          subtitle: lead ? 'Add one below.' : 'Suggest one below.',
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
              onNavigate: () => navigateTo(
                s.lat,
                s.lng,
                label: s.name.isEmpty ? 'Stop ${i + 1}' : s.name,
                startLat: hasMe ? meLat : null,
                startLng: hasMe ? meLng : null,
              ),
            );
          },
        ),
      for (final s in skipped)
        _TimelineRow(
          ring: AppTheme.border2,
          title: s.name.isEmpty ? StopKind.fromCategory(s.category).label : s.name,
          titleColor: AppTheme.muted,
          subtitle: 'Skipped',
          chip: DsChip('Skipped', color: AppTheme.muted, background: AppTheme.soft),
        ),
      _TimelineRow(
        ring: AppTheme.accentText,
        fill: AppTheme.brand,
        last: true,
        title: convoy.destinationName.isNotEmpty ? convoy.destinationName : 'No destination set',
        subtitle: [
          hasDestination ? ['Destination', if (destinationDistance.isNotEmpty) destinationDistance].join(' · ') : 'Destination',
          if (destinationArrivals.isNotEmpty) destinationArrivals,
        ].join('\n'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasDestination)
              IconButton(
                key: const Key('destination_navigate_button'),
                tooltip: 'Navigate to destination',
                icon: Icon(Icons.navigation_rounded, color: AppTheme.accentText),
                onPressed: () => navigateTo(
                  convoy.destinationLat,
                  convoy.destinationLng,
                  label: convoy.destinationName.isEmpty ? 'Destination' : convoy.destinationName,
                  startLat: hasMe ? meLat : null,
                  startLng: hasMe ? meLng : null,
                ),
              ),
            if (lead)
              IconButton(tooltip: 'Change destination', icon: Icon(Icons.edit_location_alt_outlined, color: AppTheme.accentText), onPressed: changeDestination),
          ],
        ),
      ),
      const SizedBox(height: Space.s12),
      Row(
        children: [
          Expanded(
            child: DsButton(
              tone: DsButtonTone.outline,
              icon: lead ? Icons.add_rounded : Icons.add_comment_outlined,
              fontSize: 15,
              label: lead ? 'Add a stop' : 'Suggest a stop',
              onPressed: planned.length + suggestions.length >= 20 ? null : addOrSuggest,
            ),
          ),
          if (!shrinkWrap) ...[
            const SizedBox(width: 10),
            Expanded(
              child: DsButton(
                icon: Icons.navigation_rounded,
                fontSize: 15,
                label: 'Back to riding',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ],
      ),
      if (suggestions.isNotEmpty) ...[
        const SizedBox(height: Space.s24),
        Semantics(
          header: true,
          child: DsSectionHeader(lead ? 'Suggested by the group' : 'Suggestions waiting for the lead'),
        ),
        const SizedBox(height: 10),
        for (final s in suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: DsCard(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(color: AppTheme.soft, borderRadius: BorderRadius.circular(14)),
                        child: Icon(StopKind.fromCategory(s.category).icon, size: 24, color: AppTheme.accentText),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s.name.isEmpty ? StopKind.fromCategory(s.category).label : s.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
                            const SizedBox(height: 3),
                            Text(
                              [
                                if (s.suggestedByName.isNotEmpty) 'From ${s.suggestedByName}',
                                if (fromMe(s.lat, s.lng).isNotEmpty) fromMe(s.lat, s.lng),
                              ].join(' · '),
                              style: AppText.label,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (lead) ...[
                    const SizedBox(height: Space.s12),
                    Row(
                      children: [
                        Expanded(
                          child: DsButton(
                            tone: DsButtonTone.outline,
                            height: 48,
                            fontSize: 15,
                            icon: Icons.close_rounded,
                            label: 'Decline',
                            onPressed: () => service.declineStop(s.stopId),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: DsButton(
                            height: 48,
                            fontSize: 15,
                            icon: Icons.check_rounded,
                            label: 'Add to route',
                            onPressed: () => service.acceptStop(s.stopId),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
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

/// 18 px timeline dot: a 4 px ring on the card, or [fill]ed solid.
class _RouteDot extends StatelessWidget {
  final Color ring;
  final Color? fill;
  const _RouteDot({required this.ring, this.fill});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill ?? AppTheme.card,
        border: Border.all(color: ring, width: 4),
      ),
    );
  }
}

/// One entry of the vertical route timeline: ring dot and a 3 px rail on
/// the left, name 15/800 and detail 13/600, optional chip, trailing and
/// extra lines under the detail (arrivals, "waiting for signal").
class _TimelineRow extends StatelessWidget {
  final Color ring;
  final Color? fill;
  final String title;
  final Color? titleColor;
  final String subtitle;
  final Widget? chip;
  final Widget? trailing;
  final List<Widget> extra;
  final bool last;

  const _TimelineRow({
    required this.ring,
    this.fill,
    required this.title,
    this.titleColor,
    required this.subtitle,
    this.chip,
    this.trailing,
    this.extra = const [],
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = chip;
    final t = trailing;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 22,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _RouteDot(ring: ring, fill: fill),
                ),
                if (!last) Expanded(child: Center(child: Container(width: 3, color: AppTheme.border2))),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(0, 8, 0, last ? 8 : 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: titleColor ?? AppTheme.text, fontSize: 15, fontWeight: FontWeight.w800, height: 1.25),
                        ),
                      ),
                      if (c != null) ...[const SizedBox(width: 8), c],
                    ],
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(subtitle, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.label),
                  ],
                  ...extra,
                ],
              ),
            ),
          ),
          if (t != null) Center(child: t),
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
  final VoidCallback? onNavigate;

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
    this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    final s = stop;
    final q = queued;
    final kind = StopKind.fromCategory(s.category);
    final details = [
      s.isVisited ? 'Visited' : 'Stop ${index + 1}',
      if (distance.isNotEmpty) distance,
      if (s.plannedDwellMin > 0) 'stay ${s.plannedDwellMin} min',
      if (s.suggestedByName.isNotEmpty) 'added by ${s.suggestedByName}',
    ].join(' · ');
    return _TimelineRow(
      ring: s.isVisited ? AppTheme.accentText : AppTheme.warnText,
      fill: s.isVisited ? AppTheme.brand : null,
      title: s.name.isEmpty ? kind.label : s.name,
      subtitle: details,
      chip: DsChip(stopKindChoiceLabel(kind), warning: !s.isVisited),
      extra: [
        if (arrivals.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Space.s4),
            child: Text(arrivals, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
          ),
        if (q != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.s4),
            child: QueuedLine(what: 'Visited mark', failed: q.state == OutboxState.failed, sending: online),
          ),
      ],
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onNavigate != null)
            IconButton(
              key: Key('stop_navigate_button_${s.stopId}'),
              tooltip: 'Navigate to stop',
              icon: Icon(Icons.navigation_outlined, color: AppTheme.accentText, size: 20),
              onPressed: onNavigate,
            ),
          // One tick control: tap to mark visited, tap again to undo.
          IconButton(
            tooltip: s.isVisited ? 'Mark as not visited' : 'Mark as visited',
            icon: Icon(
              s.isVisited ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
              color: s.isVisited ? AppTheme.accentText : AppTheme.muted,
            ),
            onPressed: () => onVisited(!s.isVisited),
          ),
          if (lead)
            PopupMenuButton<String>(
              tooltip: 'Stop options',
              icon: Icon(Icons.more_vert_rounded, color: AppTheme.muted),
              color: AppTheme.card,
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
    );
  }
}
