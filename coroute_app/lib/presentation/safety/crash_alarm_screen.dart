import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/safety_service.dart';
import '../widgets/emergency_sos_sheet.dart';
import 'sos_hold_screen.dart';

/// Full-screen crash alarm (POSSIBLE_ACCIDENT), shown by [CrashAlarmHost]
/// while [SafetyService.alarm] is open. Counting down: red screen, "Possible
/// accident detected. Are you okay?", **I'm OK** (green, nothing is sent)
/// and **Need Help** (sends at once). After the SOS went out: the SOS sheet content (call, text, 112,
/// "I am safe") until the rider closes it. Texts follow the rider's language
/// ([L10n], 3.16) and change at once when it changes.
class CrashAlarmScreen extends StatelessWidget {
  const CrashAlarmScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: L10n.changes,
      builder: (context, _, _) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final safety = context.watch<SafetyService>();
    final alarm = safety.alarm;
    if (alarm == null) {
      return Scaffold(backgroundColor: AppTheme.bg, body: const SizedBox.shrink());
    }
    if (alarm.sent) {
      return PopScope(
        canPop: true,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) safety.closeAlarm();
        },
        child: Scaffold(
          backgroundColor: AppTheme.bg,
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: SingleChildScrollView(
                  padding: dsScreenPadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DsScreenHeader(
                        title: L10n.t('crash.sent'),
                        onBack: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(height: 18),
                      EmergencySosSheet(lat: alarm.lat, lng: alarm.lng, onResolved: safety.closeAlarm),
                    ],
                  ),
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
        lat: alarm.lat,
        lng: alarm.lng,
      ),
    );
  }
}

/// The red countdown screen itself (pure, for tests). Verified at 320 dp and
/// text x1.3 in portrait and landscape: every text wraps or shrinks, the two
/// buttons keep their height, nothing overflows. Same red treatment as
/// [SosHoldScreen]: overline + position, the 140 px ring with the seconds,
/// headline, who gets alerted, white "I'm OK" and outlined "Need Help".
class CrashAlarmView extends StatelessWidget {
  /// The words in the rider's language (read at build time).
  static String get title => L10n.t('crash.title');
  static String get okLabel => L10n.t('crash.ok');
  static String get helpLabel => L10n.t('crash.help');

  final int secondsLeft;
  final VoidCallback onImOk;
  final VoidCallback onSendNow;

  /// Where the impact was, for the top row (0 when unknown).
  final double? lat;
  final double? lng;

  const CrashAlarmView({
    super.key,
    required this.secondsLeft,
    required this.onImOk,
    required this.onSendNow,
    this.lat,
    this.lng,
  });

  static const double buttonHeight = 72;

  static String countdownText(int seconds) =>
      seconds == 1 ? L10n.t('crash.countdown.one') : L10n.t('crash.countdown', {'n': seconds});

  @override
  Widget build(BuildContext context) {
    final top = SosTopRow(overline: L10n.t('crash.automatic'), lat: lat, lng: lng);
    final heading = Semantics(
      container: true,
      header: true,
      liveRegion: true,
      child: Text(
        title,
        textAlign: TextAlign.center,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.3, height: 1.15),
      ),
    );
    final countdown = Text(
      countdownText(secondsLeft),
      textAlign: TextAlign.center,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700, height: 1.35),
    );
    final hint = Text(
      L10n.t('crash.hint'),
      textAlign: TextAlign.center,
      maxLines: 4,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: sosPale, fontSize: 15, fontWeight: FontWeight.w600, height: 1.35),
    );
    final count = ExcludeSemantics(
      child: SosRing(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 64,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '$secondsLeft',
                  textScaler: TextScaler.noScaling,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 64,
                    fontWeight: FontWeight.w800,
                    height: 1.0,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 2),
            const Text(
              'SECONDS',
              textScaler: TextScaler.noScaling,
              style: TextStyle(color: sosPale, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.5),
            ),
          ],
        ),
      ),
    );
    final ok = SizedBox(
      height: buttonHeight,
      child: FilledButton.icon(
        onPressed: onImOk,
        style: sosPrimaryButtonStyle(height: buttonHeight),
        icon: const Icon(Icons.check_rounded, size: 26),
        label: Text(okLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    final send = SizedBox(
      height: buttonHeight,
      child: FilledButton.icon(
        onPressed: onSendNow,
        style: sosOutlineButtonStyle(height: buttonHeight),
        icon: const Icon(Icons.sos_rounded, size: 24),
        label: Text(helpLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    final buttons = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [ok, const SizedBox(height: 12), send, const SizedBox(height: 12), const SosCaption()],
    );
    const list = SosAlertList();

    return Scaffold(
      backgroundColor: AppTheme.sos,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth > box.maxHeight && box.maxWidth >= 480;
            if (wide) {
              // Landscape: text on the left, the ring and the two big buttons on the right.
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            top,
                            const SizedBox(height: 14),
                            heading,
                            const SizedBox(height: 8),
                            countdown,
                            const SizedBox(height: 4),
                            hint,
                            const SizedBox(height: 16),
                            list,
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [Center(child: count), const SizedBox(height: 16), buttons],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }
            return SingleChildScrollView(
              padding: dsScreenPadding,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight > 44 ? box.maxHeight - 44 : 0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        top,
                        const SizedBox(height: 24),
                        Center(child: count),
                        const SizedBox(height: 14),
                        heading,
                        const SizedBox(height: 10),
                        countdown,
                        const SizedBox(height: 4),
                        hint,
                        const SizedBox(height: 20),
                        list,
                      ],
                    ),
                    Padding(padding: const EdgeInsets.only(top: 20), child: buttons),
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
