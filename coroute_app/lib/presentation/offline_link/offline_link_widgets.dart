// Round 10 offline link: the small status chip on the ride screen ("Offline link: 5 riders, 2 hops", the walkie-talkie
// "Voice message from Ravi" and the chain-keeper note) and the group panel line ("4 of 6 phones support long range").
// Both read OfflineLinkService through Provider and show nothing when it is absent or idle.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_tokens.dart';
import '../../data/services/offline_link/offline_link_service.dart';

class OfflineLinkChip extends StatelessWidget {
  const OfflineLinkChip({super.key, this.margin});
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final link = context.watch<OfflineLinkService?>();
    if (link == null) return const SizedBox.shrink();
    return ValueListenableBuilder<String?>(
      valueListenable: link.clipNotice,
      builder: (context, clip, _) => ValueListenableBuilder<String?>(
        valueListenable: link.chainNotice,
        builder: (context, chain, _) {
          final lines = <(IconData, String, Color)>[
            if (link.chipText.isNotEmpty) (Icons.bluetooth_searching_rounded, link.chipText, AppTheme.neonCyan),
            if (clip != null) (Icons.record_voice_over_rounded, clip, AppTheme.neonCyan),
            if (chain != null) (Icons.link_off_rounded, chain, StatusColors.warning),
          ];
          if (lines.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: margin ?? EdgeInsets.zero,
            child: Wrap(
              spacing: Space.s8,
              runSpacing: Space.s8,
              children: [for (final l in lines) _Pill(icon: l.$1, text: l.$2, color: l.$3)],
            ),
          );
        },
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: text,
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: Space.s12, vertical: Space.s8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: Space.s8),
            Flexible(
              child: ExcludeSemantics(
                child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "4 of 6 phones support long range" under the group roster.
class OfflineLinkCapabilityLine extends StatelessWidget {
  const OfflineLinkCapabilityLine({super.key});

  @override
  Widget build(BuildContext context) {
    final link = context.watch<OfflineLinkService?>();
    final line = link?.capabilityLine ?? '';
    if (line.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Space.s8),
      child: Row(
        children: [
          Icon(Icons.bluetooth_rounded, size: 16, color: AppTheme.neonCyan),
          const SizedBox(width: Space.s8),
          Expanded(child: Text('Offline link: $line', style: AppText.caption)),
        ],
      ),
    );
  }
}
