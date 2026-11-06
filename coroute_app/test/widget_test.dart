import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/widgets/devmonks_branding.dart';

void main() {
  testWidgets('DevMonksBadge compact renders brand label', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: DevMonksBadge(isCompact: true),
          ),
        ),
      ),
    );

    expect(find.text('devmonks.space'), findsOneWidget);
  });


}
