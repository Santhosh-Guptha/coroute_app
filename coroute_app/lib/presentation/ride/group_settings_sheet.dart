import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/convoy_service.dart';

/// Opens the group settings: separation limit, stop alert, speed limit and
/// spoken alerts (the lead changes them, everyone else sees them), and
/// whether my location is being shared.
Future<void> showGroupSettings(BuildContext context, {required String convoyId}) {
  return showAppSheet<void>(
    context,
    title: 'Group settings',
    isScrollControlled: true,
    builder: (_) => GroupSettingsView(convoyId: convoyId),
  );
}

class GroupSettingsView extends StatelessWidget {
  final String convoyId;
  const GroupSettingsView({super.key, required this.convoyId});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ConvoyService>();
    final convoy = service.allConvoys[convoyId];
    if (convoy == null) return const SizedBox.shrink();
    final lead = service.canEditRoute;

    Widget section({required String title, required String value, required String help, required Widget control}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: Space.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600))),
                const SizedBox(width: Space.s8),
                Text(value, style: AppText.body.copyWith(fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
            control,
            Text(help, style: AppText.caption),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!lead)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s12),
              child: Text('Only the lead can change these.', style: AppText.label),
            ),
          section(
            title: 'Too far behind after',
            value: formatDistance(convoy.distanceThresholdMeters),
            help: 'A rider further than this from the group is flagged and told.',
            control: Slider(
              value: convoy.distanceThresholdMeters.clamp(500, 5000).toDouble(),
              min: 500,
              max: 5000,
              divisions: 9,
              label: formatDistance(convoy.distanceThresholdMeters),
              onChanged: lead ? (v) => service.updateGroupConfig(distanceThresholdMeters: v) : null,
            ),
          ),
          section(
            title: 'Stopped alert after',
            value: formatDuration(Duration(seconds: convoy.stopThresholdSeconds)),
            help: 'After this long without moving, the rider is asked why they stopped.',
            control: Slider(
              value: convoy.stopThresholdSeconds.clamp(60, 600).toDouble(),
              min: 60,
              max: 600,
              divisions: 9,
              label: formatDuration(Duration(seconds: convoy.stopThresholdSeconds)),
              onChanged: lead ? (v) => service.updateGroupConfig(stopThresholdSeconds: v.toInt()) : null,
            ),
          ),
          section(
            title: 'Group speed limit',
            value: convoy.speedLimitKmh > 0 ? '${convoy.speedLimitKmh} km/h' : 'Off',
            help: lead
                ? 'When a rider stays over this speed for 10 seconds it is logged on the timeline and everyone is told once.'
                : 'Riding over it is logged on the timeline and the group is told once.',
            control: Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.s8),
              child: Wrap(
                spacing: Space.s8,
                runSpacing: Space.s4,
                children: [
                  for (final v in AppConstants.speedLimitChoices)
                    ChoiceChip(
                      label: Text(v == 0 ? 'Off' : '$v'),
                      selected: convoy.speedLimitKmh == v,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      onSelected: lead ? (_) => service.updateGroupConfig(speedLimitKmh: v) : null,
                    ),
                ],
              ),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Spoken alerts', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            subtitle: Text('Separation and emergency warnings are read out.', style: AppText.caption),
            value: convoy.voiceGuidanceEnabled,
            onChanged: lead ? (v) => service.updateGroupConfig(voiceGuidanceEnabled: v) : null,
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              service.isRealGpsActive ? Icons.location_on_rounded : Icons.location_off_rounded,
              color: service.isRealGpsActive ? StatusColors.success : StatusColors.warning,
            ),
            title: Text(service.isRealGpsActive ? 'Sharing my location' : 'Location not shared', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            subtitle: Text(
              service.isRealGpsActive
                  ? 'On while you are in this ride. It stops when the ride ends or you leave.'
                  : 'Waiting for GPS. Check that location is on and allowed for CoRoute.',
              style: AppText.caption.copyWith(color: AppTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
