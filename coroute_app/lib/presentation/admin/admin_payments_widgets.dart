import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import 'admin_ui.dart';

// Shared pieces of the "Payments & Plans" tabs, on top of admin_ui.dart.

/// The server's own error message for a failed admin call (shown as is).
String adminErrorOf(Object e) => e is ApiException ? e.message : 'Something went wrong: $e';

/// Body of one tab: pull to refresh, the standard admin content column, a
/// thin progress bar while loading, and an error state with retry when
/// nothing has loaded yet.
class AdminTabBody extends StatelessWidget {
  final bool loading;
  final bool hasData;
  final String? error;
  final Future<void> Function() onRefresh;
  final List<Widget> children;

  const AdminTabBody({
    super.key,
    required this.loading,
    required this.hasData,
    required this.onRefresh,
    required this.children,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final e = error;
    if (!hasData && e != null && !loading) {
      return adminRefresh(
        onRefresh: onRefresh,
        child: AdminScrollFill(child: AdminErrorState(message: e, onRetry: () => onRefresh())),
      );
    }
    return LoadingState(
      loading: loading,
      hasData: hasData,
      child: adminRefresh(
        onRefresh: onRefresh,
        child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= adminWideBreakpoint;
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            children: [
              AdminContent(
                wide: wide,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
              ),
            ],
          );
        }),
      ),
    );
  }
}

/// TEST / LIVE / MANUAL pill of a payment (icon and colour, never colour alone).
class AdminModeBadge extends StatelessWidget {
  final String badge;
  const AdminModeBadge(this.badge, {super.key});

  @override
  Widget build(BuildContext context) {
    switch (badge) {
      case 'TEST':
        return StatusTextChip(icon: Icons.science_outlined, text: 'TEST', color: AppTheme.warnText);
      case 'MANUAL':
        return StatusTextChip(icon: Icons.edit_note_rounded, text: 'MANUAL', color: AppTheme.text2);
      default:
        return StatusTextChip(icon: Icons.bolt_rounded, text: 'LIVE', color: AppTheme.accentText);
    }
  }
}

/// Outlined field decoration of the admin forms.
InputDecoration adminInput(String label, {String? hint, String? helper, String? prefix, String? suffix}) {
  final side = BorderSide(color: AppTheme.border, width: 2);
  return InputDecoration(
    labelText: label,
    hintText: hint,
    helperText: helper,
    helperMaxLines: 3,
    prefixText: prefix,
    suffixText: suffix,
    isDense: true,
    filled: true,
    fillColor: AppTheme.card,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: side),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: side),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppTheme.accentText, width: 2)),
  );
}

/// "Label: value" line of a detail sheet; long values wrap.
class AdminDetailLine extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const AdminDetailLine(this.label, this.value, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 128, child: Text(label, style: AppText.caption.copyWith(fontWeight: FontWeight.w700))),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              value,
              style: AppText.body.copyWith(fontSize: 14, fontWeight: FontWeight.w700, color: color ?? AppTheme.text),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks the admin for a line of text (a reason, or a typed confirmation).
/// [validator] returns the problem to show, or null when the text is fine.
/// Resolves to the trimmed text, or null when cancelled.
Future<String?> adminAskText(
  BuildContext context, {
  required String title,
  String? message,
  required String label,
  String? hint,
  required String confirmLabel,
  bool destructive = false,
  String? Function(String text)? validator,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _AskTextDialog(
      title: title,
      message: message,
      label: label,
      hint: hint,
      confirmLabel: confirmLabel,
      destructive: destructive,
      validator: validator,
    ),
  );
}

class _AskTextDialog extends StatefulWidget {
  final String title;
  final String? message;
  final String label;
  final String? hint;
  final String confirmLabel;
  final bool destructive;
  final String? Function(String text)? validator;

  const _AskTextDialog({
    required this.title,
    required this.message,
    required this.label,
    required this.hint,
    required this.confirmLabel,
    required this.destructive,
    required this.validator,
  });

  @override
  State<_AskTextDialog> createState() => _AskTextDialogState();
}

class _AskTextDialogState extends State<_AskTextDialog> {
  final _ctrl = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _ctrl.text.trim();
    final problem = widget.validator?.call(text);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    return AlertDialog(
      backgroundColor: AppTheme.card,
      title: Text(widget.title, style: AppText.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (m != null) ...[
              Text(m, style: AppText.body.copyWith(color: AppTheme.text2)),
              const SizedBox(height: 14),
            ],
            TextField(
              controller: _ctrl,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              style: AppText.body,
              decoration: adminInput(widget.label, hint: widget.hint).copyWith(errorText: _problem),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: widget.destructive ? AppTheme.sos : AppTheme.brand),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Small stacked label + value used inside list rows (amounts at the right).
class AdminAmount extends StatelessWidget {
  final String value;
  final String? caption;
  final Color? color;

  const AdminAmount(this.value, {super.key, this.caption, this.color});

  @override
  Widget build(BuildContext context) {
    final c = caption;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(value, style: AppText.label.copyWith(color: color ?? AppTheme.text, fontWeight: FontWeight.w800)),
          if (c != null) Text(c, style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
