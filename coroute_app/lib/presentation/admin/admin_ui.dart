import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';

// Shared pieces of the admin console, built on the UI kit so every admin
// screen has the same row, the same search and filter row, the same
// section label and the same account status chip.

/// Width from which admin screens show two panes (list and detail) side by side.
const double adminWideBreakpoint = 840;

/// A user account's status on the server: ACTIVE, ON_HOLD or BLOCKED.
enum AccountStatus {
  active,
  onHold,
  blocked;

  static AccountStatus fromCode(Object? code) {
    switch ((code?.toString() ?? '').toUpperCase()) {
      case 'ON_HOLD':
        return AccountStatus.onHold;
      case 'BLOCKED':
        return AccountStatus.blocked;
      default:
        return AccountStatus.active;
    }
  }

  /// The gateway code.
  String get code {
    switch (this) {
      case AccountStatus.active:
        return 'ACTIVE';
      case AccountStatus.onHold:
        return 'ON_HOLD';
      case AccountStatus.blocked:
        return 'BLOCKED';
    }
  }

  String get label {
    switch (this) {
      case AccountStatus.active:
        return 'Active';
      case AccountStatus.onHold:
        return 'On hold';
      case AccountStatus.blocked:
        return 'Blocked';
    }
  }

  IconData get icon {
    switch (this) {
      case AccountStatus.active:
        return Icons.check_circle_rounded;
      case AccountStatus.onHold:
        return Icons.pause_circle_rounded;
      case AccountStatus.blocked:
        return Icons.block_rounded;
    }
  }

  Color get color {
    switch (this) {
      case AccountStatus.active:
        return StatusColors.success;
      case AccountStatus.onHold:
        return StatusColors.warning;
      case AccountStatus.blocked:
        return StatusColors.critical;
    }
  }
}

/// A convoy role in plain words: LEAD "Lead", SWEEP/SWEEPER "Sweep", others "Rider".
String adminRoleLabel(Object? role) {
  switch ((role?.toString() ?? '').toUpperCase()) {
    case 'LEAD':
      return 'Lead';
    case 'SWEEP':
    case 'SWEEPER':
      return 'Sweep';
    default:
      return 'Rider';
  }
}

/// Small chip with icon and text, same look as [RiderStatusChip].
class StatusTextChip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const StatusTextChip({super.key, required this.icon, required this.text, required this.color});

  /// Chip for an account status ("On hold", "Blocked", "Active").
  factory StatusTextChip.account(AccountStatus s, {Key? key}) => StatusTextChip(key: key, icon: s.icon, text: s.label, color: s.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.s8, vertical: Space.s4),
      decoration: ShapeDecoration(
        color: color.withOpacity(0.14),
        shape: StadiumBorder(side: BorderSide(color: color.withOpacity(0.45))),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: Space.s4),
          Flexible(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

/// One line of status text with its icon (never colour alone).
class StatusLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;

  const StatusLine({super.key, required this.icon, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.textSecondary;
    return Row(
      children: [
        Icon(icon, size: 16, color: c),
        const SizedBox(width: Space.s4),
        Flexible(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: c))),
      ],
    );
  }
}

/// Section heading inside an admin screen.
class AdminSectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const AdminSectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = trailing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, Space.s24, 0, Space.s8),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
            ),
          ),
          ?t,
        ],
      ),
    );
  }
}

/// Plain surface for a group of content: card colour, 12 dp corners, thin border.
class AdminCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const AdminCard({super.key, required this.child, this.padding = const EdgeInsets.all(Space.s16)});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppTheme.slateCard,
        borderRadius: Radii.mdAll,
        border: Border.all(color: AppTheme.subtleBorder),
      ),
      child: child,
    );
  }
}

/// The one list row of the admin console: leading avatar or icon, a title,
/// up to two text lines, an optional status line, an optional trailing
/// widget (menu) and a chevron. At least 72 dp tall, whole row tappable.
class AdminRow extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle;
  final String? detail;
  final Widget? status;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;

  const AdminRow({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.detail,
    this.status,
    this.trailing,
    this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    final det = detail;
    final st = status;
    final tr = trailing;
    final border = selected ? AppTheme.neonCyan : AppTheme.subtleBorder;
    return Material(
      color: selected ? Color.alphaBlend(AppTheme.neonCyan.withOpacity(0.10), AppTheme.slateCard) : AppTheme.slateCard,
      shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: EdgeInsets.fromLTRB(Space.s12, Space.s8, onTap == null ? Space.s12 : 0.0, Space.s8),
            child: Row(
              children: [
                leading,
                const SizedBox(width: Space.s12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                      if (sub != null && sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                      if (det != null && det.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(det, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.label),
                        ),
                      if (st != null) Padding(padding: const EdgeInsets.only(top: Space.s4), child: st),
                    ],
                  ),
                ),
                ?tr,
                if (onTap != null)
                  Padding(
                    padding: const EdgeInsets.only(right: Space.s8),
                    child: Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Round tinted icon used as the leading of rows that are not a person.
class AdminRowIcon extends StatelessWidget {
  final IconData icon;
  final Color? color;

  const AdminRowIcon(this.icon, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.neonCyan;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: c.withOpacity(0.14), shape: BoxShape.circle),
      child: Icon(icon, color: c, size: 22),
    );
  }
}

/// A filter as one compact 48 dp button that opens a menu. [label] is the
/// short text of the current choice.
class AdminFilterButton<T> extends StatelessWidget {
  final T value;
  final String label;
  final List<(T, String)> options;
  final ValueChanged<T> onSelected;

  const AdminFilterButton({
    super.key,
    required this.value,
    required this.label,
    required this.options,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: 'Filter',
      initialValue: value,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final (v, text) in options)
          PopupMenuItem<T>(
            value: v,
            height: 48,
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: v == value ? Icon(Icons.check_rounded, size: 20, color: AppTheme.neonCyan) : null,
                ),
                Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body)),
              ],
            ),
          ),
      ],
      child: Semantics(
        button: true,
        label: 'Filter: $label',
        excludeSemantics: true,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          padding: const EdgeInsets.symmetric(horizontal: Space.s12),
          decoration: BoxDecoration(
            color: AppTheme.slateCard,
            borderRadius: Radii.mdAll,
            border: Border.all(color: AppTheme.subtleBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.filter_list_rounded, size: 20, color: AppTheme.textSecondary),
              const SizedBox(width: Space.s4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 112),
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: AppTheme.textPrimary)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Search field and filter button in one row.
class AdminSearchRow extends StatefulWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  final Widget? filter;

  const AdminSearchRow({super.key, required this.hint, required this.onChanged, this.filter});

  @override
  State<AdminSearchRow> createState() => _AdminSearchRowState();
}

class _AdminSearchRowState extends State<AdminSearchRow> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _clear() {
    _ctrl.clear();
    widget.onChanged('');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.filter;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            onChanged: (v) {
              widget.onChanged(v);
              setState(() {});
            },
            style: AppText.body,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: widget.hint,
              hintMaxLines: 1,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: Space.s12, vertical: 14),
              border: const OutlineInputBorder(borderRadius: Radii.mdAll),
              prefixIcon: Icon(Icons.search_rounded, color: AppTheme.textMuted),
              suffixIcon: _ctrl.text.isEmpty
                  ? null
                  : IconButton(tooltip: 'Clear search', icon: const Icon(Icons.close_rounded), onPressed: _clear),
            ),
          ),
        ),
        if (f != null) ...[const SizedBox(width: Space.s8), f],
      ],
    );
  }
}

/// Fills the available height with [child] inside a scroll view, so pull to
/// refresh also works on an empty or error state.
class AdminScrollFill extends StatelessWidget {
  final Widget child;

  const AdminScrollFill({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [SizedBox(height: c.maxHeight.isFinite ? c.maxHeight : 400, child: child)],
      ),
    );
  }
}

/// Error with a retry button, for a screen that has no data yet.
class AdminErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const AdminErrorState({super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.cloud_off_rounded,
      title: 'Could not load',
      message: message,
      primaryLabel: 'Try again',
      onPrimary: onRetry,
    );
  }
}

/// Shows [message] in a snackbar (used when a refresh fails but old data stays).
void adminSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? StatusColors.critical : null,
    ),
  );
}

/// Converts a JSON list of maps into typed maps; anything else gives an empty list.
List<Map<String, dynamic>> adminMapList(Object? list) =>
    list is List ? list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : <Map<String, dynamic>>[];

/// A number from a JSON map, 0 when missing.
num adminNum(Map m, String k) => m[k] is num ? m[k] as num : 0;

/// [s] with its first letter in capitals ("emergency" to "Emergency").
String adminCapitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
