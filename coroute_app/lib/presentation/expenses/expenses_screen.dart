import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/realtime_service.dart';
import '../../domain/expenses/expense_split.dart';

/// v3.63 trip planning lite: the ride's shared expenses (gateway src/expenses.js).
///
/// Records only: what was spent, who paid, who shares it, and "who pays whom" to square up. CoRoute never moves money.
/// Open from the ride sheet during the ride and from the trip report afterwards (30 days to add and settle).
class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key, required this.groupId, this.rideName = ''});

  final String groupId;
  final String rideName;

  static Future<void> open(BuildContext context, {required String groupId, String rideName = ''}) {
    return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExpensesScreen(groupId: groupId, rideName: rideName)));
  }

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  ExpenseBook? _book;
  String? _error;
  bool _loading = true;
  final Set<String> _busy = {};
  StreamSubscription<Map<String, dynamic>>? _sub;

  String get _base => '/convoys/${Uri.encodeComponent(widget.groupId)}/expenses';

  @override
  void initState() {
    super.initState();
    _load();
    // Another rider added or settled something: reload (the room event carries no amounts).
    _sub = context.read<RealtimeService?>()?.events.listen((e) {
      if (e['type'] == 'EXPENSES_CHANGED' && mounted) _load(quiet: true);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = true);
    try {
      final res = await context.read<ApiClient>().get(_base);
      if (!mounted) return;
      setState(() {
        _book = res is Map ? ExpenseBook.fromJson(res) : null;
        _error = null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the expenses. Check your connection.';
        _loading = false;
      });
    }
  }

  /// Runs one change at a time per [key] (a double tap does nothing the second time).
  Future<void> _act(String key, Future<void> Function() fn, {String? done}) async {
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    HapticFeedback.selectionClick();
    try {
      await fn();
      if (done != null && mounted) _toast(done);
      await _load(quiet: true);
    } on ApiException catch (e) {
      if (mounted) _toast(e.message);
    } catch (_) {
      if (mounted) _toast('That did not go through. Try again.');
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  void _toast(String text) {
    final m = ScaffoldMessenger.maybeOf(context);
    m?.clearSnackBars();
    m?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  Future<void> _edit([ExpenseItem? item]) async {
    final book = _book;
    if (book == null || !book.canEdit) return;
    final body = await showAppSheet<Map<String, Object>>(
      context,
      isScrollControlled: true,
      title: item == null ? 'Add an expense' : 'Edit expense',
      builder: (_) => _ExpenseForm(book: book, item: item),
    );
    if (body == null || !mounted) return;
    final api = context.read<ApiClient>();
    await _act(item == null ? 'add' : 'edit_${item.id}', () async {
      if (item == null) {
        await api.post(_base, body);
      } else {
        await api.put('$_base/${item.id}', body);
      }
    }, done: item == null ? 'Expense added' : 'Expense saved');
  }

  Future<void> _delete(ExpenseItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this expense?'),
        content: Text('${item.what} · ${formatAmount(item.amount)}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final api = context.read<ApiClient>();
    await _act('del_${item.id}', () => api.delete('$_base/${item.id}'), done: 'Expense deleted');
  }

  Future<void> _markPaid(Transfer t) async {
    final book = _book;
    if (book == null) return;
    final api = context.read<ApiClient>();
    await _act('settle_${t.from}_${t.to}', () => api.post('$_base/settle', {'from': t.from, 'to': t.to, 'amount': t.amount / 100}),
        done: '${book.nameOf(t.from)} paid ${book.nameOf(t.to)} back');
  }

  Future<void> _undoSettle(String id) async {
    final api = context.read<ApiClient>();
    await _act('undo_$id', () => api.delete('$_base/settle/$id'), done: 'Paid-back record removed');
  }

  @override
  Widget build(BuildContext context) {
    final book = _book;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(title: Text(widget.rideName.isEmpty ? 'Ride expenses' : 'Expenses · ${widget.rideName}', maxLines: 1, overflow: TextOverflow.ellipsis)),
      floatingActionButton: book != null && book.canEdit
          ? FloatingActionButton.extended(
              key: const Key('expenses_add'),
              onPressed: _busy.contains('add') ? null : () => _edit(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add expense'),
            )
          : null,
      body: _loading && book == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => _load(quiet: true),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                children: [
                  if (_error != null && book == null) DsCard(child: Text(_error!, style: AppText.body)),
                  if (book != null) ..._content(book),
                ],
              ),
            ),
    );
  }

  List<Widget> _content(ExpenseBook book) {
    final mine = book.myBalance;
    final balanceText = mine > 0 ? 'You get back ${formatAmount(mine)}' : (mine < 0 ? 'You owe ${formatAmount(-mine)}' : 'You are all square');
    return [
      Row(children: [
        Expanded(child: DsStatCell(label: 'Spent on this ride', value: formatAmount(book.totalSpent))),
        const SizedBox(width: 10),
        Expanded(child: DsStatCell(label: 'You', value: balanceText, valueColor: mine < 0 ? AppTheme.warnText : (mine > 0 ? AppTheme.primary : null))),
      ]),
      if (!book.canEdit) ...[
        const SizedBox(height: 10),
        Text('This ride ended more than 30 days ago: the list can be read, not changed.', style: AppText.caption),
      ],
      const SizedBox(height: 16),
      DsSectionHeader('Square up'),
      const SizedBox(height: 6),
      if (book.settleUp.isEmpty)
        Text(book.expenses.isEmpty ? 'Add what the group spends: fuel, food, tolls, stays.' : 'Everyone is square.', style: AppText.body)
      else
        DsCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            for (final t in book.settleUp)
              DsListRow(
                icon: Icons.swap_horiz_rounded,
                label: '${book.nameOf(t.from)} pays ${book.nameOf(t.to)}',
                value: formatAmount(t.amount),
                trailing: book.canEdit && (t.from == book.me || t.to == book.me)
                    ? TextButton(
                        key: Key('expenses_paid_${t.from}_${t.to}'),
                        onPressed: _busy.contains('settle_${t.from}_${t.to}') ? null : () => _markPaid(t),
                        child: const Text('Paid back'),
                      )
                    : null,
                divider: t != book.settleUp.last,
              ),
          ]),
        ),
      const SizedBox(height: 16),
      DsSectionHeader('Expenses'),
      const SizedBox(height: 6),
      if (book.expenses.isEmpty) Text('Nothing added yet.', style: AppText.caption),
      for (final e in book.expenses)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: DsCard(
            onTap: e.mine && book.canEdit ? () => _edit(e) : null,
            semanticsLabel: '${e.what}, ${formatAmount(e.amount)}, paid by ${book.nameOf(e.paidBy)}',
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e.what, style: AppText.title.copyWith(fontSize: 16), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text('Paid by ${book.nameOf(e.paidBy)} · shared by ${e.shares.length}', style: AppText.caption),
                ]),
              ),
              Text(formatAmount(e.amount), style: AppText.title.copyWith(fontSize: 16)),
              if (e.mine && book.canEdit)
                IconButton(
                  tooltip: 'Delete',
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  onPressed: _busy.contains('del_${e.id}') ? null : () => _delete(e),
                  icon: Icon(Icons.delete_outline_rounded, color: AppTheme.textMuted),
                ),
            ]),
          ),
        ),
      if (book.settlements.isNotEmpty) ...[
        const SizedBox(height: 12),
        DsSectionHeader('Paid back'),
        const SizedBox(height: 6),
        for (final s in book.settlements)
          DsListRow(
            icon: Icons.check_circle_outline_rounded,
            label: '${book.nameOf(s.$2)} paid ${book.nameOf(s.$3)}',
            value: formatAmount(s.$4),
            trailing: s.$5 && book.canEdit
                ? IconButton(
                    tooltip: 'Undo',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    onPressed: _busy.contains('undo_${s.$1}') ? null : () => _undoSettle(s.$1),
                    icon: Icon(Icons.undo_rounded, color: AppTheme.textMuted),
                  )
                : null,
          ),
      ],
      const SizedBox(height: 12),
      Text('A record for the group only. CoRoute does not send or collect money.', style: AppText.caption),
    ];
  }
}

/// Add / edit form: what, amount, who paid, split equally among chosen riders or custom amounts.
class _ExpenseForm extends StatefulWidget {
  const _ExpenseForm({required this.book, this.item});
  final ExpenseBook book;
  final ExpenseItem? item;

  @override
  State<_ExpenseForm> createState() => _ExpenseFormState();
}

class _ExpenseFormState extends State<_ExpenseForm> {
  static const List<String> quick = ['Fuel', 'Food', 'Toll', 'Stay', 'Parking', 'Repair'];
  late final TextEditingController _what = TextEditingController(text: widget.item?.what ?? '');
  late final TextEditingController _amount = TextEditingController(text: widget.item == null ? '' : (widget.item!.amount / 100).toStringAsFixed(widget.item!.amount % 100 == 0 ? 0 : 2));
  late String _paidBy = widget.item?.paidBy ?? widget.book.me;
  late final Set<String> _among = widget.item == null ? widget.book.members.keys.toSet() : widget.item!.shares.keys.toSet();
  bool _custom = false;
  final Map<String, TextEditingController> _shares = {};
  String? _error;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    if (item != null) {
      final eq = equalShares(item.amount, item.shares.keys.toList());
      _custom = !eq.entries.every((e) => item.shares[e.key] == e.value);
    }
    for (final id in widget.book.members.keys) {
      final v = item?.shares[id];
      _shares[id] = TextEditingController(text: v == null ? '' : (v / 100).toStringAsFixed(v % 100 == 0 ? 0 : 2));
    }
  }

  @override
  void dispose() {
    _what.dispose();
    _amount.dispose();
    for (final c in _shares.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (_sent) return; // one save per tap
    final what = _what.text.trim();
    final amount = parseAmount(_amount.text);
    String? err;
    if (what.isEmpty) err = 'Say what it was for.';
    if (err == null && amount == null) err = 'Enter an amount above 0 (up to 2 decimals).';
    Map<String, Object>? split;
    if (err == null) {
      if (_custom) {
        final shares = <String, Object>{};
        var sum = 0;
        for (final e in _shares.entries) {
          final t = e.value.text.trim();
          if (t.isEmpty || t == '0') continue;
          final p = parseAmount(t);
          if (p == null) {
            err = 'Shares must be amounts (up to 2 decimals).';
            break;
          }
          sum += p;
          shares[e.key] = p / 100;
        }
        if (err == null && shares.isEmpty) err = 'Give at least one share.';
        if (err == null && sum != amount) err = 'The shares add up to ${formatAmount(sum)}, not ${formatAmount(amount!)}.';
        split = {'mode': 'custom', 'shares': shares};
      } else {
        if (_among.isEmpty) err = 'Choose who shares it.';
        split = {'mode': 'equal', 'among': _among.toList()};
      }
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    _sent = true;
    Navigator.of(context).pop(<String, Object>{'what': what, 'amount': amount! / 100, 'paidBy': _paidBy, 'split': split!});
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final ids = book.members.keys.toList()..sort((a, b) => book.nameOf(a).compareTo(book.nameOf(b)));
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final q in quick)
            ChoiceChip(label: Text(q), selected: _what.text == q, onSelected: (_) => setState(() => _what.text = q)),
        ]),
        const SizedBox(height: 10),
        TextField(
          key: const Key('expense_what'),
          controller: _what,
          maxLength: 60,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'What for'),
          onChanged: (_) => setState(() {}),
        ),
        TextField(
          key: const Key('expense_amount'),
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
          decoration: const InputDecoration(labelText: 'Amount'),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: book.members.containsKey(_paidBy) ? _paidBy : null,
          decoration: const InputDecoration(labelText: 'Paid by'),
          items: [for (final id in ids) DropdownMenuItem(value: id, child: Text(book.nameOf(id)))],
          onChanged: (v) => setState(() => _paidBy = v ?? _paidBy),
        ),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Split equally')),
            ButtonSegment(value: true, label: Text('Custom amounts')),
          ],
          selected: {_custom},
          onSelectionChanged: (v) => setState(() => _custom = v.first),
        ),
        const SizedBox(height: 10),
        if (!_custom)
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final id in ids)
              FilterChip(
                label: Text(book.nameOf(id)),
                selected: _among.contains(id),
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onSelected: (on) => setState(() => on ? _among.add(id) : _among.remove(id)),
              ),
          ])
        else
          for (final id in ids)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                Expanded(child: Text(book.nameOf(id), style: AppText.body)),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _shares[id],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                    textAlign: TextAlign.end,
                    decoration: const InputDecoration(hintText: '0'),
                  ),
                ),
              ]),
            ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: AppText.caption.copyWith(color: AppTheme.sos)),
        ],
        const SizedBox(height: 16),
        DsButton(key: const Key('expense_save'), label: widget.item == null ? 'Add' : 'Save', icon: Icons.check_rounded, onPressed: _save),
      ],
    );
  }
}
