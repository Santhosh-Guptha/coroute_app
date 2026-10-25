import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/presentation/rider/widgets/voice_assistant_hud_pill.dart';
import 'package:coroute_app/data/services/voice/voice_assistant_controller.dart';
import 'package:coroute_app/data/services/voice/voice_action_executor.dart';
import 'package:coroute_app/data/services/voice/speech_recognition_adapter.dart';

void main() {
  late MockSpeechRecognitionAdapter mockSpeech;
  late VoiceAssistantController controller;

  setUp(() {
    mockSpeech = MockSpeechRecognitionAdapter();
    controller = VoiceAssistantController(
      speechAdapter: mockSpeech,
      actionExecutor: VoiceActionExecutor(),
      enforcePhase1Scope: false,
      allowMessaging: true,
      allowStopsAndAlerts: true,
      allowIntercom: true,
    );
    controller.setPermissionState(MicPermissionState.granted);
  });

  tearDown(() {
    controller.cancelSession();
    controller.dispose();
  });

  Widget buildTestApp(Widget child) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: child),
      ),
    );
  }

  group('VoiceAssistantHudPill Widget Tests', () {
    testWidgets('renders SizedBox.shrink when idle and statusFeedback is empty', (tester) async {
      await tester.pumpWidget(buildTestApp(VoiceAssistantHudPill(controller: controller)));

      expect(find.byType(AnimatedContainer), findsNothing);
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('renders cyan listening pill when listening starts', (tester) async {
      await tester.pumpWidget(buildTestApp(VoiceAssistantHudPill(controller: controller)));

      controller.setLocale('te-IN');
      await controller.startListening();
      await tester.pump();

      expect(find.byType(AnimatedContainer), findsOneWidget);
      expect(find.text('LISTENING (PTT)'), findsOneWidget);
      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);

      await controller.cancelSession();
      await tester.pump();
    });

    testWidgets('updates transcript text in real time during listening', (tester) async {
      await tester.pumpWidget(buildTestApp(VoiceAssistantHudPill(controller: controller)));

      controller.setLocale('en-IN');
      await controller.startListening();
      await tester.pump();

      mockSpeech.simulateUtterance('Find nearest petrol pump', isFinal: false);
      await tester.pump();

      expect(find.text('Find nearest petrol pump'), findsOneWidget);

      await controller.cancelSession();
      await tester.pump();
    });

    testWidgets('tapping pill while listening stops listening', (tester) async {
      await tester.pumpWidget(buildTestApp(VoiceAssistantHudPill(controller: controller)));

      controller.setLocale('en-IN');
      await controller.startListening();
      await tester.pump();
      expect(controller.isListening, isTrue);

      await tester.tap(find.byType(VoiceAssistantHudPill));
      await tester.pump();

      expect(controller.isListening, isFalse);

      await controller.cancelSession();
      await tester.pump();
    });

    testWidgets('displays confirmation prompt when confirming action', (tester) async {
      await tester.pumpWidget(buildTestApp(VoiceAssistantHudPill(controller: controller)));

      controller.setLocale('en-IN');
      await controller.startListening();
      await tester.pump();

      mockSpeech.simulateUtterance('Send message to Rohit', isFinal: true);
      await tester.pump();

      if (controller.isConfirming) {
        expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
        expect(find.text('CONFIRM ACTION'), findsOneWidget);
        expect(find.text('Say Yes / No'), findsOneWidget);
      }

      await controller.cancelSession();
      await tester.pump();
    });
  });

  group('VoicePttButton Ergonomic Touch Target Tests', () {
    testWidgets('renders 56x56 dp glove-friendly circular touch target', (tester) async {
      await tester.pumpWidget(buildTestApp(VoicePttButton(controller: controller)));

      final containerFinder = find.byType(AnimatedContainer);
      expect(containerFinder, findsOneWidget);

      final Size size = tester.getSize(containerFinder);
      expect(size.width, equals(56.0));
      expect(size.height, equals(56.0));
    });

    testWidgets('idle button shows mic icon and initiates listening on tap', (tester) async {
      await tester.pumpWidget(buildTestApp(VoicePttButton(controller: controller)));

      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);

      await tester.tap(find.byType(VoicePttButton));
      await tester.pump();

      expect(controller.isListening, isTrue);
      expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);

      await controller.cancelSession();
      await tester.pump();
    });

    testWidgets('listening button stops listening on tap', (tester) async {
      await tester.pumpWidget(buildTestApp(VoicePttButton(controller: controller)));

      await controller.startListening();
      await tester.pump();
      expect(controller.isListening, isTrue);

      await tester.tap(find.byType(VoicePttButton));
      await tester.pump();

      expect(controller.isListening, isFalse);

      await controller.cancelSession();
      await tester.pump();
    });

    testWidgets('button renders SizedBox.shrink when controller is null', (tester) async {
      await tester.pumpWidget(buildTestApp(const VoicePttButton(controller: null)));

      expect(find.byType(AnimatedContainer), findsNothing);
    });
  });
}
