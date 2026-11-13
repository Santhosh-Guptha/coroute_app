// Round 10 rescue beacon, VICTIM phone: what a passer-by (or the rider, coming round) sees while the
// beacon runs, and the "Still able to respond?" check after an SOS.
//  * on the crash alarm screen after the SOS went out (CrashAlarmScreen), and
//  * on its own screen over the lock screen when no alarm screen is open (RescueBeaconHost).
// Stops: the rider ("I'm OK, stop the siren", the existing rule); a bystander's deliberate 3 s hold
// ("Stop siren: help is here", logged, the SOS stays open). A touch anywhere pauses the sound for
// 15 s so nobody is blasted at ear distance while reading the Medical ID or calling.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/rescue_beacon_service.dart';
import '../../domain/rescue/rescue_beacon_plan.dart';
import '../../domain/rescue/rescue_id.dart';
import 'rescue_widgets.dart';

class RescueBeaconPanel extends StatelessWidget {
  const RescueBeaconPanel({super.key});

  static const String stopLabel = 'Stop siren: help is here';
  static const String stopHolding = 'Keep holding to stop the siren...';
  static const String riderOkLabel = "I'm the rider and I'm OK: stop the siren";

  @override
  Widget build(BuildContext context) {
    final rescue = context.watch<RescueBeaconService?>();
    if (rescue == null) return const SizedBox.shrink();
    if (rescue.askingResponse) return _ResponseCheck(rescue: rescue);
    if (!rescue.active) {
      if (!rescue.canStartByHand) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: Space.s16),
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(64),
          ),
          onPressed: rescue.startByHand,
          icon: const Icon(Icons.campaign_rounded),
          label: const Text(
            'Lost or trapped? Start the rescue siren',
            maxLines: 2,
          ),
        ),
      );
    }
    final quiet =
        rescue.phase == RescuePhase.reserve ||
        rescue.phase == RescuePhase.critical;
    final title = rescue.bystanderStopped
        ? 'Siren stopped by someone here. The SOS is still open.'
        : (quiet
              ? 'Battery low: siren paused to keep the SOS working.'
              : 'Rescue siren is on: guiding people to this phone.');
    final ble = rescue.bleState;
    return Listener(
      onPointerDown: (_) => rescue.noteTouch(),
      child: Container(
        margin: const EdgeInsets.only(bottom: Space.s16),
        padding: const EdgeInsets.all(Space.s16),
        decoration: BoxDecoration(
          color: AppTheme.isLight
              ? const Color(0xFFFFECEC)
              : const Color(0xFF2A0606),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.sos, width: 2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.campaign_rounded, color: AppTheme.sos, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: AppTheme.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.s8),
            Text(
              'This rider may be hurt. Help is on the way: their group and emergency contacts have the location. '
              'If you are with them, call 112 and stay with them. Touching the screen pauses the sound for a moment.',
              style: AppText.body,
            ),
            const SizedBox(height: Space.s8),
            Text(
              [
                    if (!rescue.bystanderStopped && !quiet) 'Siren',
                    if (!quiet) 'Locator sound',
                    if (ble.any)
                      ble.coded ? 'Bluetooth (long range)' : 'Bluetooth',
                  ].join(' + ') +
                  (rescue.rescueId > 0
                      ? '  ·  Rescue code ${RescueId.hex(rescue.rescueId).toUpperCase()}'
                      : ''),
              style: AppText.caption,
            ),
            const SizedBox(height: Space.s16),
            if (!rescue.bystanderStopped) ...[
              HoldToConfirmButton(
                label: stopLabel,
                holdingLabel: stopHolding,
                onConfirmed: rescue.bystanderStop,
              ),
              const SizedBox(height: Space.s12),
            ],
            SizedBox(
              height: 64,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.success,
                  foregroundColor: Colors.white,
                ),
                onPressed: rescue.riderOk,
                icon: const Icon(Icons.check_rounded),
                label: const Text(
                  riderOkLabel,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResponseCheck extends StatelessWidget {
  const _ResponseCheck({required this.rescue});
  final RescueBeaconService rescue;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: Space.s16),
      padding: const EdgeInsets.all(Space.s16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.warning, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Still able to respond?', style: AppText.title),
          const SizedBox(height: Space.s8),
          Text(
            'Your SOS is open. If you do not answer, a loud rescue siren starts in ${rescue.responseSecondsLeft} s '
            'so your group can find you.',
            style: AppText.body,
          ),
          const SizedBox(height: Space.s12),
          SizedBox(
            height: 72,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.success,
                foregroundColor: Colors.white,
              ),
              onPressed: rescue.answerResponseCheck,
              icon: const Icon(Icons.record_voice_over_rounded, size: 28),
              label: const Text(
                'I can respond',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The beacon's own screen (over the lock screen) when no crash alarm screen is open.
class RescueBeaconScreen extends StatelessWidget {
  const RescueBeaconScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final rescue = context.watch<RescueBeaconService?>();
    return Scaffold(
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
                    title: 'Rescue beacon',
                    onBack: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(height: Space.s16),
                  const RescueBeaconPanel(),
                  if (rescue != null)
                    for (final l in rescue.log.reversed.take(5))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '${TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(l.atMs)).format(context)}  ${l.text}',
                          style: AppText.caption,
                        ),
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
