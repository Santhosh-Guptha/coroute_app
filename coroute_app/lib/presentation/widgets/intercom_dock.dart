import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/intercom_service.dart';

/// Shared voice-intercom control bar used by the dashboard and the cockpit map.
///
/// * "Talk to" picker: everyone, or one rider for a private 1:1 channel.
/// * PTT (hold) or VOX (hands-free, transmits only while you speak).
/// * Mute / deafen, live "who is speaking" badge, busy indicator.
/// * Optional SOS button via [onSos].
class IntercomDock extends StatelessWidget {
  final ConvoyModel convoy;
  final RiderModel me;
  final VoidCallback? onSos;
  final bool compact;

  const IntercomDock({super.key, required this.convoy, required this.me, this.onSos, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final ic = context.watch<IntercomService>();
    final others = convoy.riders.values.where((r) => r.userId != me.userId).toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14, vertical: compact ? 6 : 10),
      decoration: BoxDecoration(
        color: AppTheme.slateCard,
        border: Border(top: BorderSide(color: AppTheme.glassBorder)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (ic.isReceiving) _SpeakerBadge(name: ic.activeSpeakerName!, isPrivate: ic.activeSpeakerIsPrivate),
            if (ic.busyWith != null) _InfoChip(icon: Icons.hourglass_top_rounded, text: '${ic.busyWith} is talking, wait for a gap', color: AppTheme.hyperAmber),
            if (!ic.isOnline) _InfoChip(icon: Icons.cloud_off_rounded, text: 'Reconnecting to convoy radio…', color: AppTheme.textMuted),
            Row(
              children: [
                Expanded(child: _TalkTargetChip(others: others, ic: ic)),
                const SizedBox(width: 6),
                _ModeToggle(ic: ic),
              ],
            ),
            SizedBox(height: compact ? 6 : 8),
            Row(
              children: [
                IconButton(
                  tooltip: ic.isMicMuted ? 'Unmute microphone' : 'Mute microphone',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(ic.isMicMuted ? Icons.mic_off_rounded : Icons.mic_rounded, color: ic.isMicMuted ? AppTheme.laserRed : AppTheme.neonCyan),
                  onPressed: () => ic.setMicMuted(!ic.isMicMuted),
                ),
                IconButton(
                  tooltip: ic.isDeafened ? 'Hear convoy' : 'Deafen',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(ic.isDeafened ? Icons.volume_off_rounded : Icons.volume_up_rounded, color: ic.isDeafened ? AppTheme.laserRed : AppTheme.textPrimary),
                  onPressed: () => ic.setDeafened(!ic.isDeafened),
                ),
                Expanded(child: ic.mode == IntercomMode.ptt ? _PttButton(ic: ic) : _VoxButton(ic: ic)),
                if (onSos != null) ...[
                  const SizedBox(width: 8),
                  Semantics(
                    button: true,
                    label: sosSemanticsLabel,
                    onTap: onSos,
                    excludeSemantics: true,
                    child: ElevatedButton(
                      onPressed: onSos,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.laserRed,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        minimumSize: const Size(56, 44),
                      ),
                      child: const Text('SOS', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SpeakerBadge extends StatelessWidget {
  final String name;
  final bool isPrivate;
  const _SpeakerBadge({required this.name, required this.isPrivate});

  @override
  Widget build(BuildContext context) {
    final color = isPrivate ? AppTheme.devmonksPurple : AppTheme.neonCyan;
    return _InfoChip(
      icon: isPrivate ? Icons.lock_rounded : Icons.graphic_eq_rounded,
      text: isPrivate ? '$name, private to you' : '$name is speaking',
      color: color,
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _InfoChip({required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 15),
          const SizedBox(width: 8),
          Flexible(
            child: Text(text, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
          ),
        ],
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
    final color = private ? AppTheme.devmonksPurple : AppTheme.neonCyan;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _pickTarget(context),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.7)),
        ),
        child: Row(
          children: [
            Icon(private ? Icons.person_rounded : Icons.groups_rounded, size: 15, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            Icon(Icons.expand_more_rounded, size: 16, color: color),
          ],
        ),
      ),
    );
  }

  void _pickTarget(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.slateCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        final maxH = MediaQuery.of(ctx).size.height * 0.6;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Text('Who should hear you?', style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.bold)),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      ListTile(
                        leading: Icon(Icons.groups_rounded, color: AppTheme.neonCyan),
                        title: Text('Everyone in the convoy', style: TextStyle(color: AppTheme.textPrimary)),
                        subtitle: Text('Group channel', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                        trailing: !ic.isPrivateTalk ? Icon(Icons.check_rounded, color: AppTheme.neonCyan) : null,
                        onTap: () {
                          ic.setTalkTarget();
                          Navigator.pop(ctx);
                        },
                      ),
                      if (others.isEmpty)
                        Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('No other riders online yet.', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                        ),
                      for (final r in others)
                        ListTile(
                          leading: Icon(Icons.person_rounded, color: AppTheme.devmonksPurple),
                          title: Text(r.name, style: TextStyle(color: AppTheme.textPrimary)),
                          subtitle: Text('Private 1:1 • ${r.role} • ${r.vehicleType}', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                          trailing: ic.talkTargetUserId == r.userId ? Icon(Icons.check_rounded, color: AppTheme.devmonksPurple) : null,
                          onTap: () {
                            ic.setTalkTarget(userId: r.userId, name: r.name);
                            Navigator.pop(ctx);
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ModeToggle extends StatelessWidget {
  final IntercomService ic;
  const _ModeToggle({required this.ic});

  @override
  Widget build(BuildContext context) {
    Widget seg(String text, IconData icon, IntercomMode mode, Color color) {
      final selected = ic.mode == mode;
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          if (mode == IntercomMode.vox) {
            ic.startVox();
          } else {
            ic.setMode(IntercomMode.ptt);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? color.withOpacity(0.2) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: selected ? Border.all(color: color) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: selected ? color : AppTheme.textMuted),
              const SizedBox(width: 4),
              Text(text, style: TextStyle(color: selected ? color : AppTheme.textMuted, fontWeight: FontWeight.bold, fontSize: 11)),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppTheme.elevatedCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg('PTT', Icons.touch_app_rounded, IntercomMode.ptt, AppTheme.neonCyan),
          const SizedBox(width: 3),
          seg('VOX', Icons.record_voice_over_rounded, IntercomMode.vox, AppTheme.hyperAmber),
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
    final activeColor = private ? AppTheme.devmonksPurple : AppTheme.emeraldSafe;
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
        HapticFeedback.heavyImpact();
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
        duration: const Duration(milliseconds: 120),
        height: 44,
        decoration: BoxDecoration(
          color: tx ? activeColor : AppTheme.devmonksPurple.withOpacity(0.3),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: tx ? activeColor : AppTheme.devmonksPurple, width: tx ? 2 : 1),
          boxShadow: tx ? [BoxShadow(color: activeColor.withOpacity(0.4), blurRadius: 10, spreadRadius: 2)] : null,
        ),
        child: Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(tx ? Icons.mic_rounded : Icons.radio_button_checked_rounded, size: 16, color: tx ? Colors.black : AppTheme.textPrimary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  tx ? (private ? 'PRIVATE, TALKING…' : 'TRANSMITTING…') : 'HOLD TO TALK',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tx ? Colors.black : AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ],
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
    final color = tx ? AppTheme.emeraldSafe : (armed ? AppTheme.hyperAmber : AppTheme.textMuted);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => armed ? ic.stopVox() : ic.startVox(),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: color.withOpacity(0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color, width: 1.5),
          boxShadow: tx ? [BoxShadow(color: color.withOpacity(0.35), blurRadius: 8, spreadRadius: 1)] : null,
        ),
        child: Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(tx ? Icons.graphic_eq_rounded : (armed ? Icons.hearing_rounded : Icons.mic_off_rounded), size: 18, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  tx ? 'VOX, SENDING' : (armed ? 'VOX ARMED (tap to stop)' : 'VOX OFF (tap to arm)'),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What TalkBack reads for the SOS button.
const String sosSemanticsLabel = 'Send SOS to your convoy';

/// What TalkBack reads for the talk button: who will hear you.
String pttSemanticsLabel(String? privateTarget) =>
    'Hold to talk to ${privateTarget == null || privateTarget.isEmpty ? 'everyone' : privateTarget}';
