import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/safety_service.dart';
import '../widgets/emergency_sos_sheet.dart';

/// Full-screen crash alarm (POSSIBLE_ACCIDENT), shown by [CrashAlarmHost]
/// while [SafetyService.alarm] is open. Counting down: red screen, "Possible
/// accident detected. Are you okay?", **I'm OK** (green, nothing is sent)
/// and **Need Help** (sends at once). After the SOS went out: the SOS sheet content (call, text, 112,
/// "I am safe") until the rider closes it.
class CrashAlarmScreen extends StatelessWidget {
  const CrashAlarmScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final safety = context.watch<SafetyService>();
    final alarm = safety.alarm;
    if (alarm == null) {
      return Scaffold(backgroundColor: AppTheme.obsidianVoid, body: const SizedBox.shrink());
    }
    if (alarm.sent) {
      return PopScope(
        canPop: true,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) safety.closeAlarm();
        },
        child: Scaffold(
          backgroundColor: AppTheme.obsidianVoid,
          appBar: AppBar(title: const Text('Crash SOS sent')),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(Space.s16),
                  child: EmergencySosSheet(lat: alarm.lat, lng: alarm.lng, onResolved: safety.closeAlarm),
                ),
              ),
            ),
          ),
        ),
      );
    }
    // While counting down, Back does not close the alarm: only the two buttons do.
    return PopScope(
      canPop: false,
      child: CrashAlarmView(
        secondsLeft: alarm.secondsLeft,
        onImOk: safety.alarmImOk,
        onSendNow: safety.alarmSendNow,
      ),
    );
  }
}

/// The red countdown screen itself (pure, for tests).
class CrashAlarmView extends StatelessWidget {
  static const String title = 'Possible accident detected. Are you okay?';
  static const String okLabel = 'I\'m OK';
  static const String helpLabel = 'Need Help';

  final int secondsLeft;
  final VoidCallback onImOk;
  final VoidCallback onSendNow;

  const CrashAlarmView({super.key, required this.secondsLeft, required this.onImOk, required this.onSendNow});

  static const double buttonHeight = 72;

  static String countdownText(int seconds) =>
      'Sending SOS to your group in $seconds ${seconds == 1 ? 'second' : 'seconds'}.';

  @override
  Widget build(BuildContext context) {
    final onRed = StatusColors.onCritical;
    final header = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: Space.s8, vertical: Space.s4),
          decoration: BoxDecoration(border: Border.all(color: onRed), borderRadius: Radii.smAll),
          child: Text('Automatic alert', style: AppText.label.copyWith(color: onRed)),
        ),
        const SizedBox(height: Space.s12),
        Semantics(
          container: true,
          header: true,
          liveRegion: true,
          child: Text(
            title,
            style: AppText.metric.copyWith(color: onRed, fontSize: 30, height: 1.15),
          ),
        ),
        const SizedBox(height: Space.s8),
        Text(
          countdownText(secondsLeft),
          style: AppText.title.copyWith(color: onRed, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: Space.s4),
        Text(
          'If you are fine, tap I\'m OK. Nothing is sent.',
          style: AppText.body.copyWith(color: onRed),
        ),
      ],
    );
    final count = ExcludeSemantics(
      child: Text(
        '$secondsLeft',
        style: AppText.metric.copyWith(color: onRed, fontSize: 64, height: 1.0),
      ),
    );
    final ok = SizedBox(
      height: buttonHeight,
      child: FilledButton.icon(
        onPressed: onImOk,
        style: FilledButton.styleFrom(
          backgroundColor: StatusColors.success,
          foregroundColor: onRed,
          minimumSize: const Size.fromHeight(buttonHeight),
          side: BorderSide(color: onRed, width: 2),
          textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        icon: const Icon(Icons.check_circle_rounded, size: 30),
        label: const Text(okLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    final send = SizedBox(
      height: buttonHeight,
      child: FilledButton.icon(
        onPressed: onSendNow,
        style: FilledButton.styleFrom(
          backgroundColor: StatusColors.critical,
          foregroundColor: onRed,
          minimumSize: const Size.fromHeight(buttonHeight),
          side: BorderSide(color: onRed, width: 3),
          textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        icon: const Icon(Icons.sos_rounded, size: 30),
        label: const Text(helpLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );

    return Scaffold(
      backgroundColor: StatusColors.critical,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth > box.maxHeight && box.maxWidth >= 480;
            if (wide) {
              // Landscape: text on the left, the two big buttons on the right.
              return Padding(
                padding: const EdgeInsets.all(Space.s16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [header, const SizedBox(height: Space.s8), count],
                        ),
                      ),
                    ),
                    const SizedBox(width: Space.s16),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [ok, const SizedBox(height: Space.s16), send],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.all(Space.s16),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight > Space.s32 ? box.maxHeight - Space.s32 : 0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Space.s16),
                      child: Center(child: count),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [ok, const SizedBox(height: Space.s16), send],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
