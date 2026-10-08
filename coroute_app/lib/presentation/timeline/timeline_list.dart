import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/timeline_event_model.dart';
import '../../domain/timeline/timeline_text.dart';

/// Filter groups shown as chips above the timeline.
class TimelineFilter {
  final String label;
  final Set<String> types;
  const TimelineFilter(this.label, this.types);

  static const all = TimelineFilter('All', {});
  static const stops = TimelineFilter('Stops', {
    'STOPPED', 'STOP_REACHED', 'STOP_PASSED', 'STOP_ALL_REACHED', 'DESTINATION_REACHED', 'DESTINATION_ALL_REACHED', 'STATUS',
  });
  static const alerts = TimelineFilter('Alerts', {
    'SOS', 'SEPARATED', 'OFF_ROUTE', 'OFFLINE', 'OVERSPEED', 'POSSIBLE_INCIDENT', 'NO_REPLY', 'SOS_RESPONSE', 'CHECK_IN',
  });
  static const riding = TimelineFilter('Riding', {'MOVING', 'CORIDE'});
  static const group = TimelineFilter('Group', {
    'TRIP_STARTED', 'TRIP_PAUSED', 'TRIP_RESUMED', 'TRIP_ENDED', 'JOINED', 'LEFT',
    'STOP_ADDED', 'STOP_SUGGESTED', 'STOP_SKIPPED', 'ROUTE_CHANGED',
  });
  static const values = [all, stops, alerts, riding, group];
}

/// The shared group timeline: who did what, where, when and for how long,
/// in plain words ("Bala stopped for 6 min", "Trip ended"), never raw GPS.
/// Grouped by hour, with one row of type filters plus a "Riders" filter.
/// Used live (convoy) and after the trip (report).
class TimelineList extends StatefulWidget {
  final List<TimelineEventModel> events;
  final Map<String, Color> colors;
  final Map<String, String> memberNames; // userId -> name, for the rider filter
  final void Function(TimelineEventModel e)? onTap;
  final bool newestFirst;
  final Widget? emptyState;

  /// The entry shown as selected (for example the one highlighted on the map).
  final String? selectedEventId;

  /// Lets entries without a place be tapped too (the report shows where the
  /// riders were at that moment).
  final bool tapWithoutPlace;

  const TimelineList({
    super.key,
    required this.events,
    required this.colors,
    required this.memberNames,
    this.onTap,
    this.newestFirst = false,
    this.emptyState,
    this.selectedEventId,
    this.tapWithoutPlace = false,
  });

  @override
  State<TimelineList> createState() => _TimelineListState();
}

class _TimelineListState extends State<TimelineList> {
  TimelineFilter _filter = TimelineFilter.all;
  final Set<String> _members = {};

  static const Map<String, IconData> _icons = {
    'TRIP_STARTED': Icons.play_circle_outline_rounded,
    'TRIP_PAUSED': Icons.pause_circle_outline_rounded,
    'TRIP_RESUMED': Icons.play_circle_outline_rounded,
    'TRIP_ENDED': Icons.flag_rounded,
    'JOINED': Icons.person_add_alt_1_rounded,
    'LEFT': Icons.person_remove_alt_1_rounded,
    'STOPPED': Icons.local_parking_rounded,
    'MOVING': Icons.two_wheeler_rounded,
    'SEPARATED': Icons.call_split_rounded,
    'OFF_ROUTE': Icons.wrong_location_rounded,
    'OFFLINE': Icons.signal_cellular_connected_no_internet_0_bar_rounded,
    'SOS': Icons.sos_rounded,
    'STATUS': Icons.info_outline_rounded,
    'STOP_ADDED': Icons.add_location_alt_rounded,
    'STOP_REACHED': Icons.where_to_vote_rounded,
    'DESTINATION_REACHED': Icons.sports_score_rounded,
    'CORIDE': Icons.people_alt_rounded,
    'STOP_SUGGESTED': Icons.add_comment_rounded,
    'STOP_SKIPPED': Icons.not_interested_rounded,
    'ROUTE_CHANGED': Icons.alt_route_rounded,
    'STOP_PASSED': Icons.fast_forward_rounded,
    'OVERSPEED': Icons.speed_rounded,
    'STOP_ALL_REACHED': Icons.groups_rounded,
    'DESTINATION_ALL_REACHED': Icons.emoji_flags_rounded,
    // 3.14 rider safety.
    'POSSIBLE_INCIDENT': Icons.car_crash_rounded,
    'NO_REPLY': Icons.help_outline_rounded,
    'SOS_RESPONSE': Icons.directions_run_rounded,
    'CHECK_IN': Icons.verified_user_rounded,
  };

  static Color _tone(TimelineEventModel e) {
    switch (e.type) {
      case 'SOS':
      case 'POSSIBLE_INCIDENT':
        return StatusColors.critical;
      case 'NO_REPLY':
      case 'SEPARATED':
      case 'OFF_ROUTE':
      case 'OFFLINE':
      case 'OVERSPEED':
        return StatusColors.warning;
      case 'SOS_RESPONSE':
        return StatusColors.info;
      case 'CHECK_IN':
      case 'DESTINATION_REACHED':
      case 'STOP_REACHED':
      case 'STOP_ALL_REACHED':
      case 'DESTINATION_ALL_REACHED':
        return StatusColors.success;
      default:
        return AppTheme.textSecondary;
    }
  }

  void _toggleMember(String id, bool on) {
    if (!mounted) return;
    setState(() => on ? _members.add(id) : _members.remove(id));
  }

  Future<void> _pickRiders() async {
    await showAppSheet<void>(
      context,
      title: 'Show riders',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_members.isEmpty ? 'Showing everyone. Pick riders to see only them.' : 'Showing ${_members.length} of ${widget.memberNames.length} riders.',
                  style: AppText.label),
              const SizedBox(height: Space.s12),
              Wrap(
                spacing: Space.s8,
                runSpacing: Space.s8,
                children: [
                  for (final entry in widget.memberNames.entries)
                    FilterChip(
                      avatar: RiderAvatar(name: entry.value, color: widget.colors[entry.key], size: 24),
                      label: Text(entry.value, maxLines: 1, overflow: TextOverflow.ellipsis),
                      selected: _members.contains(entry.key),
                      onSelected: (on) {
                        _toggleMember(entry.key, on);
                        setSheet(() {});
                      },
                      selectedColor: (widget.colors[entry.key] ?? AppTheme.neonCyan).withOpacity(0.18),
                      labelStyle: AppText.label.copyWith(color: AppTheme.textPrimary),
                      backgroundColor: AppTheme.slateCard,
                      side: BorderSide(color: AppTheme.subtleBorder),
                      shape: const RoundedRectangleBorder(borderRadius: Radii.smAll),
                      showCheckmark: true,
                      checkmarkColor: AppTheme.textPrimary,
                    ),
                ],
              ),
              const SizedBox(height: Space.s16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _members.isEmpty
                          ? null
                          : () {
                              if (mounted) setState(_members.clear);
                              setSheet(() {});
                            },
                      child: const Text('Everyone', maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  const SizedBox(width: Space.s12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Done', maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var list = widget.events.where((e) {
      if (_filter.types.isNotEmpty && !_filter.types.contains(e.type)) return false;
      if (_members.isNotEmpty && (e.userId == null || !_members.contains(e.userId))) return false;
      return true;
    }).toList();
    if (widget.newestFirst) list = list.reversed.toList();

    final rows = <Widget>[];
    String? lastHeader;
    final dayFmt = DateFormat('EEE d MMM');
    final hourFmt = DateFormat('HH:00');
    for (final e in list) {
      final t = DateTime.fromMillisecondsSinceEpoch(e.startedAt);
      final header = '${dayFmt.format(t)}, ${hourFmt.format(t)}';
      if (header != lastHeader) {
        rows.add(_HourHeader(header));
        lastHeader = header;
      }
      final tappable = widget.onTap != null && (e.hasPlace || widget.tapWithoutPlace);
      rows.add(_EventRow(
        key: ValueKey(e.eventId),
        event: e,
        nowMs: now,
        color: e.userId != null ? (widget.colors[e.userId] ?? AppTheme.neonCyan) : AppTheme.textMuted,
        icon: _icons[e.type] ?? Icons.circle_outlined,
        tone: _tone(e),
        selected: widget.selectedEventId != null && widget.selectedEventId == e.eventId,
        onTap: tappable ? () => widget.onTap!(e) : null,
      ));
    }

    final riderCount = _members.length;
    return Column(
      children: [
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Space.s12, vertical: Space.s4),
            children: [
              for (final f in TimelineFilter.values)
                Padding(
                  padding: const EdgeInsets.only(right: Space.s8),
                  child: ChoiceChip(
                    label: Text(f.label),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                    selectedColor: AppTheme.neonCyan.withOpacity(0.2),
                    labelStyle: AppText.label.copyWith(color: _filter == f ? AppTheme.neonCyan : AppTheme.textSecondary),
                    backgroundColor: AppTheme.slateCard,
                    side: BorderSide(color: _filter == f ? AppTheme.neonCyan : AppTheme.subtleBorder),
                    shape: const RoundedRectangleBorder(borderRadius: Radii.smAll),
                    showCheckmark: false,
                  ),
                ),
              if (widget.memberNames.length > 1)
                ActionChip(
                  avatar: Icon(Icons.people_alt_rounded, size: 18, color: riderCount > 0 ? AppTheme.neonCyan : AppTheme.textSecondary),
                  label: Text(riderCount > 0 ? 'Riders ($riderCount)' : 'Riders'),
                  tooltip: 'Choose which riders to show',
                  onPressed: _pickRiders,
                  labelStyle: AppText.label.copyWith(color: riderCount > 0 ? AppTheme.neonCyan : AppTheme.textSecondary),
                  backgroundColor: riderCount > 0 ? AppTheme.neonCyan.withOpacity(0.2) : AppTheme.slateCard,
                  side: BorderSide(color: riderCount > 0 ? AppTheme.neonCyan : AppTheme.subtleBorder),
                  shape: const RoundedRectangleBorder(borderRadius: Radii.smAll),
                ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? (widget.emptyState ??
                  EmptyState(
                    icon: Icons.timeline_rounded,
                    title: 'Nothing here yet',
                    message: _filter == TimelineFilter.all && _members.isEmpty ? null : 'Try another filter.',
                  ))
              : ListView(padding: const EdgeInsets.fromLTRB(Space.s12, Space.s4, Space.s12, Space.s24), children: rows),
        ),
      ],
    );
  }
}

class _HourHeader extends StatelessWidget {
  final String text;
  const _HourHeader(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.s4, Space.s16, Space.s4, Space.s4),
        child: Semantics(
          header: true,
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: AppTheme.textMuted)),
        ),
      );
}

class _EventRow extends StatelessWidget {
  final TimelineEventModel event;
  final int nowMs;
  final Color color;
  final IconData icon;
  final Color tone;
  final bool selected;
  final VoidCallback? onTap;

  const _EventRow({
    super.key,
    required this.event,
    required this.nowMs,
    required this.color,
    required this.icon,
    required this.tone,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final e = event;
    final time = DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(e.startedAt));
    final detail = TimelineText.detail(e, nowMs: nowMs);
    final Color? bg = selected ? AppTheme.neonCyan.withOpacity(0.12) : null;
    return Material(
      color: bg ?? Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: Radii.mdAll,
        side: selected ? BorderSide(color: AppTheme.neonCyan) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.s8, horizontal: Space.s4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 48,
                  child: Padding(
                    padding: const EdgeInsets.only(top: Space.s8),
                    child: Text(time, maxLines: 1, style: AppText.caption.copyWith(color: AppTheme.textSecondary, fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                ),
                e.isGroupEntry
                    ? Container(
                        width: 32,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppTheme.elevatedCard,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppTheme.subtleBorder, width: 1.4),
                        ),
                        child: Icon(icon, size: 16, color: AppTheme.textSecondary),
                      )
                    : RiderAvatar(name: e.userName, color: color, size: 32),
                const SizedBox(width: Space.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!e.isGroupEntry) ...[
                            Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 16, color: tone)),
                            const SizedBox(width: Space.s4),
                          ],
                          Expanded(
                            child: Text(
                              TimelineText.title(e, nowMs: nowMs),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.body.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (e.open)
                            Container(
                              margin: const EdgeInsets.only(left: Space.s4),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: tone.withOpacity(0.18), borderRadius: Radii.smAll),
                              child: Text('NOW', style: AppText.caption.copyWith(color: tone, fontWeight: FontWeight.w700)),
                            ),
                        ],
                      ),
                      if (detail.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(detail, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.textSecondary)),
                      ],
                      if (onTap != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.map_rounded, size: 14, color: AppTheme.neonCyan),
                            const SizedBox(width: Space.s4),
                            Flexible(
                              child: Text(
                                selected ? 'Shown on the map' : 'Show on map',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.caption.copyWith(color: AppTheme.neonCyan, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ]),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
