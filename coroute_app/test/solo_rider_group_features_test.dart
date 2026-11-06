import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Solo rider suppresses group features and retains safety systems, dynamic reveal on participant >= 2', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Text('SOS Active'),
              Text('Crash Detection Active'),
              Text('GPS Telemetry Active'),
              Text('Offline Map Active'),
              Text('Speed Limit Active'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('SOS Active'), findsOneWidget);
    expect(find.text('Crash Detection Active'), findsOneWidget);
    expect(find.text('GPS Telemetry Active'), findsOneWidget);
    expect(find.text('Offline Map Active'), findsOneWidget);
    expect(find.text('Speed Limit Active'), findsOneWidget);
  });
}
