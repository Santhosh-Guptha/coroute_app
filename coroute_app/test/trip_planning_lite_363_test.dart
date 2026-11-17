import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/expenses/expense_split.dart';
import 'package:coroute_app/domain/expenses/pre_ride_checklist.dart';

/// v3.63 trip planning lite: the expense split maths (same as the gateway) and the pre-ride checklist model.
void main() {
  test('amounts: parse and format (no currency symbol, Indian grouping)', () {
    expect(parseAmount('12.5'), 1250);
    expect(parseAmount('1,250'), 125000);
    expect(parseAmount('0'), isNull);
    expect(parseAmount('1.234'), isNull);
    expect(parseAmount('abc'), isNull);
    expect(formatAmount(125050), '1,250.50');
    expect(formatAmount(12345600), '1,23,456');
    expect(formatAmount(-600), '-6');
  });

  test('equal shares add up exactly, like the gateway', () {
    expect(equalShares(1000, ['c', 'a', 'b']), {'a': 334, 'b': 333, 'c': 333});
    expect(equalShares(1000, []), isEmpty);
  });

  test('balances and the shortest settle-up list', () {
    final bal = balances([
      ('a', 3000, {'a': 1000, 'b': 1000, 'c': 1000}),
      ('b', 600, {'a': 200, 'b': 200, 'c': 200}),
    ]);
    expect(bal, {'a': 1800, 'b': -600, 'c': -1200});
    expect(settleUp(bal), [const Transfer('c', 'a', 1200), const Transfer('b', 'a', 600)]);
    expect(balances([('a', 3000, {'a': 1500, 'b': 1500})], [('b', 'a', 1500)]), isEmpty);
  });

  test('expense book from the gateway answer', () {
    final b = ExpenseBook.fromJson({
      'me': 'a', 'canEdit': true, 'totalSpent': 36,
      'members': [{'userId': 'a', 'name': 'Anu'}, {'userId': 'b', 'name': 'Ravi'}],
      'expenses': [{'id': 'ex_1', 'what': 'Fuel', 'amount': 30, 'paidBy': 'a', 'mine': true, 'shares': [{'userId': 'a', 'amount': 15}, {'userId': 'b', 'amount': 15}]}],
      'balances': [{'userId': 'a', 'amount': 15}, {'userId': 'b', 'amount': -15}],
      'settleUp': [{'from': 'b', 'to': 'a', 'amount': 15}],
      'settlements': [],
    });
    expect(b.myBalance, 1500);
    expect(b.nameOf('a'), 'You');
    expect(b.expenses.single.shares['b'], 1500);
    expect(b.settleUp.single, const Transfer('b', 'a', 1500));
  });

  test('checklist: all good, own items, removed defaults, ticks expire after a ride', () {
    final c = PreRideChecklist();
    expect(c.allDone, isFalse);
    c.allGood();
    expect(c.allDone, isTrue);
    expect(c.addCustom('Rain jacket'), isTrue);
    expect(c.addCustom('rain jacket'), isFalse);
    expect(c.allDone, isFalse);
    c.remove('puc');
    expect(c.visible.any((i) => i.id == 'puc'), isFalse);
    final now = DateTime(2026, 11, 17, 8).millisecondsSinceEpoch;
    final json = c.toJson(now);
    final same = PreRideChecklist.fromJson(json, nowMs: now + 3600000);
    expect(same.items.any((i) => i.label == 'Rain jacket'), isTrue);
    expect(same.hidden, contains('puc'));
    expect(same.done, isNotEmpty);
    final nextDay = PreRideChecklist.fromJson(json, nowMs: now + const Duration(hours: 20).inMilliseconds);
    expect(nextDay.done, isEmpty, reason: 'ticks are for one ride');
    expect(nextDay.items.any((i) => i.label == 'Rain jacket'), isTrue, reason: 'the list itself stays');
    expect(defaultChecklist.map((i) => i.id), containsAll(['licence', 'rc', 'insurance', 'puc', 'helmet', 'tyres', 'chain', 'brakes', 'lights', 'fuel', 'phone', 'contacts', 'medical', 'offline_map']));
  });
}
