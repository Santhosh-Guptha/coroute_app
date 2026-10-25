import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/biometric_safety_bridge.dart';
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
        child: Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (alarm.isSirenActive && event is KeyDownEvent) {
              final key = event.logicalKey;
              if (key == LogicalKeyboardKey.audioVolumeDown ||
                  key == LogicalKeyboardKey.audioVolumeUp ||
                  key == LogicalKeyboardKey.audioVolumeMute ||
                  key == LogicalKeyboardKey.escape) {
                safety.silenceSiren();
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
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
                        if (alarm.isSirenActive) ...[
                          Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: AppTheme.isLight ? const Color(0xFFFFECEC) : const Color(0xFF2A0606),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: AppTheme.sos, width: 2),
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.sos.withValues(alpha: AppTheme.isLight ? 0.15 : 0.35),
                                  blurRadius: 16,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.emergency_rounded, color: AppTheme.sos, size: 26),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        '🚨 BYSTANDER AUDIO BEACON ACTIVE',
                                        style: TextStyle(
                                          color: AppTheme.isLight ? AppTheme.sos : Colors.redAccent.shade100,
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 0.6,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  "Loud audio beacon sounding to guide bystanders to your location. Tap below, press volume keys, or say 'CoRoute Silence' to mute. SOS remains broadcasting to your convoy.",
                                  style: TextStyle(
                                    color: AppTheme.isLight ? AppTheme.text : Colors.white.withValues(alpha: 0.9),
                                    fontSize: 13,
                                    height: 1.4,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                ElevatedButton.icon(
                                  onPressed: safety.silenceSiren,
                                  icon: const Icon(Icons.volume_off_rounded, color: Colors.white),
                                  label: const Text(
                                    "🔕 I'M CONSCIOUS · SILENCE SIREN",
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.sos,
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size.fromHeight(56),
                                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        EmergencySosSheet(lat: alarm.lat, lng: alarm.lng, onResolved: safety.closeAlarm),
                      ],
                    ),
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
        currentBpm: alarm.currentBpm,
        traumaLevel: alarm.traumaLevel,
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

  /// FEAT-04: Smartwatch biometric trauma & pulse verification during crash countdown.
  final int? currentBpm;
  final BiometricTraumaLevel? traumaLevel;

  const CrashAlarmView({
    super.key,
    required this.secondsLeft,
    required this.onImOk,
    required this.onSendNow,
    this.lat,
    this.lng,
    this.currentBpm,
    this.traumaLevel,
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

    Widget? pulseBadge;
    if (currentBpm != null) {
      final isCrit = traumaLevel == BiometricTraumaLevel.criticalTraumaLevel1;
      final isElevated = traumaLevel == BiometricTraumaLevel.elevatedTrauma;
      final bg = isCrit
          ? Colors.black.withValues(alpha: 0.45)
          : (isElevated ? const Color(0xFFB45309).withValues(alpha: 0.45) : Colors.black.withValues(alpha: 0.25));
      final textColor = isCrit ? const Color(0xFFFFD1D1) : Colors.white;
      final label = currentBpm == 0
          ? '0 BPM · CRITICAL PULSELESSNESS'
          : '$currentBpm BPM · ${traumaLevel?.label ?? "Live Pulse"}';

      pulseBadge = Container(
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.only(top: 8, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isCrit ? Colors.redAccent.withValues(alpha: 0.8) : Colors.white.withValues(alpha: 0.3),
            width: isCrit ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              currentBpm == 0 ? Icons.heart_broken_rounded : Icons.favorite_rounded,
              color: isCrit ? const Color(0xFFFF4B4B) : const Color(0xFFFF6B6B),
              size: 16,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.sos,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth > box.maxHeight && box.maxWidth >= 480;
            if (wide) {
              // Landscape: text on the left, the ring and the two big buttons on the right.
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 840),
                  child: Padding(
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
                              children: [
                                Center(child: count),
                                if (pulseBadge != null) Center(child: pulseBadge),
                                const SizedBox(height: 16),
                                buttons,
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            final compact = box.maxHeight < 800;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: SingleChildScrollView(
                  padding: compact ? const EdgeInsets.fromLTRB(16, 12, 16, 16) : dsScreenPadding,
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
                            SizedBox(height: compact ? 12 : 24),
                            Center(child: count),
                            if (pulseBadge != null) Center(child: pulseBadge),
                            SizedBox(height: compact ? 8 : 14),
                            heading,
                            SizedBox(height: compact ? 6 : 10),
                            countdown,
                            const SizedBox(height: 4),
                            hint,
                            SizedBox(height: compact ? 12 : 20),
                            list,
                          ],
                        ),
                        Padding(padding: EdgeInsets.only(top: compact ? 12 : 20), child: buttons),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
