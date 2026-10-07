import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Round 48 dp map button (recentre, layers, compass, zoom).
///
/// [active] fills it with the primary colour (for example "follow me" is on).
/// [tooltip] is also the screen reader label. A null [onPressed] disables it.
class MapControl extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;

  const MapControl({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  static const double size = 48;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final bg = active ? AppTheme.neonCyan : AppTheme.slateCard;
    final Color fg = active ? Colors.black : (enabled ? AppTheme.textPrimary : AppTheme.textMuted);
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      selected: active,
      label: tooltip,
      excludeSemantics: true,
      onTap: onPressed,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: Material(
          color: bg,
          elevation: 2,
          shadowColor: AppTheme.shadow,
          shape: CircleBorder(side: BorderSide(color: AppTheme.subtleBorder)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, size: 24, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}
