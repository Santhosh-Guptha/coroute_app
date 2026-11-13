// Stand-in for package:flutter_test for PURE Dart tests (no widgets, no dart:ui), used where the
// Flutter SDK is not installed. tool/pure_dart_test/run.sh swaps the flutter_test import for this
// file and runs the test with the plain Dart VM. Supports group / test / setUp / tearDown / expect
// (matchers from package:matcher) and async tests. Not a replacement for `flutter test`.
import 'dart:async';

import 'package:matcher/matcher.dart';

export 'package:matcher/matcher.dart';

int passed = 0, failed = 0;
final List<String> _groups = [];
final List<(String, FutureOr<void> Function(), List<FutureOr<void> Function()>, List<FutureOr<void> Function()>)> _tests = [];
final List<List<FutureOr<void> Function()>> _setUps = [[]];
final List<List<FutureOr<void> Function()>> _tearDowns = [[]];

void group(String name, void Function() body) {
  _groups.add(name);
  _setUps.add([]);
  _tearDowns.add([]);
  body();
  _groups.removeLast();
  _setUps.removeLast();
  _tearDowns.removeLast();
}

void setUp(FutureOr<void> Function() body) => _setUps.last.add(body);
void tearDown(FutureOr<void> Function() body) => _tearDowns.last.add(body);

void test(String name, FutureOr<void> Function() body) {
  _tests.add(([..._groups, name].join(' > '), body, [for (final l in _setUps) ...l], [for (final l in _tearDowns.reversed) ...l]));
}

void expect(dynamic actual, dynamic matcher, {String? reason}) {
  final m = wrapMatcher(matcher);
  final state = <dynamic, dynamic>{};
  if (!m.matches(actual, state)) {
    final d = StringDescription();
    m.describe(d);
    final md = StringDescription();
    m.describeMismatch(actual, md, state, false);
    throw 'Expected: $d\n  Actual: $actual $md${reason != null ? '\n  Reason: $reason' : ''}';
  }
}

Future<void> report(String file) async {
  for (final (name, body, ups, downs) in _tests) {
    try {
      for (final s in ups) {
        await s();
      }
      await body();
      for (final s in downs) {
        await s();
      }
      passed++;
    } catch (e, st) {
      failed++;
      print('FAIL: $name\n  $e\n${st.toString().split('\n').take(4).join('\n')}');
    }
  }
  print('$file: $passed passed, $failed failed');
  if (failed > 0) throw StateError('$failed test(s) failed');
}
