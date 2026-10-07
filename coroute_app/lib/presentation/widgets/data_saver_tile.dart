import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/settings_service.dart';

/// The "Data saver" switch (Profile tab). Shows nothing when the settings
/// service is not provided (isolated screens in tests).
class DataSaverTile extends StatelessWidget {
  /// Kept for older callers; the tile always uses the normal size now.
  final bool dense;
  const DataSaverTile({super.key, this.dense = false});

  static const String title = 'Data saver';
  static const String subtitle = 'Intercom uses half the data. Positions are sent every 5 seconds instead of every 2.5.';

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService?>();
    if (settings == null) return const SizedBox.shrink();
    return SwitchListTile(
      value: settings.lowData,
      onChanged: (v) => settings.setLowData(v),
      activeColor: AppTheme.neonCyan,
      secondary: Icon(Icons.data_saver_on_rounded, color: AppTheme.textSecondary),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body),
      subtitle: Text(subtitle, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.caption),
    );
  }
}
