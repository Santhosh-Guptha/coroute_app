import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'ui_tokens.dart';

/// How urgent an alert is.
///
/// * critical: SOS, accident, unexpected disconnect, extreme separation.
/// * important: a rider stopped, route changed, meeting point changed.
/// * normal: a rider joined, trip update, arrival.
enum AlertTier {
  critical,
  important,
  normal;

  IconData get icon {
    switch (this) {
      case AlertTier.critical:
        return Icons.error_rounded;
      case AlertTier.important:
        return Icons.warning_amber_rounded;
      case AlertTier.normal:
        return Icons.info_outline_rounded;
    }
  }

  Color get color {
    switch (this) {
      case AlertTier.critical:
        return StatusColors.critical;
      case AlertTier.important:
        return StatusColors.warning;
      case AlertTier.normal:
        return StatusColors.info;
    }
  }
}

/// A compact alert banner: icon, title, optional one line, optional action.
///
/// Critical alerts are solid SOS red with white text and are announced by
/// screen readers as they appear. Important ones sit on the amber warnTint
/// with a warnBorder; normal ones are a plain card with a teal icon.
class RideAlert extends StatelessWidget {
  final AlertTier tier;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Shows a close button when set.
  final VoidCallback? onDismiss;

  const RideAlert({
    super.key,
    required this.tier,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final critical = tier == AlertTier.critical;
    final important = tier == AlertTier.important;
    // Canvas status colours: solid SOS red, amber warnTint/warnBorder, plain card.
    final Color bg = critical ? AppTheme.sos : (important ? AppTheme.warnTint : AppTheme.card);
    final Color fg = critical ? StatusColors.onCritical : AppTheme.text;
    final Color sub = critical ? StatusColors.onCritical : AppTheme.text2;
    final Color iconColor = critical ? StatusColors.onCritical : (important ? AppTheme.warnText : AppTheme.accentText);
    final Color border = critical ? AppTheme.sos : (important ? AppTheme.warnBorder : AppTheme.border);
    final Color actionFg = critical ? StatusColors.onCritical : (important ? AppTheme.warnText : AppTheme.accentText);
    final Color actionBg = critical ? Colors.black.withOpacity(0.18) : (important ? AppTheme.card : AppTheme.tint);
    final m = message;
    final action = actionLabel;
    final dismiss = onDismiss;

    return Semantics(
      container: true,
      liveRegion: critical,
      child: Material(
        color: bg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.lgAll,
          side: BorderSide(color: border, width: 2),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(Space.s16, Space.s12, dismiss == null ? Space.s16 : Space.s4, Space.s12),
            child: Row(
              children: [
                Icon(tier.icon, color: iconColor, size: 24),
                const SizedBox(width: Space.s12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(color: fg, fontWeight: FontWeight.w800),
                      ),
                      if (m != null && m.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            m,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.label.copyWith(color: sub),
                          ),
                        ),
                      if (action != null && onAction != null)
                        Padding(
                          padding: const EdgeInsets.only(top: Space.s4),
                          child: TextButton(
                            onPressed: onAction,
                            style: TextButton.styleFrom(
                              foregroundColor: actionFg,
                              backgroundColor: actionBg,
                              minimumSize: const Size(48, 44),
                              padding: const EdgeInsets.symmetric(horizontal: Space.s12),
                              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
                              textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                            ),
                            child: Text(action, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                    ],
                  ),
                ),
                if (dismiss != null)
                  IconButton(
                    onPressed: dismiss,
                    tooltip: 'Dismiss',
                    icon: Icon(Icons.close_rounded, color: sub, size: 20),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
