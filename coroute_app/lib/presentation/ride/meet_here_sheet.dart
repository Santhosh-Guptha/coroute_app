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

bool _isMeetHereSheetShowing = false;

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
}) async {
  if (_isMeetHereSheetShowing) return null;
  _isMeetHereSheetShowing = true;
  try {
    return await showAppSheet<MeetHereResult>(
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
  } finally {
    _isMeetHereSheetShowing = false;
  }
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
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: AppTheme.tint, borderRadius: BorderRadius.circular(Radii.md)),
                child: Icon(lead ? StopKind.meeting.icon : Icons.add_location_alt_rounded, color: AppTheme.accentText, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      liveRegion: true,
                      child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.headline.copyWith(fontSize: 20)),
                    ),
                    if (facts.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(facts.join('. '), maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.label),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: AppTheme.bg, borderRadius: BorderRadius.circular(Radii.md)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 18, color: AppTheme.accentText),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    lead ? 'Everyone in the group gets an alert with the distance to it.' : 'The lead decides whether to add the stop.',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.label,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (lead) ...[
            DsButton(
              label: 'Meet here',
              icon: Icons.groups_rounded,
              onPressed: () => Navigator.of(context).pop(MeetHereResult(MeetHereAction.meet, _name)),
            ),
            const SizedBox(height: 10),
            DsButton(
              label: 'Add a stop here',
              icon: Icons.add_location_alt_rounded,
              tone: DsButtonTone.outline,
              onPressed: () => Navigator.of(context).pop(MeetHereResult(MeetHereAction.addStop, _name)),
            ),
          ] else
            DsButton(
              label: MeetHereSheet.suggestLabel,
              icon: Icons.add_location_alt_rounded,
              onPressed: () => Navigator.of(context).pop(MeetHereResult(MeetHereAction.addStop, _name)),
            ),
          if (widget.canReport) ...[
            const SizedBox(height: 10),
            _ReportButton(
              label: L10n.t('report.title'),
              onPressed: () => Navigator.of(context).pop(MeetHereResult(MeetHereAction.reportDown, _name)),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Report a rider down here": a 56 dp outline button in SOS red (the kit's
/// outline tone is neutral, so this one is local to the sheet).
class _ReportButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const _ReportButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final Color c = AppTheme.sos;
    return SizedBox(
      height: 56,
      child: Material(
        color: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: c, width: 2)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.personal_injury_rounded, size: 22, color: c),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c, fontSize: 16, fontWeight: FontWeight.w800),
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
