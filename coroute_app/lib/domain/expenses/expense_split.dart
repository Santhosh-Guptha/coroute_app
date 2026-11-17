/// v3.63 trip planning lite: expense split (pure Dart; the gateway, src/expenses.js, is the truth).
///
/// Records riders keep for themselves: what was spent, who paid, who shares it, and the shortest "who pays whom"
/// list. CoRoute never moves money here. Amounts are whole paise inside, shown as plain numbers ("1,250.50").
library;

/// "12.5" / "12.50" / "1,250" -> paise, or null (above 0, at most 2 decimals, at most 10,00,000).
int? parseAmount(String raw) {
  final s = raw.replaceAll(',', '').trim();
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(s)) return null;
  final parts = s.split('.');
  final whole = int.tryParse(parts[0]);
  if (whole == null) return null;
  final frac = parts.length > 1 ? int.parse(parts[1].padRight(2, '0')) : 0;
  final p = whole * 100 + frac;
  if (p < 1 || p > 100000000) return null;
  return p;
}

/// Paise from the gateway's rupee number (12.5 -> 1250).
int paiseOf(Object? v) => v is num ? (v * 100).round() : 0;

/// 125050 -> "1,250.50"; 120000 -> "1,200" (Indian grouping).
String formatAmount(int paise) {
  final neg = paise < 0;
  final p = paise.abs();
  final whole = p ~/ 100;
  final frac = p % 100;
  final digits = whole.toString();
  String grouped;
  if (digits.length <= 3) {
    grouped = digits;
  } else {
    final last3 = digits.substring(digits.length - 3);
    var rest = digits.substring(0, digits.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    grouped = '${parts.join(',')},$last3';
  }
  final f = frac == 0 ? '' : '.${frac.toString().padLeft(2, '0')}';
  return '${neg ? '-' : ''}$grouped$f';
}

/// Equal shares of [amount] among [ids] (sorted ids; the first ones carry the leftover paise, like the gateway).
Map<String, int> equalShares(int amount, List<String> ids) {
  final sorted = [...{...ids}]..sort();
  if (sorted.isEmpty) return const {};
  final base = amount ~/ sorted.length;
  var rest = amount - base * sorted.length;
  return {
    for (final id in sorted) id: base + (rest-- > 0 ? 1 : 0),
  };
}

/// One transfer of the settle-up list.
class Transfer {
  const Transfer(this.from, this.to, this.amount);
  final String from;
  final String to;
  final int amount;
  @override
  bool operator ==(Object other) => other is Transfer && other.from == from && other.to == to && other.amount == amount;
  @override
  int get hashCode => Object.hash(from, to, amount);
  @override
  String toString() => '$from->$to:$amount';
}

/// Net balance per rider (positive = is owed). [expenses]: (paidBy, amount, shares); [settled]: (from, to, amount).
Map<String, int> balances(List<(String, int, Map<String, int>)> expenses, [List<(String, String, int)> settled = const []]) {
  final bal = <String, int>{};
  void add(String id, int v) => bal[id] = (bal[id] ?? 0) + v;
  for (final e in expenses) {
    add(e.$1, e.$2);
    e.$3.forEach((id, s) => add(id, -s));
  }
  for (final s in settled) {
    add(s.$1, s.$3);
    add(s.$2, -s.$3);
  }
  bal.removeWhere((_, v) => v == 0);
  return bal;
}

/// Largest debtor pays largest creditor, repeated (at most n - 1 transfers; same order as the gateway).
List<Transfer> settleUp(Map<String, int> bal) {
  int byAmount(MapEntry<String, int> a, MapEntry<String, int> b) => b.value != a.value ? b.value.compareTo(a.value) : a.key.compareTo(b.key);
  final cred = [for (final e in bal.entries) if (e.value > 0) MapEntry(e.key, e.value)]..sort(byAmount);
  final debt = [for (final e in bal.entries) if (e.value < 0) MapEntry(e.key, -e.value)]..sort(byAmount);
  final c = [for (final e in cred) [e.key, e.value]];
  final d = [for (final e in debt) [e.key, e.value]];
  final out = <Transfer>[];
  var i = 0, j = 0;
  while (i < d.length && j < c.length) {
    final amt = (d[i][1] as int) < (c[j][1] as int) ? d[i][1] as int : c[j][1] as int;
    if (amt > 0) out.add(Transfer(d[i][0] as String, c[j][0] as String, amt));
    d[i][1] = (d[i][1] as int) - amt;
    c[j][1] = (c[j][1] as int) - amt;
    if (d[i][1] == 0) i++;
    if (c[j][1] == 0) j++;
  }
  return out;
}

/// One expense as the gateway lists it.
class ExpenseItem {
  const ExpenseItem({required this.id, required this.what, required this.amount, required this.paidBy, required this.paidByName, required this.mine, required this.shares, required this.createdAt});
  final String id;
  final String what;
  final int amount;
  final String paidBy;
  final String paidByName;
  final bool mine;
  final Map<String, int> shares;
  final int createdAt;

  static ExpenseItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final shares = <String, int>{};
    final raw = j['shares'];
    if (raw is List) {
      for (final s in raw) {
        if (s is Map && s['userId'] != null) shares[s['userId'].toString()] = paiseOf(s['amount']);
      }
    }
    return ExpenseItem(
      id: id,
      what: j['what']?.toString() ?? '',
      amount: paiseOf(j['amount']),
      paidBy: j['paidBy']?.toString() ?? '',
      paidByName: j['paidByName']?.toString() ?? 'Rider',
      mine: j['mine'] == true,
      shares: shares,
      createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The whole ride's expense book.
class ExpenseBook {
  const ExpenseBook({required this.me, required this.canEdit, required this.members, required this.expenses, required this.totalSpent, required this.balances, required this.settleUp, required this.settlements});
  final String me;
  final bool canEdit;

  /// userId -> first name.
  final Map<String, String> members;
  final List<ExpenseItem> expenses;
  final int totalSpent;
  final Map<String, int> balances;
  final List<Transfer> settleUp;

  /// (id, from, to, amount, mine)
  final List<(String, String, String, int, bool)> settlements;

  String nameOf(String id) => id == me ? 'You' : (members[id] ?? 'Rider');

  /// My balance in paise (positive = I get back).
  int get myBalance => balances[me] ?? 0;

  static ExpenseBook fromJson(Map j) {
    final members = <String, String>{};
    final m = j['members'];
    if (m is List) {
      for (final x in m) {
        if (x is Map && x['userId'] != null) members[x['userId'].toString()] = x['name']?.toString() ?? 'Rider';
      }
    }
    Map<String, int> bal = {};
    final b = j['balances'];
    if (b is List) {
      for (final x in b) {
        if (x is Map && x['userId'] != null) bal[x['userId'].toString()] = paiseOf(x['amount']);
      }
    }
    final su = <Transfer>[];
    final s = j['settleUp'];
    if (s is List) {
      for (final x in s) {
        if (x is Map) su.add(Transfer(x['from']?.toString() ?? '', x['to']?.toString() ?? '', paiseOf(x['amount'])));
      }
    }
    final st = <(String, String, String, int, bool)>[];
    final sl = j['settlements'];
    if (sl is List) {
      for (final x in sl) {
        if (x is Map) st.add((x['id']?.toString() ?? '', x['from']?.toString() ?? '', x['to']?.toString() ?? '', paiseOf(x['amount']), x['mine'] == true));
      }
    }
    final ex = j['expenses'];
    return ExpenseBook(
      me: j['me']?.toString() ?? '',
      canEdit: j['canEdit'] != false,
      members: members,
      expenses: [if (ex is List) for (final e in ex) ?ExpenseItem.fromJson(e)],
      totalSpent: paiseOf(j['totalSpent']),
      balances: bal,
      settleUp: su,
      settlements: st,
    );
  }
}
