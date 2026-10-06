import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';

/// Interactive Emergency SOS Action Sheet triggered when SOS is activated.
///
/// Implements Section 5.4 of CoRoute Architectural Specifications:
/// * Real-time distress beacon broadcast over WebSocket to entire convoy.
/// * Direct phone dialer trigger to designated emergency contact via `url_launcher`.
/// * Direct emergency SMS trigger with live Google Maps coordinate link (`https://maps.google.com/?q=lat,lng`).
/// * Rapid 112 emergency services dispatch button.
class EmergencySosSheet extends StatelessWidget {
  final double lat;
  final double lng;
  final String? alertId;
  final VoidCallback? onResolved;

  const EmergencySosSheet({
    super.key,
    required this.lat,
    required this.lng,
    this.alertId,
    this.onResolved,
  });

  static Future<void> show(
    BuildContext context, {
    required double lat,
    required double lng,
    String? alertId,
    VoidCallback? onResolved,
  }) {
    HapticFeedback.heavyImpact();
    return showModalBottomSheet(
      context: context,
      isDismissible: true,
      enableDrag: true,
      isScrollControlled: true,
      backgroundColor: AppTheme.slateCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => EmergencySosSheet(
        lat: lat,
        lng: lng,
        alertId: alertId,
        onResolved: onResolved,
      ),
    );
  }

  Future<void> _makeCall(BuildContext context, String phone) async {
    final clean = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.isEmpty) return;
    final uri = Uri.parse('tel:$clean');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot initiate phone call to $clean')),
      );
    }
  }

  Future<void> _sendSms(BuildContext context, String phone, double lat, double lng) async {
    final clean = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    final mapsLink = 'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';
    final body = 'EMERGENCY! I need immediate help. My live GPS location: $mapsLink';
    final uri = Uri(
      scheme: 'sms',
      path: clean,
      queryParameters: {'body': body},
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot compose SMS to $clean')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final convoyService = Provider.of<ConvoyService?>(context, listen: false);
    final emergencyPhone = auth.emergencyContact?.trim() ?? '';
    final emergencyName = auth.emergencyContactName?.trim() ?? '';
    final hasEmergencyContact = emergencyPhone.isNotEmpty;
    final mapsUrl = 'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.glassBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Header Banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.laserRed.withOpacity(0.16),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.laserRed.withOpacity(0.7)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.laserRed,
                    ),
                    child: const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '🚨 SOS DISTRESS BEACON ACTIVE',
                          style: TextStyle(color: AppTheme.laserRed, fontWeight: FontWeight.w900, fontSize: 13),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Broadcasted to all convoy riders on live map radar.',
                          style: TextStyle(color: AppTheme.textPrimary.withOpacity(0.9), fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Location Box
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.elevatedCard,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.glassBorder),
              ),
              child: Row(
                children: [
                  Icon(Icons.my_location_rounded, color: AppTheme.neonCyan, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'GPS: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: mapsUrl));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Coordinates link copied to clipboard!')),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text('COPY LINK', style: TextStyle(color: AppTheme.neonCyan, fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Action 1: Call Emergency Contact
            if (hasEmergencyContact) ...[
              ElevatedButton.icon(
                onPressed: () => _makeCall(context, emergencyPhone),
                icon: const Icon(Icons.phone_in_talk_rounded, color: Colors.white),
                label: Text(
                  'Call ${emergencyName.isNotEmpty ? emergencyName : "Emergency Contact"} ($emergencyPhone)',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.emeraldSafe,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 8),

              // Action 2: Send SMS with Maps link
              ElevatedButton.icon(
                onPressed: () => _sendSms(context, emergencyPhone, lat, lng),
                icon: const Icon(Icons.sms_rounded, color: Colors.black),
                label: Text(
                  'Send SMS with Location to $emergencyPhone',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.hyperAmber,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 8),
            ],

            // Action 3: Dial 112 National Emergency
            OutlinedButton.icon(
              onPressed: () => _makeCall(context, '112'),
              icon: Icon(Icons.local_hospital_rounded, color: AppTheme.laserRed),
              label: Text(
                'Dial 112 National Emergency Services',
                style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.laserRed, fontSize: 13),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppTheme.laserRed),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),

            // Resolve / Cancel Button
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      if (alertId != null) {
                        convoyService?.resolveSosAlert(alertId!);
                      }
                      onResolved?.call();
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('SOS Alert resolved.')),
                      );
                    },
                    child: Text('Cancel / Resolve SOS', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Keep Active', style: TextStyle(color: AppTheme.neonCyan, fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
