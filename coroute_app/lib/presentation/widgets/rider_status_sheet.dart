import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/convoy_service.dart';

/// Reusable Rider Status Sheet for selecting reasons for being stationary.
///
/// Implements Section 5.5 of CoRoute Specifications: fueling, rest break, mechanical issue,
/// flat tyre, traffic, weather, photo stop, medical emergency, regroup, or a custom reason.
/// Each reason has a Material icon (no emoji in the app).
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
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.slateCard,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Why are you stopped?',
                    style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  TextButton(
                    onPressed: () {
                      activeService.updateStatusReason(userId: userId, reason: '');
                      Navigator.pop(ctx);
                    },
                    child: Text('Clear Status', style: TextStyle(color: AppTheme.laserRed, fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final r in statusReasons)
                    ActionChip(
                      avatar: Icon(getStatusIcon(r['code']!), size: 18, color: AppTheme.neonCyan),
                      label: Text(r['label']!, style: TextStyle(fontSize: 12, color: AppTheme.textPrimary)),
                      backgroundColor: AppTheme.elevatedCard,
                      side: BorderSide(color: AppTheme.glassBorder),
                      onPressed: () {
                        Navigator.pop(ctx);
                        if (r['code'] == 'CUSTOM') {
                          _showCustomReasonDialog(context, activeService, userId);
                        } else {
                          activeService.updateStatusReason(userId: userId, reason: r['code']!);
                        }
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static void _showCustomReasonDialog(BuildContext context, ConvoyService convoyService, String userId) {
    final customCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.slateCard,
        title: Text('Custom stop reason', style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: TextField(
          controller: customCtrl,
          autofocus: true,
          style: TextStyle(color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: 'e.g. Broken clutch cable, waiting for tow',
            hintStyle: TextStyle(color: AppTheme.textMuted),
            filled: true,
            fillColor: AppTheme.elevatedCard,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            onPressed: () {
              final text = customCtrl.text.trim();
              if (text.isNotEmpty) {
                convoyService.updateStatusReason(
                  userId: userId,
                  reason: 'CUSTOM',
                  message: text,
                );
              }
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.neonCyan),
            child: const Text('Set Status', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }
}
