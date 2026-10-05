import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';

/// Light, dark or automatic. Opened from Account.
class AppearanceSheet extends StatelessWidget {
  const AppearanceSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppTheme.slateCard,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (_) => const AppearanceSheet(),
      );

  /// One line for the Account tile, e.g. "Automatic: dark from 18:02".
  static String summary(ThemeController t) {
    final next = t.nextSunChange;
    final at = next == null ? '' : DateFormat('HH:mm').format(next.toLocal());
    switch (t.preference) {
      case ThemePreference.auto:
        if (at.isEmpty) return 'Automatic, by sunrise and sunset';
        return t.isLight ? 'Automatic: dark from $at' : 'Automatic: light from $at';
      case ThemePreference.lightSensor:
        return 'Follows the light around you';
      case ThemePreference.light:
        return 'Always light';
      case ThemePreference.dark:
        return 'Always dark';
      case ThemePreference.system:
        return 'Same as the phone';
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<ThemeController>();
    final options = <(ThemePreference, IconData, String, String)>[
      (ThemePreference.auto, Icons.wb_twilight_rounded, 'Automatic', 'Light from sunrise to sunset where you are. Works offline.'),
      if (t.sensorSupported)
        (ThemePreference.lightSensor, Icons.light_mode_outlined, 'Light sensor',
            'Follows the light around you. Waits 30 seconds, so tunnels and shade do not flip it.'),
      (ThemePreference.light, Icons.light_mode_rounded, 'Light', 'Easier to read in bright sunlight.'),
      (ThemePreference.dark, Icons.dark_mode_rounded, 'Dark', 'Easier on the eyes at night and saves battery on most phones.'),
      (ThemePreference.system, Icons.phone_android_rounded, 'Same as the phone', 'Uses your phone\'s dark mode setting.'),
    ];

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Appearance', style: TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(summary(t), style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
            const SizedBox(height: 8),
            for (final (pref, icon, title, subtitle) in options)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: Icon(icon, color: t.preference == pref ? AppTheme.neonCyan : AppTheme.textSecondary),
                title: Text(title, style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600, fontSize: 14)),
                subtitle: Text(subtitle, style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                trailing: Icon(
                  t.preference == pref ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                  color: t.preference == pref ? AppTheme.neonCyan : AppTheme.textMuted,
                ),
                onTap: () => t.setPreference(pref),
              ),
          ],
        ),
      ),
    );
  }
}
