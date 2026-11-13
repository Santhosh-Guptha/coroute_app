// Round 10 rescue finder: the "Find Ravi" button on another rider's SOS (incident sheet) and on an
// accepted nearby-rider request (assist sheet). Shows nothing when the finder is not available or the
// alert is not open.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/services/rescue_finder_service.dart';
import 'rescue_finder_screen.dart';

class FindRiderButton extends StatelessWidget {
  const FindRiderButton({super.key, this.alertId, this.incidentId});

  /// A group alert, or a nearby-rider incident (one of the two).
  final String? alertId;
  final String? incidentId;

  @override
  Widget build(BuildContext context) {
    final f = context.watch<RescueFinderService?>();
    if (f == null) return const SizedBox.shrink();
    RescueTarget? t;
    if (incidentId != null && incidentId!.isNotEmpty) {
      t = f.assistTarget(incidentId!);
    } else {
      for (final x in f.targets) {
        if (x.alertId == alertId) {
          t = x;
          break;
        }
      }
    }
    final target = t;
    if (target == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        height: 64,
        child: FilledButton.tonalIcon(
          onPressed: () => RescueFinderScreen.open(context, target),
          icon: const Icon(Icons.radar_rounded, size: 26),
          label: Text('Find ${target.firstName}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }
}
