import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';

/// What the rider chose on the long-press sheet.
enum MeetHereAction {
  /// Lead: set the group's meeting point here.
  meet,

  /// Lead: add a stop here; anyone else: suggest a stop here.
  addStop,

  /// Anyone: report a rider down at this point (3.16).
  reportDown,
}

/// The rider's choice and the place name shown on the sheet (empty when the
/// name was not found).
class MeetHereResult {
  final MeetHereAction action;
  final String name;
  const MeetHereResult(this.action, this.name);
}

/// Long-press on the ride map: a small sheet with the place name (looked up
/// once, the sheet works without it), how far it is, and the actions. The
/// lead gets "Meet here" (sets the group's meeting point) and "Add a stop
/// here"; everyone else "Suggest a stop here". Every rider also gets
/// "Report a rider down here" (3.16), shown when [canReport].
Future<MeetHereResult?> showMeetHereSheet(
  BuildContext context, {
  required Future<String?> Function() placeName,
  double? distanceFromMeM,
  String? replacesName,
  bool lead = true,
  bool canReport = true,
}) {
  return showAppSheet<MeetHereResult>(
    context,
    isScrollControlled: true,
    builder: (ctx) => MeetHereSheet(
      placeName: placeName,
      distanceFromMeM: distanceFromMeM,
      replacesName: replacesName,
      lead: lead,
      canReport: canReport,
    ),
  );
}

class MeetHereSheet extends StatefulWidget {
  final Future<String?> Function() placeName;
  final double? distanceFromMeM;

  /// Name of the open meeting point this one replaces, if any.
  final String? replacesName;

  /// The lead's actions (meet here, add a stop) or the pack's (suggest a stop).
  final bool lead;

  /// Shows "Report a rider down here".
  final bool canReport;

  const MeetHereSheet({
    super.key,
    required this.placeName,
    this.distanceFromMeM,
    this.replacesName,
    this.lead = true,
    this.canReport = true,
  });

  static const String suggestLabel = 'Suggest a stop here';

  @override
  State<MeetHereSheet> createState() => _MeetHereSheetState();
}

class _MeetHereSheetState extends State<MeetHereSheet> {
  String _name = '';
  bool _looking = true;

  @override
  void initState() {
    super.initState();
    _lookUp();
  }

  Future<void> _lookUp() async {
    String? n;
    try {
      n = await widget.placeName();
    } catch (_) {
      n = null;
    }
    if (!mounted) return;
    setState(() {
      _name = (n ?? '').trim();
      _looking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.distanceFromMeM;
    final old = widget.replacesName;
    final lead = widget.lead;
    final title = _name.isNotEmpty ? _name : (_looking ? 'Finding the place name' : 'This place');
    final facts = <String>[
      if (d != null) '${formatDistanceRounded(d)} from you',
      if (lead && old != null) 'Replaces the meeting point${old.isEmpty ? '' : ' at $old'}',
    ];
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(lead ? StopKind.meeting.icon : Icons.add_location_alt_rounded, color: AppTheme.neonCyan, size: 28),
              const SizedBox(width: Space.s12),
              Expanded(
                child: Semantics(
                  header: true,
                  liveRegion: true,
                  child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
                ),
              ),
            ],
          ),
          if (facts.isNotEmpty) ...[
            const SizedBox(height: Space.s4),
            Text(facts.join('. '), maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.label),
          ],
          const SizedBox(height: Space.s8),
          Text(
            lead ? 'Everyone in the group gets an alert with the distance to it.' : 'The lead decides whether to add the stop.',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption,
          ),
          const SizedBox(height: Space.s16),
          if (lead) ...[
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              onPressed: () => Navigator.of(context).pop(MeetHereResult(MeetHereAction.meet, _name)),
              icon: const Icon(Icons.groups_rounded),
              label: const Text('Meet here', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(height: Space.s12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => Navigator.of(context).pop(MeetHereResult(MeetHereAction.addStop, _name)),
              icon: const Icon(Icons.add_location_alt_rounded),
              label: const Text('Add a stop here', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ] else
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              onPressed: () => Navigator.of(context).pop(MeetHereResult(MeetHereAction.addStop, _name)),
              icon: const Icon(Icons.add_location_alt_rounded),
              label: const Text(MeetHereSheet.suggestLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          if (widget.canReport) ...[
            const SizedBox(height: Space.s12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: StatusColors.critical,
                side: BorderSide(color: StatusColors.critical),
              ),
              onPressed: () => Navigator.of(context).pop(MeetHereResult(MeetHereAction.reportDown, _name)),
              icon: const Icon(Icons.personal_injury_rounded),
              label: Text(L10n.t('report.title'), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ],
      ),
    );
  }
}
