import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/safety_service.dart';
import '../engagement/rate_and_feedback.dart';
import '../home/ride_start_view.dart';
import '../widgets/emergency_sos_sheet.dart';

/// v3.58 the centre "+" of the bottom bar: every way to start, in one sheet. Emergency is the first row (red,
/// never behind a menu). Each action reuses the existing flow and its gates (safety details, phone check,
/// permissions, bike details): nothing is skipped here.
class QuickActionsSheet extends StatelessWidget {
  /// Switches the shell to Explore (for "Plan a trip").
  final VoidCallback onExplore;
  const QuickActionsSheet({super.key, required this.onExplore});

  static const String title = 'Start something';

  /// Keys of the rows, in order (tests check them).
  static const List<String> rowKeys = ['qa_emergency', 'qa_solo', 'qa_group', 'qa_join', 'qa_plan', 'qa_suggest'];

  static Future<void> show(BuildContext context, {required VoidCallback onExplore}) async {
    final action = await showAppSheet<String>(
      context,
      title: title,
      isScrollControlled: true,
      builder: (ctx) => SingleChildScrollView(child: QuickActionsSheet(onExplore: onExplore)),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'emergency':
        final f = context.read<SafetyService?>()?.lastFix;
        await EmergencySosSheet.show(context, lat: f?.lat ?? 0, lng: f?.lng ?? 0);
      case 'solo':
        await RideStartView.startOfflineSolo(context);
      case 'group':
        await RideStartView.startRide(context);
      case 'join':
        await showJoinRideSheet(context);
      case 'plan':
        onExplore();
      case 'suggest':
        await RateAndFeedback.openFeedback(context, category: FeedbackCategory.other);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The sheet returns the chosen action; the flow runs from the shell's context after the sheet closed.
    void pick(String a) => Navigator.of(context).pop(a);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ActionRow(
          key: Key(rowKeys[0]),
          icon: Icons.sos_rounded,
          title: 'Emergency',
          subtitle: 'Call your contact or 112, share your location, Medical ID',
          danger: true,
          onTap: () => pick('emergency'),
        ),
        const SizedBox(height: Space.s12),
        _ActionRow(key: Key(rowKeys[1]), icon: Icons.signal_cellular_off_rounded, title: 'Start solo ride', subtitle: 'Crash detection and SOS by text. No group or data needed', onTap: () => pick('solo')),
        _ActionRow(key: Key(rowKeys[2]), icon: Icons.groups_rounded, title: 'Start or plan a group ride', subtitle: 'Route, stops and pace. Share the code', onTap: () => pick('group')),
        _ActionRow(key: Key(rowKeys[3]), icon: Icons.key_rounded, title: 'Join with a code', subtitle: 'From the rider who started the ride', onTap: () => pick('join')),
        _ActionRow(key: Key(rowKeys[4]), icon: Icons.explore_rounded, title: 'Plan a trip', subtitle: 'Pick a destination near you', onTap: () => pick('plan')),
        _ActionRow(key: Key(rowKeys[5]), icon: Icons.add_location_alt_outlined, title: 'Suggest a place or ride', subtitle: 'Tell us a destination riders should know', onTap: () => pick('suggest'), divider: false),
        const SizedBox(height: Space.s8),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool danger;
  final bool divider;
  const _ActionRow({super.key, required this.icon, required this.title, required this.subtitle, required this.onTap, this.danger = false, this.divider = true});

  @override
  Widget build(BuildContext context) {
    final fg = danger ? Colors.white : AppTheme.accentText;
    final bg = danger ? AppTheme.sos : AppTheme.tint;
    final body = Row(
      children: [
        Container(width: 48, height: 48, alignment: Alignment.center, decoration: BoxDecoration(color: danger ? Colors.white.withValues(alpha: 0.18) : bg, borderRadius: Radii.mdAll), child: Icon(icon, color: fg, size: 26)),
        const SizedBox(width: Space.s12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(color: danger ? Colors.white : AppTheme.text, fontWeight: danger ? FontWeight.w700 : FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: danger ? Colors.white : AppTheme.text2)),
            ],
          ),
        ),
        Icon(Icons.chevron_right_rounded, color: danger ? Colors.white : AppTheme.muted),
      ],
    );
    if (danger) {
      return Semantics(
        button: true,
        label: '$title. $subtitle',
        excludeSemantics: true,
        child: Material(
          color: AppTheme.sos,
          borderRadius: Radii.lgAll,
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: onTap, child: Padding(padding: const EdgeInsets.all(12), child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 56), child: body))),
        ),
      );
    }
    return Semantics(
      button: true,
      label: '$title. $subtitle',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
          child: body,
        ),
      ),
    );
  }
}
