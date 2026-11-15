import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/models/convoy_model.dart';
import '../../../data/models/rider_model.dart';
import '../../../data/services/intercom_service.dart';
import '../../../data/services/settings_service.dart';
import '../../../domain/audio/talk_button_state.dart';
import '../../widgets/feature_switch.dart';

/// v3.61 compact talk control for the short ride sheet (owner, 15 Nov 2026).
///
/// Two glove-sized parts in one capsule:
/// * the mic (60 x 56 dp): hold to talk; in hands-free a tap stops hands-free; muted: tap unmutes;
/// * the options part (44 x 56 dp): Hold to talk / Hands-free, who hears me (everyone or one rider:
///   private talk) and which side of the screen the talk button sits on.
///
/// Uses the same IntercomService calls as the full-width bar (beginTransmission / endTransmission,
/// toggleHandsFreeTalk, setTalkTarget), so the voice path, permissions and the admin switch are
/// unchanged. Hidden when talk is switched off or not part of this ride.
class CockpitTalkButton extends StatefulWidget {
  const CockpitTalkButton({super.key, required this.convoy, required this.me});

  final ConvoyModel convoy;
  final RiderModel me;

  @override
  State<CockpitTalkButton> createState() => _CockpitTalkButtonState();
}

class _CockpitTalkButtonState extends State<CockpitTalkButton> {
  bool _pressed = false;
  bool _swipeCancelled = false;
  Offset? _downPos;
  DateTime? _downTime;

  void _note(String text) {
    if (!mounted) return;
    final m = ScaffoldMessenger.maybeOf(context);
    m?.clearSnackBars();
    m?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final ic = context.watch<IntercomService?>();
    if (ic == null || !context.featureOn('intercom') || !widget.convoy.allowsGroupFeature('intercom')) return const SizedBox.shrink();
    final vox = ic.mode == IntercomMode.vox;
    final st = TalkButtonState.of(
      transmitting: ic.isTransmitting,
      receiving: ic.isReceiving,
      handsFree: vox,
      muted: ic.isMicMuted,
      available: !ic.isMicrophoneRevoked && !ic.isPausedByPhoneCall,
      privateName: ic.talkTargetName ?? (ic.isPrivateTalk ? 'one rider' : null),
      speakerName: ic.activeSpeakerName,
    );
    final privateFill = AppTheme.isLight ? AppTheme.infoBlue : const Color(0xFF35679F);
    final talkFill = AppTheme.isLight ? AppTheme.warnText : const Color(0xFF8A5A1C);
    final (Color bg, Color fg) = switch (st.look) {
      TalkButtonLook.talking => (st.private ? privateFill : talkFill, Colors.white),
      TalkButtonLook.muted => (AppTheme.accentSoft, AppTheme.warnText),
      TalkButtonLook.off => (AppTheme.surfaceAlt, AppTheme.textMuted),
      _ => (st.private ? privateFill : AppTheme.brand, Colors.white),
    };
    final IconData icon = switch (st.look) {
      TalkButtonLook.muted || TalkButtonLook.off => Icons.mic_off_rounded,
      TalkButtonLook.hearing => Icons.volume_up_rounded,
      TalkButtonLook.handsFree => Icons.record_voice_over_rounded,
      _ => st.private ? Icons.lock_rounded : Icons.mic_rounded,
    };

    final mic = Semantics(
      button: true,
      label: st.hint,
      excludeSemantics: true,
      child: Listener(
        key: const Key('cockpit_talk_mic'),
        onPointerDown: (e) async {
          if (vox) {
            HapticFeedback.lightImpact();
            await ic.disableHandsFree();
            _note('Hands-free off · hold to talk');
            return;
          }
          if (ic.isMicMuted) {
            HapticFeedback.lightImpact();
            ic.setMicMuted(false);
            return;
          }
          _pressed = true;
          _swipeCancelled = false;
          _downPos = e.position;
          _downTime = DateTime.now();
          HapticFeedback.selectionClick();
          final ok = await ic.beginTransmission();
          if (ok && (!_pressed || _swipeCancelled)) {
            await ic.endTransmission();
            return;
          }
          if (!ok && !_swipeCancelled) _note('Cannot talk: check the microphone permission and the connection.');
        },
        onPointerMove: (e) {
          final start = _downPos;
          final at = _downTime;
          if (!_pressed || _swipeCancelled || start == null || at == null) return;
          final dy = (e.position.dy - start.dy).abs();
          final dx = (e.position.dx - start.dx).abs();
          final quick = DateTime.now().difference(at) < const Duration(milliseconds: 350);
          // A vertical drag that starts here is the rider moving the sheet, not holding to talk.
          if (dy > dx * 1.5 && ((quick && dy > 24) || dy > 48)) {
            _swipeCancelled = true;
            if (ic.isTransmitting) ic.endTransmission();
          }
        },
        onPointerUp: (_) {
          final was = _pressed;
          _pressed = false;
          if (!vox && was && ic.isTransmitting) {
            HapticFeedback.selectionClick();
            ic.endTransmission();
          }
        },
        onPointerCancel: (_) {
          _pressed = false;
          if (!vox && ic.isTransmitting) ic.endTransmission();
        },
        child: SizedBox(
          width: 60,
          height: 56,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 24, color: fg),
            Text(st.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: fg, fontWeight: FontWeight.w700, height: 1.1)),
          ]),
        ),
      ),
    );

    final options = Semantics(
      button: true,
      label: 'Talk options: hands-free, private talk, button side',
      excludeSemantics: true,
      child: InkWell(
        key: const Key('cockpit_talk_options'),
        onTap: () => showTalkOptionsSheet(context, convoy: widget.convoy, me: widget.me),
        child: SizedBox(width: 44, height: 56, child: Icon(Icons.tune_rounded, size: 22, color: fg)),
      ),
    );

    return AnimatedContainer(
      key: const Key('cockpit_talk_button'),
      duration: Motion.button,
      curve: Motion.curve,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        border: st.look == TalkButtonLook.muted ? Border.all(color: AppTheme.warnBorder, width: 2) : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          mic,
          Container(width: 1, height: 32, color: fg.withValues(alpha: 0.3)),
          options,
        ]),
      ),
    );
  }
}

/// Talk options: how I talk, who hears me, which side the button sits on. Big rows, one tap each.
Future<void> showTalkOptionsSheet(BuildContext context, {required ConvoyModel convoy, required RiderModel me}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => _TalkOptions(convoy: convoy, me: me),
  );
}

class _TalkOptions extends StatelessWidget {
  const _TalkOptions({required this.convoy, required this.me});
  final ConvoyModel convoy;
  final RiderModel me;

  @override
  Widget build(BuildContext context) {
    final ic = context.watch<IntercomService?>();
    final settings = context.watch<SettingsService?>();
    if (ic == null) return const SizedBox.shrink();
    final vox = ic.mode == IntercomMode.vox;
    final target = ic.talkTargetUserId;
    final others = [for (final r in convoy.riders.values) if (r.userId != me.userId) r]..sort((a, b) => a.name.compareTo(b.name));

    Widget modeTile({required Key key, required IconData icon, required String title, required String sub, required bool on, required VoidCallback onTap}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: Space.s8),
        child: Material(
          color: on ? AppTheme.primarySoft : AppTheme.surfaceAlt,
          shape: RoundedRectangleBorder(borderRadius: Radii.lgAll, side: BorderSide(color: on ? AppTheme.primary : AppTheme.border, width: on ? 2 : 1)),
          child: InkWell(
            key: key,
            customBorder: RoundedRectangleBorder(borderRadius: Radii.lgAll),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s8),
              child: Row(children: [
                Icon(icon, color: AppTheme.primary, size: 28),
                const SizedBox(width: Space.s12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(title, style: AppText.title.copyWith(fontSize: 16)),
                    Text(sub, style: AppText.caption),
                  ]),
                ),
                if (on) Icon(Icons.check_circle_rounded, color: AppTheme.primary),
              ]),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(Space.s16, 0, Space.s16, Space.s16 + MediaQuery.paddingOf(context).bottom),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('Talk', style: AppText.headline.copyWith(fontSize: 18)),
        const SizedBox(height: Space.s12),
        modeTile(
          key: const Key('talk_mode_hold'),
          icon: Icons.touch_app_rounded,
          title: 'Hold to talk',
          sub: 'Hold the mic button, let go to stop',
          on: !vox,
          onTap: () async {
            if (vox) await ic.disableHandsFree();
          },
        ),
        modeTile(
          key: const Key('talk_mode_hands_free'),
          icon: Icons.record_voice_over_rounded,
          title: 'Hands-free',
          sub: 'Just speak: the mic opens on your voice. Best with a helmet headset',
          on: vox,
          onTap: () async {
            if (vox) return;
            final on = await ic.toggleHandsFreeTalk();
            if (!on && context.mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Hands-free could not start: check the microphone permission and the connection.')));
            }
          },
        ),
        const SizedBox(height: Space.s8),
        Text('Who hears me', style: AppText.label.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Space.s8),
        Wrap(spacing: Space.s8, runSpacing: Space.s8, children: [
          ChoiceChip(
            key: const Key('talk_to_everyone'),
            avatar: const Icon(Icons.groups_rounded, size: 18),
            label: const Text('Everyone'),
            selected: target == null,
            materialTapTargetSize: MaterialTapTargetSize.padded,
            onSelected: (_) => ic.setTalkTarget(),
          ),
          for (final r in others)
            ChoiceChip(
              key: Key('talk_private_${r.userId}'),
              avatar: const Icon(Icons.lock_rounded, size: 16),
              label: Text(r.name.split(' ').first),
              selected: target == r.userId,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              onSelected: (_) => ic.setTalkTarget(userId: r.userId, name: r.name),
            ),
        ]),
        const SizedBox(height: Space.s4),
        Text(target == null ? 'The whole group hears you.' : 'Private: only ${ic.talkTargetName?.split(' ').first ?? 'this rider'} hears you.',
            style: AppText.caption),
        if (settings != null) ...[
          const SizedBox(height: Space.s16),
          Text('Talk button side', style: AppText.label.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Space.s8),
          SegmentedButton<bool>(
            key: const Key('talk_side'),
            segments: const [
              ButtonSegment(value: true, label: Text('Left'), icon: Icon(Icons.west_rounded)),
              ButtonSegment(value: false, label: Text('Right'), icon: Icon(Icons.east_rounded)),
            ],
            selected: {settings.cockpitControlsLeft},
            onSelectionChanged: (v) => settings.setCockpitControlsLeft(v.first),
          ),
          const SizedBox(height: Space.s4),
          Text('Left moves talk and the map buttons to the left and SOS to the right.', style: AppText.caption),
        ],
      ]),
    );
  }
}
