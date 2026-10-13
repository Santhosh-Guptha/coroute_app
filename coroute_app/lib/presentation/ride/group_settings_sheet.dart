import 'guardian_sheet.dart';
import 'ride_feature_summary.dart';
import 'ride_sheet.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/network_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/network_wire.dart';
import '../../data/models/safety_wire.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/settings_service.dart';

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
    final featureControls = lead && service.isOnline && service.supports(ProtocolFeatures.featurePolicy);

    Widget section({required String title, required String value, required String help, required Widget control}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700))),
                const SizedBox(width: 8),
                Text(value, style: AppText.body.copyWith(fontWeight: FontWeight.w800, color: AppTheme.accentText, fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
            control,
            Text(help, style: AppText.caption),
          ],
        ),
      );
    }

    /// The canvas settings group: a `bg` filled block with 18 dp corners.
    Widget group(List<Widget> children) {
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(color: AppTheme.bg, borderRadius: BorderRadius.circular(Radii.lg)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );
    }

    Widget note(String text, {Color? color, IconData icon = Icons.info_outline_rounded}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: color ?? AppTheme.muted),
            const SizedBox(width: 6),
            Expanded(child: Text(text, style: AppText.caption.copyWith(color: color))),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Ride Guardian Live Link Banner
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: DsHeroCard(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: Colors.white.withOpacity(0.16), borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.shield_rounded, color: Colors.white, size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Ride Guardian', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 2),
                            Text(
                              convoy.featurePolicy.guardianEnabled
                                  ? 'Share your personal ride with someone you trust.'
                                  : 'Guardian links are disabled for this group.',
                              style: const TextStyle(color: DsHeroCard.secondary, fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  DsButton(
                    key: const Key('group_settings_guardian_share_btn'),
                    label: 'Share with a Ride Guardian',
                    icon: Icons.share_rounded,
                    tone: DsButtonTone.onHero,
                    height: 48,
                    fontSize: 15,
                    onPressed: convoy.featurePolicy.guardianEnabled ? () => showGuardianSheet(context, groupId: convoyId) : null,
                  ),
                ],
              ),
            ),
          ),

          RideFeatureSummary(groupId: convoyId),
          const SizedBox(height: Space.s12),

          // 2. Ride Feature Controls
          SheetSectionTitle('Ride feature controls'),
          if (!service.supports(ProtocolFeatures.featurePolicy))
            note('Connect to an updated gateway to change ride features.', color: AppTheme.warnText, icon: Icons.warning_amber_rounded),
          if (!service.isOnline) note('Reconnect to change group settings.', color: AppTheme.warnText, icon: Icons.cloud_off_rounded),
          if (service.lastError != null) note(service.lastError!, color: AppTheme.sos, icon: Icons.error_outline_rounded),
          group([
            for (final entry in const {
              'essentialsEnabled': 'Route essentials',
              'autoDiscovery': 'Automatic essentials refresh',
              'groupFuelEnabled': 'Allow opt-in group fuel estimates',
              'guardianEnabled': 'Allow Ride Guardian links',
              'guardianRequirePin': 'Require PIN on Guardian links',
              'notificationInsights': 'Expanded notification insights',
            }.entries)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(entry.value, style: AppText.body.copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
                value: convoy.featurePolicy.toJson()[entry.key] == true,
                onChanged: featureControls ? (v) => service.updateGroupConfig(featurePolicy: {entry.key: v}) : null,
              ),
          ]),
          const SizedBox(height: 14),
          for (final entry in const {
            'guardianMaxHours': ('Guardian maximum hours', [1, 6, 24, 72, 168, 336]),
            'guardianStopMinutes': ('Guardian stopped warning minutes', [5, 15, 30, 60, 120]),
            'guardianOfflineMinutes': ('Guardian offline warning minutes', [2, 5, 10, 30, 60]),
            'guardianDeviationMinutes': ('Guardian deviation warning minutes', [1, 5, 10, 15, 30]),
          }.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.value.$1, style: AppText.label.copyWith(fontWeight: FontWeight.w700, color: AppTheme.text)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final v in entry.value.$2)
                        ChoiceChip(
                          label: Text('$v'),
                          selected: convoy.featurePolicy.toJson()[entry.key] == v,
                          onSelected: featureControls ? (_) => service.updateGroupConfig(featurePolicy: {entry.key: v}) : null,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          note('Changes apply after server confirmation. Rider consent and emergency safeguards remain in control of each rider.'),
          if (!lead) note('Only the lead can change these.', icon: Icons.lock_outline_rounded),
          const SizedBox(height: 8),

          // 3. Convoy Safety Limits
          SheetSectionTitle('Convoy safety limits'),
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
            DsCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.flag_rounded, size: 22, color: AppTheme.accentText),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      GroupSettingsView.sweeperLine(convoy),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),

          // 4. Alerts & Voice Guidance
          SheetSectionTitle('Audio & guidance alerts'),
          Builder(
            builder: (context) {
              final riderSettings = context.watch<SettingsService?>();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  group([
                    DsSwitchRow(
                      label: 'Spoken alerts',
                      subtitle: 'Separation and emergency warnings are read out.',
                      value: convoy.voiceGuidanceEnabled,
                      onChanged: lead ? (v) => service.updateGroupConfig(voiceGuidanceEnabled: v) : null,
                      divider: riderSettings != null,
                    ),
                    if (riderSettings != null)
                      DsSwitchRow(
                        label: 'Announce all alerts',
                        subtitle: 'Read out all notifications and alerts via voice.',
                        value: riderSettings.voiceAnnounceAllAlerts,
                        onChanged: (v) => riderSettings.setVoiceAnnounceAllAlerts(v),
                        divider: false,
                      ),
                  ]),
                  const SizedBox(height: 14),
                  if (riderSettings != null)
                  section(
                    title: 'Map alert banner duration',
                    value: riderSettings.mapAlertDismissSeconds == 0 ? 'Manual' : '${riderSettings.mapAlertDismissSeconds}s',
                    help: riderSettings.mapAlertDismissSeconds == 0
                        ? 'Manual dismissal only on map HUD.'
                        : 'Auto-dismisses from map after ${riderSettings.mapAlertDismissSeconds}s (remains in notifications).',
                    control: Padding(
                      padding: const EdgeInsets.symmetric(vertical: Space.s8),
                      child: Wrap(
                        spacing: Space.s8,
                        runSpacing: Space.s4,
                        children: [
                          for (final sec in NetworkConstants.mapAlertDismissChoices)
                            ChoiceChip(
                              label: Text(sec == 0 ? 'Manual' : '${sec}s'),
                              selected: riderSettings.mapAlertDismissSeconds == sec,
                              materialTapTargetSize: MaterialTapTargetSize.padded,
                              onSelected: (_) => riderSettings.setMapAlertDismissSeconds(sec),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),

          // 5. Network & Discovery Settings
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

          // 6. Location Status
          const SizedBox(height: 18),
          DsCard(
            tinted: service.isRealGpsActive,
            warning: !service.isRealGpsActive,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  service.isRealGpsActive ? Icons.location_on_rounded : Icons.location_off_rounded,
                  color: service.isRealGpsActive ? AppTheme.accentText : AppTheme.warnText,
                  size: 26,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(service.isRealGpsActive ? 'Sharing my location' : 'Location not shared', style: AppText.title),
                      const SizedBox(height: 2),
                      Text(
                        service.isRealGpsActive
                            ? 'On while you are in this ride. It stops when the ride ends or you leave.'
                            : 'Waiting for GPS. Check that location is on and allowed for CoRoute.',
                        style: AppText.caption.copyWith(color: AppTheme.text2),
                      ),
                    ],
                  ),
                ),
              ],
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
