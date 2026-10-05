import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/timeline_event_model.dart';
import '../../domain/timeline/timeline_text.dart';
import 'member_colors.dart';

/// Filter groups shown as chips above the timeline.
class TimelineFilter {
  final String label;
  final Set<String> types;
  const TimelineFilter(this.label, this.types);

  static const all = TimelineFilter('All', {});
  static const stops = TimelineFilter('Stops', {
    'STOPPED', 'STOP_REACHED', 'STOP_PASSED', 'STOP_ALL_REACHED', 'DESTINATION_REACHED', 'DESTINATION_ALL_REACHED', 'STATUS',
  });
  static const alerts = TimelineFilter('Alerts', {'SOS', 'SEPARATED', 'OFF_ROUTE', 'OFFLINE', 'OVERSPEED'});
  static const riding = TimelineFilter('Riding', {'MOVING', 'CORIDE'});
  static const group = TimelineFilter('Group', {
    'TRIP_STARTED', 'TRIP_PAUSED', 'TRIP_RESUMED', 'TRIP_ENDED', 'JOINED', 'LEFT',
    'STOP_ADDED', 'STOP_SUGGESTED', 'STOP_SKIPPED', 'ROUTE_CHANGED',
  });
  static const values = [all, stops, alerts, riding, group];
}

/// The shared group timeline: who did what, where, when and for how long.
/// Grouped by hour, with member and type filters. Used live (convoy) and
/// after the trip (report).
class TimelineList extends StatefulWidget {
  final List<TimelineEventModel> events;
  final Map<String, Color> colors;
  final Map<String, String> memberNames; // userId -> name, for the member chips
  final void Function(TimelineEventModel e)? onTap;
  final bool newestFirst;
  final Widget? emptyState;

  const TimelineList({
    super.key,
    required this.events,
    required this.colors,
    required this.memberNames,
    this.onTap,
    this.newestFirst = false,
    this.emptyState,
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
  };

  static Color _tone(TimelineEventModel e) {
    switch (e.type) {
      case 'SOS':
        return AppTheme.laserRed;
      case 'SEPARATED':
      case 'OFF_ROUTE':
      case 'OFFLINE':
      case 'OVERSPEED':
        return AppTheme.hyperAmber;
      case 'DESTINATION_REACHED':
      case 'STOP_REACHED':
      case 'STOP_ALL_REACHED':
      case 'DESTINATION_ALL_REACHED':
        return AppTheme.emeraldSafe;
      default:
        return AppTheme.textSecondary;
    }
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
      rows.add(_EventRow(
        event: e,
        nowMs: now,
        color: e.userId != null ? (widget.colors[e.userId] ?? AppTheme.neonCyan) : AppTheme.textMuted,
        icon: _icons[e.type] ?? Icons.circle_outlined,
        tone: _tone(e),
        onTap: widget.onTap == null ? null : () => widget.onTap!(e),
      ));
    }

    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            children: [
              for (final f in TimelineFilter.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(f.label),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                    selectedColor: AppTheme.neonCyan.withOpacity(0.2),
                    labelStyle: TextStyle(color: _filter == f ? AppTheme.neonCyan : AppTheme.textSecondary, fontSize: 12),
                    backgroundColor: AppTheme.slateCard,
                    side: BorderSide(color: AppTheme.subtleBorder),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    showCheckmark: false,
                  ),
                ),
            ],
          ),
        ),
        if (widget.memberNames.length > 1)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                for (final entry in widget.memberNames.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      avatar: CircleAvatar(backgroundColor: widget.colors[entry.key] ?? AppTheme.neonCyan, radius: 6),
                      label: Text(entry.value),
                      selected: _members.contains(entry.key),
                      onSelected: (on) => setState(() => on ? _members.add(entry.key) : _members.remove(entry.key)),
                      selectedColor: (widget.colors[entry.key] ?? AppTheme.neonCyan).withOpacity(0.18),
                      labelStyle: TextStyle(color: AppTheme.textPrimary, fontSize: 12),
                      backgroundColor: AppTheme.slateCard,
                      side: BorderSide(color: AppTheme.subtleBorder),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      showCheckmark: false,
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: rows.isEmpty
              ? (widget.emptyState ??
                  Center(child: Text('Nothing here yet.', style: TextStyle(color: AppTheme.textMuted))))
              : ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 24), children: rows),
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
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Text(text.toUpperCase(), style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
      );
}

class _EventRow extends StatelessWidget {
  final TimelineEventModel event;
  final int nowMs;
  final Color color;
  final IconData icon;
  final Color tone;
  final VoidCallback? onTap;

  const _EventRow({required this.event, required this.nowMs, required this.color, required this.icon, required this.tone, this.onTap});

  @override
  Widget build(BuildContext context) {
    final e = event;
    final time = DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(e.startedAt));
    final detail = TimelineText.detail(e, nowMs: nowMs);
    return InkWell(
      onTap: e.hasPlace ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 44, child: Text(time, style: TextStyle(color: AppTheme.textSecondary, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]))),
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: e.isGroupEntry ? AppTheme.elevatedCard : color.withOpacity(0.18),
                shape: BoxShape.circle,
                border: Border.all(color: e.isGroupEntry ? AppTheme.subtleBorder : color, width: 1.4),
              ),
              child: e.isGroupEntry
                  ? Icon(icon, size: 15, color: AppTheme.textSecondary)
                  : Text(MemberColors.initials(e.userName), style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (!e.isGroupEntry) ...[Icon(icon, size: 14, color: tone), const SizedBox(width: 5)],
                      Expanded(
                        child: Text(TimelineText.title(e, nowMs: nowMs),
                            style: TextStyle(color: AppTheme.textPrimary, fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                      if (e.open)
                        Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: tone.withOpacity(0.18), borderRadius: BorderRadius.circular(4)),
                          child: Text('NOW', style: TextStyle(color: tone, fontSize: 10, fontWeight: FontWeight.bold)),
                        ),
                    ],
                  ),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(detail, style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                  ],
                  if (e.hasPlace && onTap != null)
                    Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Text('Show on map', style: TextStyle(color: AppTheme.neonCyan, fontSize: 11)),
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
