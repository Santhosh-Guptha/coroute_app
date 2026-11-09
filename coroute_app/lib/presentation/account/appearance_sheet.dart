import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/ui.dart';

/// System, Light or Dark. Opened from Settings.
class AppearanceSheet extends StatelessWidget {
  const AppearanceSheet({super.key});

  static Future<void> show(BuildContext context) => showAppSheet<void>(
        context,
        isScrollControlled: true,
        builder: (_) => const SingleChildScrollView(child: AppearanceSheet()),
      );

  /// One short line for the settings tile.
  static String summary(ThemeController t) {
    switch (t.preference) {
      case ThemePreference.light:
        return 'Light';
      case ThemePreference.dark:
        return 'Dark';
      case ThemePreference.auto:
      case ThemePreference.lightSensor:
      case ThemePreference.system:
        return 'System';
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<ThemeController>();
    final current = t.preference == ThemePreference.light || t.preference == ThemePreference.dark ? t.preference : ThemePreference.system;
    final options = <(ThemePreference, IconData, String, String)>[
      (ThemePreference.system, Icons.brightness_auto_outlined, 'System', 'Follows your phone'),
      (ThemePreference.light, Icons.light_mode_outlined, 'Light', 'Best in sunlight'),
      (ThemePreference.dark, Icons.dark_mode_outlined, 'Dark', 'Easy on the eyes at night'),
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
              const AppSheetHeader(title: 'Appearance'),
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
                        selected: current == options[i].$1,
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

/// One theme choice: icon, title, short hint and a radio mark.
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
                    Text(title, style: AppText.body.copyWith(fontWeight: FontWeight.w500)),
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
