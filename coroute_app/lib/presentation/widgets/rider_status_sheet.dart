import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_bottom_sheet.dart';
import '../../core/ui/ui_tokens.dart';
import '../../data/services/convoy_service.dart';

/// "Why are you stopped?": tells the group the reason for a stop.
///
/// Implements Section 5.5 of CoRoute Specifications: fueling, rest break, mechanical issue,
/// flat tyre, traffic, weather, photo stop, medical emergency, regroup, or a custom reason.
/// Each reason has a Material icon (no emoji in the app). The five common reasons come
/// first as big tiles; "More reasons" shows the rest and a typed reason, in the same sheet.
class RiderStatusSheet {
  static const List<Map<String, String>> statusReasons = [
    {'code': 'FUELING', 'label': 'Fueling'},
    {'code': 'REST_BREAK', 'label': 'Rest Break'},
    {'code': 'MECHANICAL', 'label': 'Mechanical Issue'},
    {'code': 'FLAT_TIRE', 'label': 'Flat Tire'},
    {'code': 'TRAFFIC', 'label': 'Traffic Delay'},
    {'code': 'RAIN_DELAY', 'label': 'Weather Delay'},
    {'code': 'PHOTO_STOP', 'label': 'Photo Stop'},
    {'code': 'MEDICAL', 'label': 'Medical Emergency'},
    {'code': 'REGROUP', 'label': 'Regroup Wait'},
    {'code': 'CUSTOM', 'label': 'Custom Reason'},
  ];

  /// Icon for each reason code.
  static const Map<String, IconData> statusIcons = {
    'FUELING': Icons.local_gas_station_rounded,
    'REST_BREAK': Icons.free_breakfast_rounded,
    'MECHANICAL': Icons.build_rounded,
    'FLAT_TIRE': Icons.tire_repair_rounded,
    'TRAFFIC': Icons.traffic_rounded,
    'RAIN_DELAY': Icons.umbrella_rounded,
    'PHOTO_STOP': Icons.photo_camera_rounded,
    'MEDICAL': Icons.medical_services_rounded,
    'REGROUP': Icons.groups_rounded,
    'CUSTOM': Icons.chat_bubble_outline_rounded,
  };

  /// Shown first, as big tiles (the rest are behind "More reasons").
  static const List<String> commonCodes = ['FUELING', 'REST_BREAK', 'MECHANICAL', 'FLAT_TIRE', 'MEDICAL'];

  /// The other preset reasons (the typed reason is separate).
  static const List<String> moreCodes = ['TRAFFIC', 'RAIN_DELAY', 'PHOTO_STOP', 'REGROUP'];

  static Map<String, String> getStatusInfo(String code) {
    return statusReasons.firstWhere(
      (r) => r['code'] == code,
      orElse: () => {'code': code, 'label': code},
    );
  }

  static IconData getStatusIcon(String code) => statusIcons[code] ?? Icons.info_outline_rounded;
  static String getStatusLabel(String code) => getStatusInfo(code)['label'] ?? code;

  static void show(
    BuildContext context, {
    ConvoyService? convoyService,
    required String userId,
  }) {
    final activeService = convoyService ?? context.read<ConvoyService>();
    final current = activeService.activeConvoy?.riders[userId]?.statusReason ?? '';
    showAppSheet<void>(
      context,
      title: 'Why are you stopped?',
      isScrollControlled: true,
      builder: (ctx) => StatusPicker(
        currentCode: current,
        onPick: (code, message) {
          activeService.updateStatusReason(userId: userId, reason: code, message: message);
          Navigator.pop(ctx);
        },
        onClear: () {
          activeService.updateStatusReason(userId: userId, reason: '');
          Navigator.pop(ctx);
        },
      ),
    );
  }
}

/// The body of the status sheet: reason tiles, "More reasons", a typed reason and
/// "Clear status". Calls [onPick] with the code (and the typed text for CUSTOM).
class StatusPicker extends StatefulWidget {
  final String currentCode;
  final void Function(String code, String message) onPick;
  final VoidCallback onClear;

  const StatusPicker({super.key, this.currentCode = '', required this.onPick, required this.onClear});

  @override
  State<StatusPicker> createState() => _StatusPickerState();
}

class _StatusPickerState extends State<StatusPicker> {
  bool _more = false;
  final _custom = TextEditingController();

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  void _sendCustom() {
    final text = _custom.text.trim();
    if (text.isEmpty) return;
    widget.onPick('CUSTOM', text);
  }

  Widget _grid(List<String> codes) {
    return LayoutBuilder(builder: (context, c) {
      final w = (c.maxWidth - Space.s8) / 2;
      return Wrap(
        spacing: Space.s8,
        runSpacing: Space.s8,
        children: [
          for (final code in codes)
            SizedBox(
              width: w,
              child: _ReasonTile(
                icon: RiderStatusSheet.getStatusIcon(code),
                label: RiderStatusSheet.getStatusLabel(code),
                selected: widget.currentCode == code,
                onTap: () => widget.onPick(code, ''),
              ),
            ),
        ],
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _grid(RiderStatusSheet.commonCodes),
          const SizedBox(height: Space.s8),
          if (!_more)
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: AppTheme.neonCyan),
              onPressed: () => setState(() => _more = true),
              icon: const Icon(Icons.expand_more_rounded),
              label: const Text('More reasons'),
            )
          else ...[
            _grid(RiderStatusSheet.moreCodes),
            const SizedBox(height: Space.s12),
            Text('Or type a reason', style: AppText.label),
            const SizedBox(height: Space.s8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _custom,
                    maxLength: 80,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendCustom(),
                    style: AppText.body,
                    decoration: InputDecoration(
                      hintText: 'For example: waiting for a mechanic',
                      hintStyle: AppText.caption,
                      counterText: '',
                      filled: true,
                      fillColor: AppTheme.elevatedCard,
                      border: const OutlineInputBorder(borderRadius: Radii.mdAll, borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: Space.s8),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
                  onPressed: _sendCustom,
                  child: const Text('Set'),
                ),
              ],
            ),
          ],
          if (widget.currentCode.isNotEmpty) ...[
            const SizedBox(height: Space.s8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: AppTheme.textPrimary),
              onPressed: widget.onClear,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Clear status'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReasonTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ReasonTile({required this.icon, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final Color accent = selected ? AppTheme.neonCyan : AppTheme.subtleBorder;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? AppTheme.neonCyan.withOpacity(0.12) : AppTheme.elevatedCard,
        shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: accent)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.s12, vertical: Space.s8),
              child: Row(
                children: [
                  Icon(icon, size: 22, color: AppTheme.neonCyan),
                  const SizedBox(width: Space.s8),
                  Expanded(
                    child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  if (selected) Icon(Icons.check_rounded, size: 20, color: AppTheme.neonCyan),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
