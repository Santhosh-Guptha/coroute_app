import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/ui.dart';

/// Light, dark or automatic. Opened from Settings > Night mode.
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
      (ThemePreference.auto, Icons.wb_twilight_outlined, 'Automatic', 'Light from sunrise to sunset where you are. Works offline.'),
      if (t.sensorSupported)
        (ThemePreference.lightSensor, Icons.wb_sunny_outlined, 'Light sensor',
            'Follows the light around you.'),
      (ThemePreference.light, Icons.light_mode_outlined, 'Light', 'Easier to read in bright sunlight.'),
      (ThemePreference.dark, Icons.dark_mode_outlined, 'Dark', 'Easier on the eyes at night. Saves battery.'),
      (ThemePreference.system, Icons.phone_android_outlined, 'Same as the phone', 'Uses your phone\'s dark mode setting.'),
    ];

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Padding(
          padding: const EdgeInsets.only(bottom: Space.s8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppSheetHeader(title: 'Night mode', subtitle: summary(t)),
              DsCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < options.length; i++)
                      _ThemeOptionRow(
                        icon: options[i].$2,
                        title: options[i].$3,
                        subtitle: options[i].$4,
                        selected: t.preference == options[i].$1,
                        divider: i < options.length - 1,
                        onTap: () {
                          t.setPreference(options[i].$1);
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One theme choice: teal icon, title, explanation and a radio mark.
class _ThemeOptionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final bool divider;
  final VoidCallback onTap;

  const _ThemeOptionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.divider,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
          child: Row(
            children: [
              Icon(icon, size: 22, color: AppTheme.accentText),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 1),
                    Text(subtitle, style: AppText.caption),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                size: 24,
                color: selected ? AppTheme.accentText : AppTheme.border2,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
