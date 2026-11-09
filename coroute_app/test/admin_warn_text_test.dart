import 'package:coroute_app/presentation/admin/admin_ride_reports.dart';
import 'package:flutter_test/flutter_test.dart';

/// Admin "Warn": typed text, required, at most 280 characters, cleaned like the gateway.
void main() {
  test('clean trims, removes control characters and angle brackets, collapses spaces', () {
    expect(AdminWarnText.clean('  Keep\u0000 it\n\n <b>polite</b> '), 'Keep it bpolite/b');
  });

  test('required and at most 280 characters (counted after cleaning)', () {
    expect(AdminWarnText.problem(''), isNotNull);
    expect(AdminWarnText.problem('   \n '), isNotNull);
    expect(AdminWarnText.problem('<>'), isNotNull);
    expect(AdminWarnText.problem('x' * 280), isNull);
    expect(AdminWarnText.problem('  ${'x' * 280}  '), isNull);
    expect(AdminWarnText.problem('x' * 281), isNotNull);
    expect(AdminWarnText.problem(AdminWarnText.guidelines), isNull, reason: 'the quick option fits');
  });
}
