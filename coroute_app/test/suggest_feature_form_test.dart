import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/presentation/feedback/suggest_feature_screen.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  test('body: topic and message; the e-mail only with "Contact me"', () {
    final off = SuggestFeatureForm.bodyOf(topic: IdeaTopic.group, message: '  Regroup alert at fuel stops  ', contact: false, email: 'a@b.co', name: 'Asha', openedAt: 5);
    expect(off, {'topic': 'group-riding', 'message': 'Regroup alert at fuel stops', 't': 5, 'contact': false});
    final on = SuggestFeatureForm.bodyOf(topic: IdeaTopic.safety, message: 'x', contact: true, email: 'a@b.co', name: 'Asha', openedAt: 5);
    expect(on['email'], 'a@b.co');
    expect(on['name'], 'Asha');
    expect(on['contact'], true);
    final noMail = SuggestFeatureForm.bodyOf(topic: IdeaTopic.other, message: 'x', contact: true, email: '', name: 'Asha', openedAt: 5);
    expect(noMail.containsKey('email'), isFalse);
    expect(noMail['contact'], false);
  });

  testWidgets('pick a topic, write, send: thank-you state', (tester) async {
    Map<String, dynamic>? sent;
    await tester.pumpWidget(host(SuggestFeatureForm(email: 'rider@example.com', send: (b) async => sent = b)));

    expect(find.text('Safety idea'), findsOneWidget);
    expect(find.text('Group riding'), findsOneWidget);
    expect(find.text('Map & navigation'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);

    // Too short: a gentle hint, nothing sent.
    await tester.enterText(find.byKey(const Key('idea_message')), 'Short');
    await tester.tap(find.byKey(const Key('idea_send')));
    await tester.pump();
    expect(sent, isNull);
    expect(find.textContaining('at least 20 characters'), findsOneWidget);

    await tester.tap(find.byKey(const Key('idea_topic_map')));
    await tester.enterText(find.byKey(const Key('idea_message')), 'Warn me about sharp bends on unknown roads');
    await tester.ensureVisible(find.byKey(const Key('idea_send')));
    await tester.tap(find.byKey(const Key('idea_send')));
    await tester.pumpAndSettle();

    expect(sent?['topic'], 'map-navigation');
    expect(sent?['message'], 'Warn me about sharp bends on unknown roads');
    expect(sent?['contact'], false);
    expect(sent?.containsKey('email'), isFalse, reason: 'private by default');
    expect(find.text(SuggestFeatureForm.thanks), findsOneWidget);
  });

  testWidgets('the message is capped at 500 characters', (tester) async {
    await tester.pumpWidget(host(SuggestFeatureForm(send: (_) async {})));
    await tester.enterText(find.byKey(const Key('idea_message')), 'a' * 700);
    await tester.pump();
    final field = tester.widget<TextField>(find.byKey(const Key('idea_message')));
    expect(field.controller!.text.length, SuggestFeatureForm.maxLength);
  });

  testWidgets('a send error is shown and the form stays', (tester) async {
    await tester.pumpWidget(host(SuggestFeatureForm(send: (_) async => throw const ApiException(0, 'offline'))));
    await tester.enterText(find.byKey(const Key('idea_message')), 'Share my fuel range with the lead rider');
    await tester.ensureVisible(find.byKey(const Key('idea_send')));
    await tester.tap(find.byKey(const Key('idea_send')));
    await tester.pumpAndSettle();
    expect(find.textContaining('offline'), findsOneWidget);
    expect(find.text(SuggestFeatureForm.thanks), findsNothing);
  });
}
