import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'stop_kind.dart';
import 'ui_tokens.dart';

/// A stop as a card row: kind icon, name, one line of detail, trailing
/// widget (distance, a button, a menu). Tappable when [onTap] is set.
class StopCard extends StatelessWidget {
  final StopKind kind;
  final String name;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const StopCard({
    super.key,
    required this.kind,
    required this.name,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    final tr = trailing;
    final title = name.isEmpty ? kind.label : name;
    return Material(
      color: AppTheme.slateCard,
      shape: RoundedRectangleBorder(
        borderRadius: Radii.mdAll,
        side: BorderSide(color: AppTheme.subtleBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.s12, vertical: Space.s8),
            child: Row(
              children: [
                Semantics(
                  label: kind.label,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.neonCyan.withOpacity(0.14),
                    ),
                    child: Icon(kind.icon, size: 22, color: AppTheme.neonCyan),
                  ),
                ),
                const SizedBox(width: Space.s12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                      if (sub != null && sub.isNotEmpty)
                        Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                    ],
                  ),
                ),
                if (tr != null) ...[const SizedBox(width: Space.s8), tr],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
