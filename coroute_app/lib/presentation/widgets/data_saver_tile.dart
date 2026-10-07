import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/settings_service.dart';

/// The "Data saver" switch (account screen and side menu). Shows nothing when the
/// settings service is not provided (isolated screens in tests).
class DataSaverTile extends StatelessWidget {
  final bool dense;
  const DataSaverTile({super.key, this.dense = false});

  static const String title = 'Data saver';
  static const String subtitle = 'Intercom uses half the data. Positions are sent every 5 seconds instead of every 2.5.';

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService?>();
    if (settings == null) return const SizedBox.shrink();
    return SwitchListTile(
      dense: dense,
      value: settings.lowData,
      onChanged: (v) => settings.setLowData(v),
      activeColor: AppTheme.neonCyan,
      secondary: Icon(Icons.data_saver_on_rounded, color: AppTheme.emeraldSafe, size: dense ? 20 : 24),
      title: Text(title, style: TextStyle(color: AppTheme.textPrimary, fontWeight: dense ? FontWeight.bold : FontWeight.w600, fontSize: dense ? 13 : 14)),
      subtitle: Text(subtitle, style: TextStyle(color: AppTheme.textMuted, fontSize: dense ? 11 : 12)),
    );
  }
}
