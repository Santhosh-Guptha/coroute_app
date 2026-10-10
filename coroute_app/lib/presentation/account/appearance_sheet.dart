import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/constants/network_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/ui.dart';
import '../../data/services/settings_service.dart';

/// Light, dark or automatic. Opened from Account.
class AppearanceSheet extends StatelessWidget {
  const AppearanceSheet({super.key});

  static Future<void> show(BuildContext context) => showAppSheet<void>(
        context,
        isScrollControlled: true,
        builder: (_) => const SingleChildScrollView(child: AppearanceSheet()),
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
        (ThemePreference.lightSensor, Icons.wb_sunny_rounded, 'Light sensor',
            'Follows the light around you. Waits 30 seconds, so tunnels and shade do not flip it.'),
      (ThemePreference.light, Icons.light_mode_rounded, 'Light', 'Easier to read in bright sunlight.'),
      (ThemePreference.dark, Icons.dark_mode_rounded, 'Dark', 'Easier on the eyes at night and saves battery on most phones.'),
      (ThemePreference.system, Icons.phone_android_rounded, 'Same as the phone', 'Uses your phone\'s dark mode setting.'),
    ];

    return Padding(
        padding: const EdgeInsets.only(bottom: Space.s8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(header: true, child: Text('Appearance', style: AppText.title)),
            const SizedBox(height: Space.s4),
            Text(summary(t), style: AppText.caption),
            const SizedBox(height: Space.s8),
            for (final (pref, icon, title, subtitle) in options)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: Space.s4),
                leading: Icon(icon, color: t.preference == pref ? AppTheme.neonCyan : AppTheme.textSecondary),
                title: Text(title, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                subtitle: Text(subtitle, style: AppText.caption),
                trailing: Icon(
                  t.preference == pref ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                  color: t.preference == pref ? AppTheme.neonCyan : AppTheme.textMuted,
                ),
                onTap: () => t.setPreference(pref),
              ),
            Builder(
              builder: (context) {
                final s = context.watch<SettingsService?>();
                if (s == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: Space.s16, left: Space.s4, right: Space.s4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Divider(),
                      const SizedBox(height: Space.s8),
                      Semantics(header: true, child: Text('Map HUD & Alerts', style: AppText.title)),
                      const SizedBox(height: Space.s4),
                      Text(
                        s.mapAlertDismissSeconds == 0
                            ? 'Manual dismissal only on map'
                            : 'Alerts dismiss from map HUD after ${s.mapAlertDismissSeconds}s (kept in notifications)',
                        style: AppText.caption,
                      ),
                      const SizedBox(height: Space.s8),
                      Wrap(
                        spacing: Space.s8,
                        runSpacing: Space.s4,
                        children: [
                          for (final sec in NetworkConstants.mapAlertDismissChoices)
                            ChoiceChip(
                              label: Text(sec == 0 ? 'Manual' : '${sec}s'),
                              selected: s.mapAlertDismissSeconds == sec,
                              onSelected: (_) => s.setMapAlertDismissSeconds(sec),
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
    );
  }
}
