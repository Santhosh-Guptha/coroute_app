import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_bottom_sheet.dart';
import '../../core/ui/rider_avatar.dart';
import '../../core/ui/ui_tokens.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/intercom_service.dart';

/// The voice intercom as one row for the ride screen:
///
/// * "Talk to" picker: everyone, or one rider for a private 1:1 channel.
/// * The talk button (hold to talk, or the hands-free switch), 56 dp.
/// * Mute.
///
/// One optional line above the row says who is speaking, that someone else
/// holds the channel, or that the radio is reconnecting. The talk mode and
/// "hear the group" live in [IntercomOptions] (opened from the ride sheet).
/// SOS is not here: it is the hold-to-send SOS button on the ride map.
class IntercomDock extends StatelessWidget {
  final ConvoyModel convoy;
  final RiderModel me;

  /// Not used any more (SOS is the hold-to-send button on the ride map).
  /// Kept so older callers compile; it can be removed once none pass it.
  final VoidCallback? onSos;

  /// True inside the ride sheet: no own background, no safe-area padding.
  final bool compact;

  const IntercomDock({super.key, required this.convoy, required this.me, this.onSos, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final ic = context.watch<IntercomService>();
    final others = convoy.riders.values.where((r) => r.userId != me.userId).toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    Widget? notice;
    if (ic.isReceiving) {
      final private = ic.activeSpeakerIsPrivate;
      notice = _Notice(
        icon: private ? Icons.lock_rounded : Icons.graphic_eq_rounded,
        text: private ? '${ic.activeSpeakerName ?? 'A rider'}, private to you' : '${ic.activeSpeakerName ?? 'A rider'} is speaking',
        color: private ? StatusColors.info : AppTheme.neonCyan,
      );
    } else if (ic.busyWith != null) {
      notice = _Notice(icon: Icons.hourglass_top_rounded, text: '${ic.busyWith} is talking, wait for a gap', color: StatusColors.warning);
    } else if (!ic.isOnline) {
      notice = _Notice(icon: Icons.cloud_off_rounded, text: 'Reconnecting to convoy radio', color: AppTheme.textSecondary);
    }

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?notice,
        Row(
          children: [
            Expanded(child: _TalkTargetChip(others: others, ic: ic)),
            const SizedBox(width: Space.s8),
            Expanded(child: ic.mode == IntercomMode.ptt ? _PttButton(ic: ic) : _VoxButton(ic: ic)),
            const SizedBox(width: Space.s4),
            IconButton(
              tooltip: ic.isMicMuted ? 'Unmute microphone' : 'Mute microphone',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: Icon(ic.isMicMuted ? Icons.mic_off_rounded : Icons.mic_rounded, color: ic.isMicMuted ? StatusColors.critical : AppTheme.textPrimary),
              onPressed: () => ic.setMicMuted(!ic.isMicMuted),
            ),
          ],
        ),
      ],
    );

    if (compact) return content;
    return Container(
      padding: const EdgeInsets.fromLTRB(Space.s12, Space.s8, Space.s12, Space.s8),
      decoration: BoxDecoration(
        color: AppTheme.slateCard,
        border: Border(top: BorderSide(color: AppTheme.subtleBorder)),
      ),
      child: SafeArea(top: false, child: content),
    );
  }
}

/// Talk mode and "hear the group", shown in a sheet from the ride sheet.
class IntercomOptions extends StatelessWidget {
  const IntercomOptions({super.key});

  static Future<void> show(BuildContext context) =>
      showAppSheet<void>(context, title: 'Intercom options', builder: (_) => const IntercomOptions());

  @override
  Widget build(BuildContext context) {
    final ic = context.watch<IntercomService>();
    Widget mode(String title, String subtitle, IntercomMode m, IconData icon) {
      final selected = ic.mode == m;
      return ListTile(
        minVerticalPadding: Space.s12,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: selected ? AppTheme.neonCyan : AppTheme.textSecondary),
        title: Text(title, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: AppText.caption),
        trailing: Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
            color: selected ? AppTheme.neonCyan : AppTheme.textSecondary),
        selected: selected,
        onTap: () {
          if (m == IntercomMode.vox) {
            ic.startVox();
          } else {
            ic.setMode(IntercomMode.ptt);
          }
        },
      );
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          mode('Hold to talk', 'Press and hold the talk button while you speak.', IntercomMode.ptt, Icons.touch_app_rounded),
          mode('Hands-free', 'Sends only while you speak. Uses more battery.', IntercomMode.vox, Icons.record_voice_over_rounded),
          const Divider(),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Hear the group', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            subtitle: Text(ic.isDeafened ? 'Group audio is off.' : 'You hear riders who talk.', style: AppText.caption),
            value: !ic.isDeafened,
            onChanged: (v) => ic.setDeafened(!v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Microphone', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            subtitle: Text(ic.isMicMuted ? 'Muted. The group cannot hear you.' : 'On while you talk.', style: AppText.caption),
            value: !ic.isMicMuted,
            onChanged: (v) => ic.setMicMuted(!v),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _Notice({required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: Space.s8),
        child: Row(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: Space.s8),
            Expanded(
              child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: color)),
            ),
          ],
        ),
      ),
    );
  }
}

class _TalkTargetChip extends StatelessWidget {
  final List<RiderModel> others;
  final IntercomService ic;
  const _TalkTargetChip({required this.others, required this.ic});

  @override
  Widget build(BuildContext context) {
    final private = ic.isPrivateTalk;
    final label = private ? 'Private: ${ic.talkTargetName ?? 'rider'}' : 'Talk to: Everyone';
    final Color color = private ? StatusColors.info : AppTheme.textPrimary;
    return Semantics(
      button: true,
      label: '$label. Double tap to choose who hears you.',
      excludeSemantics: true,
      onTap: () => _pickTarget(context),
      child: Material(
      color: AppTheme.elevatedCard,
      shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: private ? StatusColors.info : AppTheme.subtleBorder)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _pickTarget(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.s8),
            child: Row(
              children: [
                Icon(private ? Icons.lock_rounded : Icons.groups_rounded, size: 20, color: color),
                const SizedBox(width: Space.s4),
                Expanded(
                  child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: color)),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  void _pickTarget(BuildContext context) {
    showAppSheet<void>(
      context,
      title: 'Who should hear you?',
      isScrollControlled: true,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.groups_rounded, color: AppTheme.neonCyan),
            title: Text('Everyone in the convoy', style: AppText.body),
            subtitle: Text('Group channel', style: AppText.caption),
            trailing: !ic.isPrivateTalk ? Icon(Icons.check_rounded, color: AppTheme.neonCyan) : null,
            onTap: () {
              ic.setTalkTarget();
              Navigator.pop(ctx);
            },
          ),
          if (others.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.s16),
              child: Text('No other riders online yet.', style: AppText.body.copyWith(color: AppTheme.textSecondary)),
            ),
          for (final r in others)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: RiderAvatar(name: r.name, size: 40),
              title: Text(r.name, style: AppText.body),
              subtitle: Text('Private channel, only ${r.name.split(' ').first} hears you', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
              trailing: ic.talkTargetUserId == r.userId ? Icon(Icons.check_rounded, color: StatusColors.info) : null,
              onTap: () {
                ic.setTalkTarget(userId: r.userId, name: r.name);
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  }
}

class _PttButton extends StatelessWidget {
  final IntercomService ic;
  const _PttButton({required this.ic});

  @override
  Widget build(BuildContext context) {
    final tx = ic.isTransmitting;
    final private = ic.isPrivateTalk;
    final Color activeColor = private ? StatusColors.info : StatusColors.success;
    // Screen readers cannot hold a finger down: for them a double tap starts talking and
    // another double tap stops.
    return Semantics(
      button: true,
      label: pttSemanticsLabel(private ? ic.talkTargetName : null),
      hint: tx ? 'Double tap to stop talking' : 'Double tap to start talking',
      excludeSemantics: true,
      onTap: () {
        if (ic.isTransmitting) {
          ic.endTransmission();
        } else if (!ic.isMicMuted) {
          ic.beginTransmission();
        }
      },
      child: Listener(
        onPointerDown: (_) async {
          if (ic.isMicMuted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Microphone is muted.'), duration: Duration(seconds: 1)));
            return;
          }
          // No haptic on every press (haptics are kept for SOS, confirmations and critical alerts).
          final ok = await ic.beginTransmission();
          if (!ok && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Cannot transmit: check microphone permission and connection.'),
              duration: Duration(seconds: 2),
            ));
          }
        },
        onPointerUp: (_) => ic.endTransmission(),
        onPointerCancel: (_) => ic.endTransmission(),
        child: AnimatedContainer(
          duration: Motion.button,
          curve: Motion.curve,
          height: 56,
          decoration: BoxDecoration(
            color: tx ? activeColor : AppTheme.neonCyan,
            borderRadius: Radii.mdAll,
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.s8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(tx ? Icons.mic_rounded : (private ? Icons.lock_rounded : Icons.mic_none_rounded), size: 20, color: Colors.black),
                  const SizedBox(width: Space.s4),
                  Flexible(
                    // Scales down instead of cutting the words on a narrow phone.
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        tx ? (private ? 'PRIVATE, TALKING' : 'TALKING') : 'HOLD TO TALK',
                        maxLines: 1,
                        softWrap: false,
                        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 14),
                      ),
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

class _VoxButton extends StatelessWidget {
  final IntercomService ic;
  const _VoxButton({required this.ic});

  @override
  Widget build(BuildContext context) {
    final armed = ic.isVoxArmed && !ic.isMicMuted;
    final tx = ic.isTransmitting;
    final Color color = tx ? StatusColors.success : (armed ? AppTheme.neonCyan : AppTheme.textSecondary);
    final text = tx ? 'Hands-free, sending' : (armed ? 'Hands-free on' : 'Hands-free off');
    return Semantics(
      button: true,
      toggled: armed,
      label: text,
      hint: armed ? 'Double tap to stop hands-free' : 'Double tap to start hands-free',
      excludeSemantics: true,
      onTap: () => armed ? ic.stopVox() : ic.startVox(),
      child: Material(
        color: color.withOpacity(0.16),
        shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: color, width: 1.5)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => armed ? ic.stopVox() : ic.startVox(),
          child: SizedBox(
            height: 56,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.s8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(tx ? Icons.graphic_eq_rounded : (armed ? Icons.hearing_rounded : Icons.mic_off_rounded), size: 20, color: color),
                  const SizedBox(width: Space.s4),
                  Flexible(
                    child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: AppTheme.textPrimary)),
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

/// What TalkBack reads for the SOS button on the ride map.
const String sosSemanticsLabel = 'Send SOS to your convoy';

/// What TalkBack reads for the talk button: who will hear you.
String pttSemanticsLabel(String? privateTarget) =>
    'Hold to talk to ${privateTarget == null || privateTarget.isEmpty ? 'everyone' : privateTarget}';
