import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';

// Shared pieces of the admin console, built on the UI kit (Manrope + teal
// canvas) so every admin screen has the same shell (rail or top nav), the
// same KPI tile, the same table card and row, the same search and filter
// row, the same section title and the same status pill.

/// Width from which admin screens show two panes (list and detail) side by
/// side, and from which the section nav is a left rail instead of a top row.
const double adminWideBreakpoint = 840;

/// Widest the admin content gets (the canvas artboard is 1280 px).
const double adminMaxContentWidth = 1280;

/// Width of the left navigation rail on wide screens.
const double adminRailWidth = 240;

/// Padding of the main admin content column (24 px on the canvas, 20 on phones).
EdgeInsets adminContentPadding(bool wide) => wide ? const EdgeInsets.fromLTRB(24, 20, 24, 32) : const EdgeInsets.fromLTRB(20, 12, 20, 28);

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
        return AppTheme.accentText;
      case AccountStatus.onHold:
        return AppTheme.warnText;
      case AccountStatus.blocked:
        return AppTheme.sos;
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

/// The pale fill that goes behind text or a pill of colour [c]: the canvas
/// tint for teal, the warning tint for amber, a 12 % wash for anything else.
Color adminTintOf(Color c) {
  if (c == AppTheme.accentText || c == AppTheme.brand) return AppTheme.tint;
  if (c == AppTheme.warnText) return AppTheme.warnTint;
  if (c == AppTheme.muted || c == AppTheme.text2) return AppTheme.soft;
  return c.withOpacity(0.12);
}

/// Status pill: 12/800 coloured text on its pale tint, radius 7, with an
/// icon (never colour alone). Same look as the canvas table pills.
class StatusTextChip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const StatusTextChip({super.key, required this.icon, required this.text, required this.color});

  /// Chip for an account status ("On hold", "Blocked", "Active").
  factory StatusTextChip.account(AccountStatus s, {Key? key}) => StatusTextChip(key: key, icon: s.icon, text: s.label, color: s.color);

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800, height: 1.2),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: adminTintOf(color), borderRadius: BorderRadius.circular(7)),
      // The chip sits both in a bounded status line (where it must ellipsize)
      // and in a row's trailing slot (unbounded width, where a flex child
      // would assert), so the label is only Flexible when there is a bound.
      child: LayoutBuilder(
        builder: (context, c) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            if (c.hasBoundedWidth) Flexible(child: label) else label,
          ],
        ),
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
    final c = color ?? AppTheme.text2;
    return Row(
      children: [
        Icon(icon, size: 16, color: c),
        const SizedBox(width: 5),
        Flexible(
          child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: c, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

/// Title of a block inside an admin screen (15/800 like the canvas card
/// titles, sentence case), with room for a trailing widget.
class AdminSectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const AdminSectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = trailing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 22, 0, 10),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title),
            ),
          ),
          ?t,
        ],
      ),
    );
  }
}

/// Uppercase 12/800 muted header, used for the column row of a table card
/// and the small label above a KPI value.
class AdminOverline extends StatelessWidget {
  final String text;
  final Color? color;
  final TextAlign? align;

  const AdminOverline(this.text, {super.key, this.color, this.align});

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      style: AppText.overline.copyWith(color: color),
    );
  }
}

/// Plain surface for a group of content: card fill, 2 px border, 18 px corners.
class AdminCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool warning;
  final bool tinted;

  const AdminCard({super.key, required this.child, this.padding = const EdgeInsets.all(Space.s16), this.warning = false, this.tinted = false});

  @override
  Widget build(BuildContext context) {
    return DsCard(padding: padding, warning: warning, tinted: tinted, child: child);
  }
}

/// A card with a title row (title 15/800, optional trailing) and a body.
class AdminTitledCard extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const AdminTitledCard({super.key, required this.title, this.trailing, required this.child, this.padding = const EdgeInsets.all(Space.s16)});

  @override
  Widget build(BuildContext context) {
    final t = trailing;
    return DsCard(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: Semantics(header: true, child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title))),
              ?t,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// KPI tile of the canvas: 12/700 muted label (sentence case, as on the
/// artboard), 32/800 value, a delta or note line in teal (or [deltaColor]).
class AdminKpiTile extends StatelessWidget {
  final String label;
  final String value;
  final String? delta;
  final Color? valueColor;
  final Color? deltaColor;

  const AdminKpiTile({super.key, required this.label, required this.value, this.delta, this.valueColor, this.deltaColor});

  @override
  Widget build(BuildContext context) {
    final d = delta;
    return Semantics(
      label: d == null || d.isEmpty ? '$label: $value' : '$label: $value, $d',
      excludeSemantics: true,
      child: DsCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, maxLines: 1, style: AppText.metric.copyWith(color: valueColor)),
            ),
            if (d != null && d.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                d,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: deltaColor ?? AppTheme.accentText, fontWeight: FontWeight.w700),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Lays [tiles] out in equal-height rows: as many 150 px+ columns as fit
/// (up to six), one column on a narrow phone.
class AdminKpiGrid extends StatelessWidget {
  final List<Widget> tiles;
  final double minTileWidth;
  final double gap;

  const AdminKpiGrid({super.key, required this.tiles, this.minTileWidth = 150, this.gap = 12});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth.isFinite ? c.maxWidth : 600.0;
      final cols = ((w + gap) / (minTileWidth + gap)).floor().clamp(1, 6).toInt();
      final rows = <Widget>[];
      for (var i = 0; i < tiles.length; i += cols) {
        final end = i + cols < tiles.length ? i + cols : tiles.length;
        final chunk = tiles.sublist(i, end);
        rows.add(IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var j = 0; j < cols; j++) ...[
                if (j > 0) SizedBox(width: gap),
                Expanded(child: j < chunk.length ? chunk[j] : const SizedBox.shrink()),
              ],
            ],
          ),
        ));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) SizedBox(height: gap),
            rows[i],
          ],
        ],
      );
    });
  }
}

/// Two cards side by side when there is room, stacked on a phone.
class AdminTwoUp extends StatelessWidget {
  final Widget left;
  final Widget right;
  final double gap;

  const AdminTwoUp({super.key, required this.left, required this.right, this.gap = 16});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= 640) {
        // No IntrinsicHeight: the halves may hold a map or LayoutBuilders.
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Expanded(child: left), SizedBox(width: gap), Expanded(child: right)],
        );
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [left, SizedBox(height: gap), right]);
    });
  }
}

/// Table card of the canvas: 2 px border, an optional title row, an
/// optional uppercase column header, then [rows] (usually [AdminRow]s)
/// separated by hairlines. The last row gets no divider.
class AdminTable extends StatelessWidget {
  final String? title;
  final Widget? trailing;
  final List<String>? columns;
  final List<Widget> rows;
  final Widget? empty;

  const AdminTable({super.key, this.title, this.trailing, this.columns, required this.rows, this.empty});

  @override
  Widget build(BuildContext context) {
    final t = title;
    final tr = trailing;
    final cols = columns;
    final e = empty;
    return DsCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (t != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(child: Semantics(header: true, child: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title))),
                  ?tr,
                ],
              ),
            ),
          if (cols != null && cols.isNotEmpty)
            Container(
              padding: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
              child: Row(
                children: [
                  for (var i = 0; i < cols.length; i++)
                    Expanded(
                      flex: i == 0 ? 2 : 1,
                      child: AdminOverline(cols[i], align: i == cols.length - 1 && cols.length > 1 ? TextAlign.end : TextAlign.start),
                    ),
                ],
              ),
            ),
          if (rows.isEmpty && e != null) Padding(padding: const EdgeInsets.fromLTRB(0, 8, 0, 10), child: e),
          ...rows,
        ],
      ),
    );
  }
}

/// The one list row of the admin console: leading avatar or icon, a title,
/// up to two text lines, an optional status line, an optional trailing
/// widget (menu) and a chevron. At least 52 dp tall, hairline under it,
/// whole row tappable. Lives inside an [AdminTable] or [AdminCard].
class AdminRow extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle;
  final String? detail;
  final Widget? status;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;
  final bool divider;

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
    this.divider = true,
  });

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    final det = detail;
    final st = status;
    final tr = trailing;
    final row = Container(
      constraints: const BoxConstraints(minHeight: 52),
      decoration: BoxDecoration(
        color: selected ? AppTheme.tint : null,
        borderRadius: selected ? BorderRadius.circular(12) : null,
        border: divider && !selected ? Border(bottom: BorderSide(color: AppTheme.border)) : null,
      ),
      padding: EdgeInsets.fromLTRB(selected ? 8 : 0, 10, selected ? 8 : 0, 10),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontSize: 14, fontWeight: FontWeight.w800)),
                if (sub != null && sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                if (det != null && det.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(det, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.label),
                  ),
                if (st != null) Padding(padding: const EdgeInsets.only(top: 6), child: st),
              ],
            ),
          ),
          ?tr,
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return Material(
      color: Colors.transparent,
      child: InkWell(borderRadius: BorderRadius.circular(12), onTap: onTap, child: row),
    );
  }
}

/// Rounded tinted icon tile used as the leading of rows that are not a person.
class AdminRowIcon extends StatelessWidget {
  final IconData icon;
  final Color? color;

  const AdminRowIcon(this.icon, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.accentText;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: adminTintOf(c), borderRadius: BorderRadius.circular(12)),
      child: Icon(icon, color: c, size: 22),
    );
  }
}

/// Small rank tile ("1", "2", …) of the canvas "Top routes" list.
class AdminRankTile extends StatelessWidget {
  final int rank;
  const AdminRankTile(this.rank, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: AppTheme.tint, borderRadius: BorderRadius.circular(8)),
      child: Text('$rank', style: TextStyle(color: AppTheme.accentText, fontSize: 12, fontWeight: FontWeight.w800)),
    );
  }
}

/// A label, a count and a thin bar: the canvas "alerts by type" row.
class AdminBarRow extends StatelessWidget {
  final String label;
  final String value;
  final double fraction;
  final Color? color;

  const AdminBarRow({super.key, required this.label, required this.value, required this.fraction, this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: AppTheme.text, fontWeight: FontWeight.w700))),
              const SizedBox(width: 8),
              Text(value, style: AppText.label.copyWith(fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 5),
          AdminMiniBar(value: fraction, color: color, height: 8),
        ],
      ),
    );
  }
}

/// Thin horizontal bar on a soft track: [value] 0..1 of brand teal (or [color]).
class AdminMiniBar extends StatelessWidget {
  final double value;
  final Color? color;
  final double height;

  const AdminMiniBar({super.key, required this.value, this.color, this.height = 8});

  @override
  Widget build(BuildContext context) {
    final v = value.isNaN ? 0.0 : value.clamp(0.0, 1.0).toDouble();
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: Container(
        height: height,
        color: AppTheme.soft,
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          heightFactor: 1,
          widthFactor: v,
          child: DecoratedBox(decoration: BoxDecoration(color: color ?? AppTheme.brand, borderRadius: BorderRadius.circular(height / 2))),
        ),
      ),
    );
  }
}

/// A 44 px round icon button with a tooltip (so tests and screen readers
/// find it by its label).
class AdminIconAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? iconColor;

  const AdminIconAction({super.key, required this.icon, required this.label, required this.onTap, this.iconColor});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: DsRoundButton(icon: icon, label: label, onTap: onTap, iconColor: iconColor ?? AppTheme.accentText),
    );
  }
}

/// A filter as one compact 44 dp button that opens a menu. [label] is the
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
      color: AppTheme.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: AppTheme.border, width: 2)),
      itemBuilder: (_) => [
        for (final (v, text) in options)
          PopupMenuItem<T>(
            value: v,
            height: 48,
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: v == value ? Icon(Icons.check_rounded, size: 20, color: AppTheme.accentText) : null,
                ),
                Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700))),
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
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppTheme.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.border, width: 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.filter_list_rounded, size: 20, color: AppTheme.accentText),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 112),
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: AppTheme.text, fontWeight: FontWeight.w800)),
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
    final side = BorderSide(color: AppTheme.border, width: 2);
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
              hintStyle: AppText.body.copyWith(color: AppTheme.muted),
              isDense: true,
              filled: true,
              fillColor: AppTheme.card,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: side),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: side),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: AppTheme.accentText, width: 2)),
              prefixIcon: Icon(Icons.search_rounded, color: AppTheme.muted),
              suffixIcon: _ctrl.text.isEmpty
                  ? null
                  : IconButton(tooltip: 'Clear search', icon: Icon(Icons.close_rounded, color: AppTheme.muted), onPressed: _clear),
            ),
          ),
        ),
        if (f != null) ...[const SizedBox(width: 8), f],
      ],
    );
  }
}

/// One entry of the admin section nav (rail on wide screens, chip row on phones).
class AdminNavItem {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final int badge;
  final bool danger;

  const AdminNavItem({required this.icon, required this.label, this.onTap, this.selected = false, this.badge = 0, this.danger = false});
}

/// The admin page frame of the canvas: a left rail (CoRoute mark, "Admin
/// console", section nav, a footer) beside the content on wide screens; on a
/// phone the rail becomes a header row plus a scrolling nav row on top.
/// The content column is at most [adminMaxContentWidth] wide.
///
/// [title] and [subtitle] head the content; [actions] are 44 px round
/// buttons at the right of the header; [onBack] adds a round back button.
/// [body] must handle its own scrolling (it fills the remaining height).
class AdminShell extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final VoidCallback? onBack;
  final List<AdminNavItem> nav;
  final Widget? railFooter;
  final Widget body;

  /// False when the shell is embedded in another scaffold (no SafeArea top).
  final bool primary;

  const AdminShell({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.onBack,
    this.nav = const [],
    this.railFooter,
    required this.body,
    this.primary = true,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      primary: primary,
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        top: primary,
        bottom: false,
        child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= adminWideBreakpoint && nav.isNotEmpty;
          final header = _Header(title: title, subtitle: subtitle, actions: actions, onBack: onBack, showMark: !wide && onBack == null);
          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Rail(nav: nav, footer: railFooter),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(padding: const EdgeInsets.fromLTRB(24, 20, 24, 4), child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: adminMaxContentWidth), child: header))),
                      Expanded(child: body),
                    ],
                  ),
                ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 4), child: header),
              if (nav.isNotEmpty) _NavRow(nav: nav),
              Expanded(child: body),
            ],
          );
        }),
      ),
    );
  }
}

/// Centres [child] in a column no wider than [adminMaxContentWidth] with the
/// standard content padding. For the scroll views inside an [AdminShell].
class AdminContent extends StatelessWidget {
  final Widget child;
  final bool wide;
  const AdminContent({super.key, required this.child, required this.wide});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: adminMaxContentWidth),
        child: Padding(padding: adminContentPadding(wide), child: child),
      ),
    );
  }
}

/// The CoRoute mark: 36 px teal rounded square with the white hub icon.
class AdminBrandMark extends StatelessWidget {
  final double size;
  const AdminBrandMark({super.key, this.size = 36});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: AppTheme.brand, borderRadius: BorderRadius.circular(size * 0.28)),
      child: Icon(Icons.hub_outlined, color: Colors.white, size: size * 0.6),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final VoidCallback? onBack;
  final bool showMark;

  const _Header({required this.title, this.subtitle, required this.actions, this.onBack, required this.showMark});

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    final back = onBack;
    return Row(
      children: [
        if (back != null) ...[
          DsRoundButton(icon: Icons.chevron_left_rounded, label: 'Back', onTap: back),
          const SizedBox(width: 12),
        ] else if (showMark) ...[
          const AdminBrandMark(),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(header: true, child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.headline)),
              if (sub != null && sub.isNotEmpty) ...[
                const SizedBox(height: 1),
                Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
              ],
            ],
          ),
        ),
        for (var i = 0; i < actions.length; i++) ...[
          SizedBox(width: i == 0 ? 12 : 8),
          actions[i],
        ],
      ],
    );
  }
}

class _Rail extends StatelessWidget {
  final List<AdminNavItem> nav;
  final Widget? footer;
  const _Rail({required this.nav, this.footer});

  @override
  Widget build(BuildContext context) {
    final f = footer;
    return Container(
      width: adminRailWidth,
      decoration: BoxDecoration(color: AppTheme.card, border: Border(right: BorderSide(color: AppTheme.border))),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 18),
            child: Row(
              children: [
                const AdminBrandMark(),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('CoRoute Ops', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w800)),
                      Text('Admin console', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final n in nav) Padding(padding: const EdgeInsets.only(bottom: 6), child: _NavTile(item: n)),
              ],
            ),
          ),
          if (f != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppTheme.soft, borderRadius: BorderRadius.circular(12)),
              child: f,
            ),
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  final AdminNavItem item;
  const _NavTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final n = item;
    final fg = n.selected ? AppTheme.accentText : (n.danger ? AppTheme.sos : AppTheme.text);
    return Material(
      color: n.selected ? AppTheme.tint : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: n.onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(n.icon, size: 20, color: fg),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  n.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: fg, fontSize: 14, fontWeight: n.selected ? FontWeight.w800 : FontWeight.w700),
                ),
              ),
              if (n.badge > 0) _Badge(n.badge),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  final List<AdminNavItem> nav;
  const _NavRow({required this.nav});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        children: [
          for (var i = 0; i < nav.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _NavChip(item: nav[i]),
          ],
        ],
      ),
    );
  }
}

class _NavChip extends StatelessWidget {
  final AdminNavItem item;
  const _NavChip({required this.item});

  @override
  Widget build(BuildContext context) {
    final n = item;
    final fg = n.selected ? Colors.white : (n.danger ? AppTheme.sos : AppTheme.text);
    return Material(
      color: n.selected ? AppTheme.brand : AppTheme.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: n.selected ? AppTheme.brand : AppTheme.border, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: n.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(n.icon, size: 18, color: fg),
              const SizedBox(width: 6),
              Text(n.label, style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w800)),
              if (n.badge > 0) ...[const SizedBox(width: 6), _Badge(n.badge)],
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final int count;
  const _Badge(this.count);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: AppTheme.sos, borderRadius: BorderRadius.circular(8)),
      child: Text('$count', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
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

/// Pull to refresh in the brand colour.
Widget adminRefresh({required Future<void> Function() onRefresh, required Widget child}) =>
    RefreshIndicator(color: AppTheme.accentText, backgroundColor: AppTheme.card, onRefresh: onRefresh, child: child);

/// Shows [message] in a snackbar (used when a refresh fails but old data stays).
void adminSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? AppTheme.sos : null,
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
