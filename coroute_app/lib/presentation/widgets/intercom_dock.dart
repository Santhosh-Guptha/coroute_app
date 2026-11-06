import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/intercom_service.dart';
import '../../data/services/settings_service.dart';

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
                  label: 'Remote or headset button',
                  subtitle: settings.hardwarePtt
                      ? 'Volume down or headset button talks.'
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

/// What TalkBack reads for the SOS button on the ride map.
const String sosSemanticsLabel = 'Send SOS to your group';

