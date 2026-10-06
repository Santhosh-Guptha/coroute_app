import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/convoy_service.dart';

/// Reusable Rider Status Sheet for selecting reasons for being stationary.
///
/// Implements Section 5.5 of CoRoute Specifications:
/// * ⛽ Fueling
/// * ☕ Rest Break
/// * 🔧 Mechanical Issue
/// * 🛞 Flat Tire
/// * 🚦 Traffic Delay
/// * 🌧️ Weather Delay
/// * 📸 Photo Stop
/// * 🏥 Medical Emergency
/// * 🛑 Regroup Request
/// * 💬 Custom Reason
class RiderStatusSheet {
  static const List<Map<String, String>> statusReasons = [
    {'code': 'FUELING', 'label': 'Fueling', 'emoji': '⛽'},
    {'code': 'REST_BREAK', 'label': 'Rest Break', 'emoji': '☕'},
    {'code': 'MECHANICAL', 'label': 'Mechanical Issue', 'emoji': '🔧'},
    {'code': 'FLAT_TIRE', 'label': 'Flat Tire', 'emoji': '🛞'},
    {'code': 'TRAFFIC', 'label': 'Traffic Delay', 'emoji': '🚦'},
    {'code': 'RAIN_DELAY', 'label': 'Weather Delay', 'emoji': '🌧️'},
    {'code': 'PHOTO_STOP', 'label': 'Photo Stop', 'emoji': '📸'},
    {'code': 'MEDICAL', 'label': 'Medical Emergency', 'emoji': '🏥'},
    {'code': 'REGROUP', 'label': 'Regroup Wait', 'emoji': '🛑'},
    {'code': 'CUSTOM', 'label': 'Custom Reason', 'emoji': '💬'},
  ];

  static Map<String, String> getStatusInfo(String code) {
    return statusReasons.firstWhere(
      (r) => r['code'] == code,
      orElse: () => {'code': code, 'label': code, 'emoji': '⚠️'},
    );
  }

  static String getStatusEmoji(String code) => getStatusInfo(code)['emoji'] ?? '⚠️';
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
                      avatar: Text(r['emoji']!),
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
        title: Text('💬 Custom Stop Reason', style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
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
