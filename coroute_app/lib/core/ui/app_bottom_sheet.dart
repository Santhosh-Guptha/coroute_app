import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'ui_tokens.dart';

/// The one way to open a bottom sheet: same handle, 20 dp top corners,
/// 16 dp side padding, safe area, keyboard-aware, 230 ms open/close.
///
/// [title] adds an [AppSheetHeader]. The [builder] content is placed in a
/// Flexible, so a ListView inside it scrolls instead of overflowing. Use
/// [isScrollControlled] for tall sheets or sheets with text fields. Do not
/// draw your own drag handle inside [builder].
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  String? title,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: enableDrag,
    useSafeArea: true,
    backgroundColor: AppTheme.slateCard,
    shape: const RoundedRectangleBorder(borderRadius: Radii.sheetTop),
    clipBehavior: Clip.antiAlias,
    sheetAnimationStyle: AnimationStyle(duration: Motion.sheet, reverseDuration: Motion.sheet),
    builder: (ctx) {
      final t = title;
      final bottomInset = MediaQuery.viewInsetsOf(ctx).bottom;
      return SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(Space.s16, enableDrag ? 0.0 : Space.s16, Space.s16, Space.s16 + bottomInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (t != null) AppSheetHeader(title: t),
              Flexible(child: builder(ctx)),
            ],
          ),
        ),
      );
    },
  );
}

/// Title row for a sheet: title, optional one-line subtitle, optional
/// trailing widget, optional close button.
class AppSheetHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool showClose;

  const AppSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.showClose = false,
  });

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    final tr = trailing;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
                ),
                if (sub != null && sub.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label),
                  ),
              ],
            ),
          ),
          if (tr != null) ...[const SizedBox(width: Space.s8), tr],
          if (showClose)
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              tooltip: 'Close',
              icon: Icon(Icons.close_rounded, color: AppTheme.textSecondary),
            ),
        ],
      ),
    );
  }
}
