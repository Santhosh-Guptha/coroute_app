import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';

/// What the lead chose on the "Meet here" sheet.
enum MeetHereAction { meet, addStop }

/// The lead's choice and the place name shown on the sheet (empty when the
/// name was not found).
class MeetHereResult {
  final MeetHereAction action;
  final String name;
  const MeetHereResult(this.action, this.name);
}

/// Long-press on the ride map, lead only: a small sheet with the place name
/// (looked up once, the sheet works without it), how far it is, and two
/// actions: "Meet here" (sets the group's meeting point) and "Add a stop
/// here" (the usual stop picker).
Future<MeetHereResult?> showMeetHereSheet(
  BuildContext context, {
  required Future<String?> Function() placeName,
  double? distanceFromMeM,
  String? replacesName,
}) {
  return showAppSheet<MeetHereResult>(
    context,
    isScrollControlled: true,
    builder: (ctx) => MeetHereSheet(placeName: placeName, distanceFromMeM: distanceFromMeM, replacesName: replacesName),
  );
}

class MeetHereSheet extends StatefulWidget {
  final Future<String?> Function() placeName;
  final double? distanceFromMeM;

  /// Name of the open meeting point this one replaces, if any.
  final String? replacesName;

  const MeetHereSheet({super.key, required this.placeName, this.distanceFromMeM, this.replacesName});

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
    final title = _name.isNotEmpty ? _name : (_looking ? 'Finding the place name' : 'This place');
    final facts = <String>[
      if (d != null) '${formatDistanceRounded(d)} from you',
      if (old != null) 'Replaces the meeting point${old.isEmpty ? '' : ' at $old'}',
    ];
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(StopKind.meeting.icon, color: AppTheme.neonCyan, size: 28),
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
          Text('Everyone in the group gets an alert with the distance to it.', maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.caption),
          const SizedBox(height: Space.s16),
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
        ],
      ),
    );
  }
}
