import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/settings_service.dart';

/// The "Data saver" switch (Profile tab), styled like a canvas settings row:
/// teal icon, 15/700 label, 12/600 line under it, switch on the right.
/// Shows nothing when the settings service is not provided (isolated screens
/// in tests).
class DataSaverTile extends StatelessWidget {
  /// Kept for older callers; the tile always uses the normal size now.
  final bool dense;

  /// Hairline under the row (off for the last row of a card).
  final bool divider;

  const DataSaverTile({super.key, this.dense = false, this.divider = true});

  static const String title = 'Data saver';
  static const String subtitle = 'Intercom uses half the data. Positions are sent every 5 seconds instead of every 2.5.';

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService?>();
    if (settings == null) return const SizedBox.shrink();
    return Semantics(
      toggled: settings.lowData,
      child: Container(
        constraints: const BoxConstraints(minHeight: 58),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
        child: Row(
          children: [
            Icon(Icons.data_saver_on_rounded, size: 22, color: AppTheme.accentText),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                  Text(subtitle, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.caption),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch(value: settings.lowData, onChanged: (v) => settings.setLowData(v)),
          ],
        ),
      ),
    );
  }
}
