import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/network_wire.dart';
import '../../data/models/safety_wire.dart';
import '../../data/services/convoy_service.dart';

/// Opens the group settings: separation limit, stop alert, speed limit,
/// spoken alerts, group visibility (Private / Public), nearby group
/// discovery and the group default for asking nearby riders to help (the
/// lead changes them, everyone else sees them), and whether my location is
/// being shared.
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

  /// Item 13 (3.16): the lower limit near planned stops, the start and the destination.
  static const String townLimitTitle = 'Lower limit near stops and in towns';
  static const String townLimitExplain = 'Within 1 km of planned stops, the start and the destination.';
  static const List<int> townLimitChoices = [0, 30, 40, 50, 60];

  /// "Sweeper: Kiran" or "No sweeper yet (set from a rider's card)" (3.16, item 11).
  static String sweeperLine(ConvoyModel convoy) {
    final id = convoy.sweeperId;
    final name = id == null ? '' : (convoy.riders[id]?.name.trim() ?? '');
    return name.isEmpty ? "No sweeper yet (set from a rider's card)" : 'Sweeper: $name';
  }

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
          if (service.supports(ProtocolFeatures.ride316))
            section(
              title: GroupSettingsView.townLimitTitle,
              value: convoy.townLimitKmh > 0 ? '${convoy.townLimitKmh} km/h' : 'Off',
              help: GroupSettingsView.townLimitExplain,
              control: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.s8),
                child: Wrap(
                  spacing: Space.s8,
                  runSpacing: Space.s4,
                  children: [
                    for (final v in GroupSettingsView.townLimitChoices)
                      ChoiceChip(
                        label: Text(v == 0 ? 'Off' : '$v'),
                        selected: convoy.townLimitKmh == v,
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        onSelected: lead ? (_) => service.updateGroupConfig(townLimitKmh: v) : null,
                      ),
                  ],
                ),
              ),
            ),
          if (service.supports(ProtocolFeatures.ride316))
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s16),
              child: Row(
                children: [
                  Icon(Icons.flag_rounded, size: 20, color: AppTheme.textSecondary),
                  const SizedBox(width: Space.s8),
                  Expanded(
                    child: Text(
                      GroupSettingsView.sweeperLine(convoy),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body,
                    ),
                  ),
                ],
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Spoken alerts', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            subtitle: Text('Separation and emergency warnings are read out.', style: AppText.caption),
            value: convoy.voiceGuidanceEnabled,
            onChanged: lead ? (v) => service.updateGroupConfig(voiceGuidanceEnabled: v) : null,
          ),
          if (service.supports(ProtocolFeatures.safetyNet) || service.supports(ProtocolFeatures.discovery))
            GroupNetworkSettings(
              visibility: convoy.visibility,
              discovery: convoy.discovery,
              assistDefault: convoy.assistDefault,
              lead: lead,
              discoveryAvailable: service.supports(ProtocolFeatures.discovery),
              assistAvailable: service.supports(ProtocolFeatures.safetyNet),
              onChanged: ({GroupVisibility? visibility, bool? discovery, bool? assistDefault}) {
                final ok = service.setGroupVisibility(visibility: visibility, discovery: discovery, assistDefault: assistDefault);
                if (!ok) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not change this now. Try again with signal.')));
                }
              },
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

/// Changes a group network setting.
typedef GroupNetworkChange = void Function({GroupVisibility? visibility, bool? discovery, bool? assistDefault});

/// Group visibility and discovery (SOCIAL, under the group's control) and
/// the group default for nearby assistance (SAFETY, never depends on
/// visibility). The lead changes them; everyone else sees them.
class GroupNetworkSettings extends StatelessWidget {
  final GroupVisibility visibility;
  final bool discovery;
  final bool assistDefault;
  final bool lead;
  final bool discoveryAvailable;
  final bool assistAvailable;
  final GroupNetworkChange onChanged;

  const GroupNetworkSettings({
    super.key,
    required this.visibility,
    required this.discovery,
    required this.assistDefault,
    required this.lead,
    required this.onChanged,
    this.discoveryAvailable = true,
    this.assistAvailable = true,
  });

  static const String visibilityTitle = 'Group visibility';
  static const String discoveryTitle = 'Nearby group discovery';
  static const String discoveryExplain =
      'Only groups that are also Public with discovery on can see your group name and rider count. Never your positions.';
  static const String privateExplain = 'Private: no other group can see this group. Emergency help still works.';
  static const String assistTitle = 'Ask nearby riders to help our riders by default';
  static const String assistExplain =
      'In an accident, riders of other groups who may reach the rider faster can be asked to help. Each rider can change this for themselves.';

  @override
  Widget build(BuildContext context) {
    final public = visibility == GroupVisibility.public;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        if (discoveryAvailable) ...[
          Padding(
            padding: const EdgeInsets.only(top: Space.s8, bottom: Space.s8),
            child: Semantics(header: true, child: Text(visibilityTitle, style: AppText.body.copyWith(fontWeight: FontWeight.w600))),
          ),
          SegmentedButton<GroupVisibility>(
            showSelectedIcon: false,
            style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(0, 48))),
            segments: const [
              ButtonSegment(value: GroupVisibility.private, label: Text('Private', maxLines: 1), icon: Icon(Icons.lock_rounded)),
              ButtonSegment(value: GroupVisibility.public, label: Text('Public', maxLines: 1), icon: Icon(Icons.public_rounded)),
            ],
            selected: {visibility},
            onSelectionChanged: lead
                ? (sel) {
                    final v = sel.first;
                    // Private also turns discovery off: never seen by other groups.
                    onChanged(visibility: v, discovery: v == GroupVisibility.private ? false : null);
                  }
                : null,
          ),
          const SizedBox(height: Space.s4),
          Text(public ? 'Public: other public groups nearby may see your group name and rider count.' : privateExplain, style: AppText.caption),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(discoveryTitle, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            subtitle: Text(discoveryExplain, style: AppText.caption),
            value: public && discovery,
            onChanged: (lead && public) ? (v) => onChanged(discovery: v) : null,
          ),
        ],
        if (assistAvailable)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(assistTitle, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            subtitle: Text(assistExplain, style: AppText.caption),
            value: assistDefault,
            onChanged: lead ? (v) => onChanged(assistDefault: v) : null,
          ),
      ],
    );
  }
}
