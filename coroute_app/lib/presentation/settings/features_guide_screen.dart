import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../account/appearance_sheet.dart';
import '../account/edit_profile_screen.dart';
import '../diagnostics/pre_ride_phone_check_screen.dart';
import '../garage/garage_screen.dart';
import '../onboarding/permissions_screen.dart';
import '../ride/fuel_sheet.dart';
import '../safety/safety_settings_screen.dart';
import '../safety/safety_settings_sheet.dart';
import '../subscription/membership_dashboard_screen.dart';
import '../trip_planner/offline_map_manager_screen.dart';
import '../widgets/data_saver_tile.dart';
import 'feature_catalog.dart';

/// Profile > Help > Features guide: every feature in plain words, grouped,
/// searchable, one expandable tile each (what it does, when it works, what it
/// uses, what it shares) with a shortcut to its switch. Content lives in
/// [featureCatalog].
class FeaturesGuideScreen extends StatefulWidget {
  /// The entries to show (tests pass a smaller list).
  final List<FeatureInfo> catalog;

  /// Opens the settings for [SettingsTarget]; null uses the app's screens.
  final void Function(BuildContext context, SettingsTarget target)? onOpenSettings;

  const FeaturesGuideScreen({super.key, this.catalog = featureCatalog, this.onOpenSettings});

  static const Key searchKey = Key('features_guide_search');

  @override
  State<FeaturesGuideScreen> createState() => _FeaturesGuideScreenState();
}

class _FeaturesGuideScreenState extends State<FeaturesGuideScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(SettingsTarget target) {
    final custom = widget.onOpenSettings;
    if (custom != null) {
      custom(context, target);
      return;
    }
    openFeatureSettings(context, target);
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = widget.catalog.where((f) => f.matches(q)).toList();
    final children = <Widget>[];
    for (final g in FeatureGroup.values) {
      final items = shown.where((f) => f.group == g).toList();
      if (items.isEmpty) continue;
      children
        ..add(const SizedBox(height: Space.s24))
        ..add(_GroupHeader(group: g, count: items.length))
        ..add(const SizedBox(height: Space.s8))
        ..add(DsCard(
          padding: EdgeInsets.zero,
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                for (var i = 0; i < items.length; i++)
                  _FeatureTile(
                    key: ValueKey('feature_${items[i].id}'),
                    info: items[i],
                    divider: i < items.length - 1,
                    onOpenSettings: _open,
                  ),
              ],
            ),
          ),
        ));
    }
    if (children.isEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: Space.s32),
        child: Text('No features match "${_query.trim()}"', textAlign: TextAlign.center, style: AppText.label),
      ));
    }

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: dsScreenPadding,
              children: [
                DsScreenHeader(
                  title: 'Features guide',
                  subtitle: 'What each feature does',
                  onBack: () => Navigator.maybePop(context),
                ),
                const SizedBox(height: Space.s16),
                TextField(
                  key: FeaturesGuideScreen.searchKey,
                  controller: _search,
                  style: AppText.body,
                  textInputAction: TextInputAction.search,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Search features',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () {
                              _search.clear();
                              setState(() => _query = '');
                            },
                          ),
                  ),
                ),
                ...children,
                const SizedBox(height: Space.s32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the screen or sheet that holds the switch for [target].
Future<void> openFeatureSettings(BuildContext context, SettingsTarget target) async {
  void push(Widget screen) => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen));
  switch (target) {
    case SettingsTarget.none:
      return;
    case SettingsTarget.riderSettings:
      push(const SafetySettingsScreen());
    case SettingsTarget.rideSafety:
      await SafetySettingsSheet.show(context);
    case SettingsTarget.permissions:
      push(const PermissionsScreen());
    case SettingsTarget.nightMode:
      await AppearanceSheet.show(context);
    case SettingsTarget.fuel:
      await showFuelSheet(context, configure: true);
    case SettingsTarget.dataSaver:
      await showAppSheet<void>(
        context,
        title: DataSaverTile.title,
        builder: (_) => const DataSaverTile(divider: false),
      );
    case SettingsTarget.offlineMaps:
      push(const OfflineMapManagerScreen());
    case SettingsTarget.garage:
      push(const GarageScreen());
    case SettingsTarget.membership:
      push(const MembershipDashboardScreen());
    case SettingsTarget.phoneCheck:
      push(const PreRidePhoneCheckScreen(autoRun: false));
    case SettingsTarget.profile:
      push(const EditProfileScreen());
  }
}

class _GroupHeader extends StatelessWidget {
  final FeatureGroup group;
  final int count;
  const _GroupHeader({required this.group, required this.count});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Row(
        children: [
          Icon(group.icon, size: 20, color: AppTheme.accentText),
          const SizedBox(width: Space.s8),
          Expanded(child: Text(group.label, style: AppText.title)),
          Text('$count', style: AppText.caption),
        ],
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  final FeatureInfo info;
  final bool divider;
  final void Function(SettingsTarget target) onOpenSettings;

  const _FeatureTile({super.key, required this.info, required this.divider, required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
      child: Theme(
        // No extra lines from ExpansionTile; the hairline above is enough.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(info.icon, color: AppTheme.accentText),
          title: Text(info.name, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
          subtitle: Text(info.what, style: AppText.caption),
          iconColor: AppTheme.accentText,
          collapsedIconColor: AppTheme.muted,
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoLine(icon: Icons.schedule_rounded, label: 'When it works', text: info.when),
            const SizedBox(height: Space.s8),
            Text('Affects', style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Space.s4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _ImpactChip(label: 'Battery', impact: info.battery),
                _ImpactChip(label: 'Data', impact: info.data),
              ],
            ),
            const SizedBox(height: Space.s8),
            _InfoLine(icon: Icons.lock_outline_rounded, label: 'Privacy', text: info.privacy),
            if (info.changeHint != null) ...[
              const SizedBox(height: Space.s8),
              _InfoLine(icon: Icons.info_outline_rounded, label: 'Where to change', text: info.changeHint!),
            ],
            if (info.settings != SettingsTarget.none) ...[
              const SizedBox(height: Space.s8),
              TextButton.icon(
                key: ValueKey('feature_settings_${info.id}'),
                onPressed: () => onOpenSettings(info.settings),
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: const Text('Change in settings'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String label;
  final String text;
  const _InfoLine({required this.icon, required this.label, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 16, color: AppTheme.muted),
        ),
        const SizedBox(width: Space.s8),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(text: text),
            ]),
            style: AppText.caption,
          ),
        ),
      ],
    );
  }
}

class _ImpactChip extends StatelessWidget {
  final String label;
  final Impact impact;
  const _ImpactChip({required this.label, required this.impact});

  @override
  Widget build(BuildContext context) {
    final text = '$label: ${impact.label}';
    final high = impact == Impact.high;
    return Semantics(
      label: '$label use ${impact.label}',
      excludeSemantics: true,
      // Own chip (not DsChip): readable caption size, no capitals, scales with text size.
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: high ? AppTheme.warnTint : AppTheme.tint,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          style: AppText.caption.copyWith(
            fontWeight: FontWeight.w700,
            color: high ? AppTheme.warnText : AppTheme.accentText,
          ),
        ),
      ),
    );
  }
}
