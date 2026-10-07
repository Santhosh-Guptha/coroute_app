import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'ui_tokens.dart';

/// Shown when there is nothing to list yet: icon, title, one line, and up
/// to two actions. Example: "No active ride" with [Start Ride] [Join Ride].
/// Scrolls instead of overflowing on short screens.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final m = message;
    final p = primaryLabel;
    final s = secondaryLabel;
    final actions = <Widget>[
      if (p != null && onPrimary != null)
        FilledButton(
          onPressed: onPrimary,
          style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
          child: Text(p, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      if (s != null && onSecondary != null)
        OutlinedButton(
          onPressed: onSecondary,
          style: OutlinedButton.styleFrom(minimumSize: const Size(120, 48)),
          child: Text(s, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
    ];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.s24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: AppTheme.textMuted),
              const SizedBox(height: Space.s16),
              Semantics(
                header: true,
                child: Text(title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
              ),
              if (m != null && m.isNotEmpty) ...[
                const SizedBox(height: Space.s8),
                Text(
                  m,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(color: AppTheme.textSecondary),
                ),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: Space.s24),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: Space.s12,
                  runSpacing: Space.s12,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
