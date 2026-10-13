import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/intercom_service.dart';
import '../../data/services/settings_service.dart';

/// The voice intercom, styled after the "Intercom" canvas sheet:
///
/// * The talk button (hold to talk, or the hands-free switch): a solid teal
///   block that turns amber while you talk.
/// * "Talk to" picker: everyone, or one rider for a private 1:1 channel.
/// * Mute.
///
/// One optional line says who is speaking (with their initials), that
/// someone else holds the channel, or that the radio is reconnecting. The
/// talk mode and "hear the group" live in [IntercomOptions] (opened from the
/// ride sheet). SOS is not here: it is the hold-to-send SOS button on the
/// ride map.
///
/// [compact] (inside the ride sheet) is one 56 dp row. Otherwise the dock is
/// the full sheet card: 28 dp top corners, the 44 x 5 handle, the "Intercom"
/// header with the radio state, and the big 96 dp push-to-talk block.
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
    final isLeader = me.role == 'LEAD' || me.role == 'SWEEPER' || me.userId == convoy.createdByUserId;

    Widget? notice;
    if (ic.isReceiving) {
      final private = ic.activeSpeakerIsPrivate;
      final leadOnly = ic.isReceivingLeadOnly;
      final who = ic.activeSpeakerName ?? 'A rider';
      notice = _Notice(
        icon: private ? Icons.lock_rounded : (leadOnly ? Icons.shield_rounded : Icons.graphic_eq_rounded),
        initials: ic.activeSpeakerName,
        text: private
            ? '$who, private to you'
            : (leadOnly ? '$who (Lead & Sweeper channel)' : '$who is speaking'),
        color: private ? StatusColors.info : (leadOnly ? AppTheme.warnText : AppTheme.accentText),
      );
    } else if (ic.busyWith != null) {
      notice = _Notice(
        icon: Icons.hourglass_top_rounded,
        initials: ic.busyWith,
        text: '${ic.busyWith} is talking, wait for a gap',
        color: AppTheme.warnText,
      );
    } else if (!ic.isOnline) {
      notice = _Notice(icon: Icons.cloud_off_rounded, text: 'Reconnecting to convoy radio', color: AppTheme.muted);
    }

    final isShort = MediaQuery.sizeOf(context).height < 500;
    final big = !compact && !isShort;
    final talk = ic.mode == IntercomMode.ptt ? _PttButton(ic: ic, big: big) : _VoxButton(ic: ic, big: big);
    final mute = _MuteButton(ic: ic);

    final channelSelector = isLeader
        ? DsSegment<IntercomChannel>(
            values: const [IntercomChannel.all, IntercomChannel.leadOnly],
            selected: ic.channel,
            label: (c) => c == IntercomChannel.all ? 'All Convoy' : 'Lead & Sweeper',
            onChanged: (c) => ic.setChannel(c),
          )
        : null;

    if (compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?notice,
          if (channelSelector != null) ...[
            channelSelector,
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(child: _TalkTargetChip(others: others, ic: ic)),
              const SizedBox(width: 10),
              Expanded(child: talk),
              const SizedBox(width: 6),
              mute,
            ],
          ),
        ],
      );
    }

    final channelDesc = ic.channel == IntercomChannel.leadOnly ? 'Lead & Sweeper' : 'All Convoy';
    final subtitle = ic.isOnline
        ? (ic.isPrivateTalk ? 'Private channel · ${ic.talkTargetName ?? 'rider'}' : 'Convoy radio · $channelDesc')
        : 'Convoy radio · no signal';

    return Material(
      color: AppTheme.card,
      shape: RoundedRectangleBorder(borderRadius: Radii.sheetTop, side: BorderSide(color: AppTheme.border, width: 2)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, isShort ? 8 : 12, 20, isShort ? 12 : 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SheetHandle(),
              SizedBox(height: isShort ? 8 : 14),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(header: true, child: Text('Intercom', style: AppText.headline)),
                        const SizedBox(height: 2),
                        Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
                      ],
                    ),
                  ),
                  mute,
                ],
              ),
              if (channelSelector != null) ...[
                SizedBox(height: isShort ? 8 : 12),
                channelSelector,
              ],
              SizedBox(height: isShort ? 10 : 18),
              talk,
              SizedBox(height: isShort ? 8 : 12),
              _TalkTargetChip(others: others, ic: ic),
              if (notice != null) ...[
                SizedBox(height: isShort ? 8 : 14),
                notice,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Talk mode and "hear the group", shown in a sheet from the ride sheet.
/// Styled like the canvas settings group: a `bg` filled block with switch
/// rows, and a two-way segment for the talk mode.
class IntercomOptions extends StatelessWidget {
  const IntercomOptions({super.key});

  static Future<void> show(BuildContext context) =>
      showAppSheet<void>(context, title: 'Intercom options', builder: (_) => const IntercomOptions());

  @override
  Widget build(BuildContext context) {
    final ic = context.watch<IntercomService>();
    final settings = context.watch<SettingsService>();
    final vox = ic.mode == IntercomMode.vox;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const DsSectionHeader('Talk mode'),
          const SizedBox(height: 10),
          DsSegment<IntercomMode>(
            values: const [IntercomMode.ptt, IntercomMode.vox],
            selected: ic.mode,
            label: (m) => m == IntercomMode.ptt ? 'Hold to talk' : 'Hands-free',
            onChanged: (m) {
              if (m == IntercomMode.vox) {
                ic.startVox();
              } else {
                ic.setMode(IntercomMode.ptt);
              }
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(vox ? Icons.record_voice_over_rounded : Icons.touch_app_rounded, size: 18, color: AppTheme.accentText),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  vox ? 'Sends only while you speak. Uses more battery.' : 'Press and hold the talk button while you speak.',
                  style: AppText.caption,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const DsSectionHeader('Audio & Controls'),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(color: AppTheme.bg, borderRadius: BorderRadius.circular(Radii.lg)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DsSwitchRow(
                  label: 'Hear the group',
                  subtitle: ic.isDeafened ? 'Group audio is off.' : 'You hear riders who talk.',
                  value: !ic.isDeafened,
                  onChanged: (v) => ic.setDeafened(!v),
                ),
                DsSwitchRow(
                  label: 'Microphone',
                  subtitle: ic.isMicMuted ? 'Muted. The group cannot hear you.' : 'On while you talk.',
                  value: !ic.isMicMuted,
                  onChanged: (v) => ic.setMicMuted(!v),
                ),
                DsSwitchRow(
                  label: 'Handlebar / Headset PTT',
                  subtitle: settings.hardwarePtt
                      ? 'Volume down or headset media button acts as push-to-talk.'
                      : 'Disabled. Use on-screen talk button.',
                  value: settings.hardwarePtt,
                  onChanged: (v) => settings.setHardwarePtt(v),
                  divider: false,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 44,
        height: 5,
        decoration: BoxDecoration(color: AppTheme.border2, borderRadius: BorderRadius.circular(3)),
      ),
    );
  }
}

/// The 48 dp round mute button with its tooltip.
class _MuteButton extends StatelessWidget {
  final IntercomService ic;
  const _MuteButton({required this.ic});

  @override
  Widget build(BuildContext context) {
    final muted = ic.isMicMuted;
    return Material(
      color: muted ? AppTheme.warnTint : AppTheme.soft,
      shape: CircleBorder(side: BorderSide(color: muted ? AppTheme.warnBorder : AppTheme.border, width: 2)),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        tooltip: muted ? 'Unmute microphone' : 'Mute microphone',
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        icon: Icon(muted ? Icons.mic_off_rounded : Icons.mic_rounded, size: 22, color: muted ? AppTheme.warnText : AppTheme.accentText),
        onPressed: () => ic.setMicMuted(!ic.isMicMuted),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  final String? initials;
  const _Notice({required this.icon, required this.text, required this.color, this.initials});

  @override
  Widget build(BuildContext context) {
    final who = initials;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            if (who != null && who.trim().isNotEmpty) ...[
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color, border: Border.all(color: AppTheme.card, width: 2)),
                child: Text(
                  initialsOf(who),
                  textScaler: TextScaler.noScaling,
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.label.copyWith(color: color, fontWeight: FontWeight.w700),
              ),
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
    final Color color = private ? StatusColors.info : AppTheme.text;
    return Semantics(
      button: true,
      label: '$label. Double tap to choose who hears you.',
      excludeSemantics: true,
      onTap: () => _pickTarget(context),
      child: Material(
        color: private ? AppTheme.tint : AppTheme.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(color: private ? StatusColors.info : AppTheme.border, width: 2),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _pickTarget(context),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(private ? Icons.lock_rounded : Icons.groups_rounded, size: 22, color: private ? StatusColors.info : AppTheme.accentText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.label.copyWith(color: color, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Icon(Icons.expand_more_rounded, size: 20, color: AppTheme.muted),
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
            leading: Icon(Icons.groups_rounded, color: AppTheme.accentText),
            title: Text('Everyone in the convoy', style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
            subtitle: Text('Group channel', style: AppText.caption),
            trailing: !ic.isPrivateTalk ? Icon(Icons.check_rounded, color: AppTheme.accentText) : null,
            onTap: () {
              ic.setTalkTarget();
              Navigator.pop(ctx);
            },
          ),
          if (others.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('No other riders online yet.', style: AppText.body.copyWith(color: AppTheme.text2)),
            ),
          for (final r in others)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: DsAvatar(initialsOf(r.name), size: 40),
              title: Text(r.name, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
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

  /// The 96 dp sheet block (icon, label and hint) instead of the 56 dp row button.
  final bool big;
  const _PttButton({required this.ic, this.big = false});

  @override
  Widget build(BuildContext context) {
    final tx = ic.isTransmitting;
    final private = ic.isPrivateTalk;
    final leadChannel = ic.channel == IntercomChannel.leadOnly;
    final Color activeColor = private ? StatusColors.info : AppTheme.warnText;
    final label = tx
        ? (private ? 'PRIVATE, TALKING' : (leadChannel ? 'LEAD TALKING' : 'TALKING'))
        : (leadChannel ? 'LEAD & SWEEPER TALK' : 'HOLD TO TALK');
    final hint = tx
        ? 'Release to stop'
        : (private
            ? 'Only ${ic.talkTargetName ?? 'this rider'} hears you'
            : (leadChannel ? 'Only leaders hear you' : 'Hold while you speak'));
    final IconData icon = tx ? Icons.mic_rounded : (private ? Icons.lock_rounded : (leadChannel ? Icons.shield_rounded : Icons.mic_none_rounded));
    final Color idleColor = leadChannel ? const Color(0xFFD97706) : AppTheme.brand;
    // Screen readers cannot hold a finger down: for them a double tap starts talking and
    // another double tap stops.
    return Semantics(
      button: true,
      label: pttSemanticsLabel(private ? ic.talkTargetName : (leadChannel ? 'leaders' : null)),
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
          height: big ? 96 : 56,
          decoration: BoxDecoration(
            color: tx ? activeColor : idleColor,
            borderRadius: BorderRadius.circular(big ? 20 : 16),
          ),
          child: Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: big ? 16 : 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: big ? 34 : 22, color: Colors.white),
                  SizedBox(width: big ? 14 : 6),
                  Flexible(
                    child: big
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  softWrap: false,
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20, letterSpacing: 0.5),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                hint,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: Colors.white.withOpacity(0.85), fontWeight: FontWeight.w600, fontSize: 13),
                              ),
                            ],
                          )
                        // Scales down instead of cutting the words on a narrow phone.
                        : FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              label,
                              maxLines: 1,
                              softWrap: false,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14, letterSpacing: 0.5),
                            ),
                          ),
                  ),
                  if (tx) ...[
                    SizedBox(width: big ? 12 : 6),
                    _AudioVuMeter(audioLevel: ic.audioLevel, height: big ? 24 : 16),
                  ],
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
  final bool big;
  const _VoxButton({required this.ic, this.big = false});

  @override
  Widget build(BuildContext context) {
    final armed = ic.isVoxArmed && !ic.isMicMuted;
    final tx = ic.isTransmitting;
    final leadChannel = ic.channel == IntercomChannel.leadOnly;
    final Color armedColor = leadChannel ? const Color(0xFFD97706) : AppTheme.brand;
    final Color color = tx ? AppTheme.warnText : (armed ? armedColor : AppTheme.muted);
    final text = tx
        ? (leadChannel ? 'Lead channel, sending' : 'Hands-free, sending')
        : (armed ? (leadChannel ? 'Hands-free (Lead)' : 'Hands-free on') : 'Hands-free off');
    final hint = tx
        ? (leadChannel ? 'Sending to leaders' : 'Sending while you speak')
        : (armed ? 'Tap to stop' : 'Tap to start');
    final IconData icon = tx ? Icons.graphic_eq_rounded : (armed ? (leadChannel ? Icons.shield_rounded : Icons.hearing_rounded) : Icons.mic_off_rounded);
    final solid = tx || armed;
    final Color fg = solid ? Colors.white : AppTheme.text;
    return Semantics(
      button: true,
      toggled: armed,
      label: text,
      hint: armed ? 'Double tap to stop hands-free' : 'Double tap to start hands-free',
      excludeSemantics: true,
      onTap: () => armed ? ic.stopVox() : ic.startVox(),
      child: Material(
        color: solid ? color : AppTheme.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(big ? 20 : 16),
          side: BorderSide(color: solid ? color : AppTheme.border, width: 2),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => armed ? ic.stopVox() : ic.startVox(),
          child: SizedBox(
            height: big ? 96 : 56,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: big ? 16 : 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: big ? 34 : 22, color: solid ? Colors.white : AppTheme.accentText),
                  SizedBox(width: big ? 14 : 6),
                  Flexible(
                    child: big
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontSize: 20, fontWeight: FontWeight.w800)),
                              const SizedBox(height: 2),
                              Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg.withOpacity(0.85), fontSize: 13, fontWeight: FontWeight.w600)),
                            ],
                          )
                        : Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: fg, fontWeight: FontWeight.w800)),
                  ),
                  if (tx) ...[
                    SizedBox(width: big ? 12 : 6),
                    _AudioVuMeter(audioLevel: ic.audioLevel, height: big ? 24 : 16),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Live 5-bar VU meter for the microphone audio level [0.0 .. 1.0].
/// Renders purely through a [ValueListenableBuilder] so audio level updates
/// don't cause parent widgets to rebuild.
class _AudioVuMeter extends StatelessWidget {
  final ValueNotifier<double> audioLevel;
  final double height;

  const _AudioVuMeter({
    required this.audioLevel,
    this.height = 18,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: audioLevel,
      builder: (context, level, _) {
        return SizedBox(
          height: height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(5, (i) {
              final threshold = (i + 1) * 0.16;
              final active = level >= threshold;
              const barWeights = [0.5, 0.8, 1.0, 0.8, 0.5];
              final maxH = barWeights[i] * height;
              final barH = active
                  ? maxH
                  : (maxH * 0.35 + (maxH * 0.65 * (level / threshold).clamp(0.0, 1.0))).clamp(3.0, maxH);

              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                width: 3.5,
                height: barH,
                decoration: BoxDecoration(
                  color: active ? Colors.white : Colors.white.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}

/// What TalkBack reads for the SOS button on the ride map.
const String sosSemanticsLabel = 'Send SOS to your convoy';

/// What TalkBack reads for the talk button: who will hear you.
String pttSemanticsLabel(String? privateTarget) =>
    'Hold to talk to ${privateTarget == null || privateTarget.isEmpty ? 'everyone' : privateTarget}';
