import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/feature_flags_service.dart';

/// 3.55 admin feature switches in widgets.
///
/// `context.featureOn('rideRoles')` watches [FeatureFlagsService] (rebuilds when a switch changes)
/// and is true when the feature is on, unknown, or when no service is provided (widget tests, older
/// trees): a missing provider never hides anything.
extension FeatureSwitchContext on BuildContext {
  bool featureOn(String id) {
    FeatureFlagsService? ff;
    try {
      ff = watch<FeatureFlagsService?>();
    } catch (_) {
      ff = null; // outside a build (callbacks): treat as on, the gateway still refuses
    }
    return ff?.isOn(id) ?? true;
  }

  /// Non-watching read for callbacks (button taps).
  bool featureOnNow(String id) {
    try {
      return read<FeatureFlagsService?>()?.isOn(id) ?? true;
    } catch (_) {
      return true;
    }
  }
}

/// The short note shown where a switched-off feature's controls were.
class FeatureOffNote extends StatelessWidget {
  final String? label;
  final EdgeInsetsGeometry padding;
  const FeatureOffNote({super.key, this.label, this.padding = const EdgeInsets.symmetric(vertical: 6)});

  @override
  Widget build(BuildContext context) {
    final l = label;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Icon(Icons.pause_circle_outline_rounded, size: 18, color: AppTheme.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l == null ? FeatureFlagsService.offNote : '$l: ${FeatureFlagsService.offNote.toLowerCase()}',
              style: AppText.caption.copyWith(color: AppTheme.muted),
            ),
          ),
        ],
      ),
    );
  }
}
