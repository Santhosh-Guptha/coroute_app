import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/widgets/devmonks_branding.dart';
import 'package:coroute_app/core/widgets/glass_card.dart';

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

  testWidgets('CoRouteHeaderLogo renders logo and tagline', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: CoRouteHeaderLogo(),
          ),
        ),
      ),
    );

    expect(find.text('CoRoute'), findsOneWidget);
    expect(find.text('Ride Together. Stay Safe.'), findsOneWidget);
  });

  testWidgets('GlassCard renders child widget', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GlassCard(
            child: Text('Test HUD Component'),
          ),
        ),
      ),
    );

    expect(find.text('Test HUD Component'), findsOneWidget);
  });
}
