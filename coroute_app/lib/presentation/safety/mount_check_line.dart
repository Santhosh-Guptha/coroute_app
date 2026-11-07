import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/sensor_safety_hub.dart';
import '../../domain/safety/mount_classifier.dart';
import '../widgets/feature_switch.dart';

/// Pre-ride phone check (3.55 phone-mount check): where the phone was on the last ride, from
/// the first minutes of riding. Hidden before the first classified ride, for an unclear result,
/// or with the switch 'mountCheck' off.
class MountCheckLine extends StatefulWidget {
  /// Tests pass the result directly; otherwise it is read from the phone.
  final (MountKind, int)? result;
  const MountCheckLine({super.key, this.result});

  /// The text for a result (pure, for tests).
  static String textFor(MountKind k) => switch (k) {
        MountKind.mounted => 'Last ride: phone in a handlebar mount. Crash detection works best like this.',
        MountKind.pocket => 'Last ride: phone in a pocket. Crash detection works best with the phone in a handlebar mount.',
        MountKind.loose => 'Last ride: phone loose or in a bag. Crash detection works best with the phone in a handlebar mount.',
        MountKind.unknown => '',
      };

  @override
  State<MountCheckLine> createState() => _MountCheckLineState();
}

class _MountCheckLineState extends State<MountCheckLine> {
  (MountKind, int)? _r;

  @override
  void initState() {
    super.initState();
    _r = widget.result;
    if (_r == null) {
      MountCheckStore.load().then((v) {
        if (mounted && v != null) setState(() => _r = v);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    if (r == null || r.$1 == MountKind.unknown || !context.featureOn('mountCheck')) return const SizedBox.shrink();
    final weak = r.$1.weak;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DsCard(
        warning: weak,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(weak ? Icons.phonelink_erase_rounded : Icons.phonelink_lock_rounded,
                color: weak ? AppTheme.warnText : AppTheme.emeraldSafe, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Phone mount', style: AppText.label),
                  const SizedBox(height: 2),
                  Text(MountCheckLine.textFor(r.$1), style: AppText.caption.copyWith(color: AppTheme.text2)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
