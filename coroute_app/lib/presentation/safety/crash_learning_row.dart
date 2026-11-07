import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/safety_service.dart';
import '../../data/services/sensor_safety_hub.dart';
import '../../domain/safety/crash_learning.dart';
import '../widgets/feature_switch.dart';

/// Settings > Safety, under crash detection (3.55 crash detection that learns): a read-only
/// line "Learned from N false alarms on this bike" with "Reset learning". Hidden when nothing
/// was learned, when the admin switch 'crashLearning' is off, or without a SafetyService.
class CrashLearningRow extends StatefulWidget {
  /// Tests pass a hub directly; otherwise SafetyService's is used.
  final SensorSafetyHub? hub;
  const CrashLearningRow({super.key, this.hub});

  @override
  State<CrashLearningRow> createState() => _CrashLearningRowState();
}

class _CrashLearningRowState extends State<CrashLearningRow> {
  CrashLearningState? _state;
  SensorSafetyHub? _hub;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    SensorSafetyHub? hub = widget.hub;
    if (hub == null) {
      try {
        hub = context.read<SafetyService?>()?.sensorSafety;
      } catch (_) {
        hub = null;
      }
    }
    if (!identical(hub, _hub)) {
      _hub = hub;
      _load();
    }
  }

  Future<void> _load() async {
    final hub = _hub;
    if (hub == null) return;
    final s = await hub.learningForActiveBike();
    if (mounted) setState(() => _state = s);
  }

  Future<void> _reset() async {
    final hub = _hub;
    if (hub == null || _busy) return;
    setState(() => _busy = true);
    await hub.resetLearning();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _state = CrashLearningState.none;
    });
  }

  @override
  Widget build(BuildContext context) {
    final line = _state == null ? null : CrashLearning.settingsLine(_state!);
    if (line == null || !context.featureOn('crashLearning')) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
      padding: const EdgeInsets.symmetric(vertical: Space.s8),
      child: Row(
        children: [
          Icon(Icons.tune_rounded, color: AppTheme.accentText, size: 22),
          const SizedBox(width: Space.s16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(line, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                Text('Fewer false alarms for low-speed falls and slides. Hard impacts always alarm.',
                    maxLines: 4, overflow: TextOverflow.ellipsis, style: AppText.caption),
              ],
            ),
          ),
          const SizedBox(width: Space.s8),
          TextButton(onPressed: _busy ? null : _reset, child: const Text('Reset learning')),
        ],
      ),
    );
  }
}
