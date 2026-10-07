import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';

/// What the SOS sheet tells the rider about delivery.
enum SosSheetStatus { delivered, sending, waitingForSignal, unknown }

/// The SOS sheet, shown right after the rider pressed SOS.
///
/// * Says honestly whether the convoy has the SOS: delivered (the server echoed it),
///   sending, or waiting for signal (kept on the phone and sent on reconnect).
/// * Calls or texts the rider's emergency contact (with a map link to the position).
/// * Dials 112.
/// * "I am safe" cancels the rider's own SOS from any screen.
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

  /// Delivery state from what the phone knows (pure, for tests).
  static SosSheetStatus statusFor({required bool hasService, required bool pending, required bool online, required bool hasOpenAlert}) {
    if (!hasService) return SosSheetStatus.unknown;
    if (pending) return online ? SosSheetStatus.sending : SosSheetStatus.waitingForSignal;
    return hasOpenAlert ? SosSheetStatus.delivered : SosSheetStatus.unknown;
  }

  static (String, String) textFor(SosSheetStatus status) {
    switch (status) {
      case SosSheetStatus.delivered:
        return ('SOS delivered to your convoy', 'Your convoy can see where you are. You can also call or text your emergency contact.');
      case SosSheetStatus.sending:
        return ('Sending your SOS to the convoy...', 'Keep the app open. You can also call or text your emergency contact below.');
      case SosSheetStatus.waitingForSignal:
        return (
          'No signal. SOS not sent yet',
          'Your SOS will be sent as soon as the phone is back online. Call or text your emergency contact below.',
        );
      case SosSheetStatus.unknown:
        return ('Emergency help', 'Call or text your emergency contact, or dial 112.');
    }
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
    final body = 'Emergency. I need help. My location: $mapsLink';
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
    // Rebuilds only when the delivery state changes (not on every position update).
    final (hasService, pending, online, openAlertId) = context.select<ConvoyService?, (bool, bool, bool, String?)>(
      (s) => (s != null, s?.pendingSos != null, s?.isOnline ?? false, s?.myOpenSosAlertId),
    );
    final status = statusFor(hasService: hasService, pending: pending, online: online, hasOpenAlert: openAlertId != null || alertId != null);
    final (title, subtitle) = textFor(status);
    final headerColor = status == SosSheetStatus.delivered ? AppTheme.emeraldSafe : AppTheme.laserRed;
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
            Semantics(
              liveRegion: true,
              container: true,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: headerColor.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: headerColor.withOpacity(0.7)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: headerColor,
                      ),
                      child: Icon(
                        status == SosSheetStatus.delivered
                            ? Icons.check_rounded
                            : (status == SosSheetStatus.waitingForSignal ? Icons.signal_cellular_off_rounded : Icons.warning_amber_rounded),
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(color: headerColor, fontWeight: FontWeight.w900, fontSize: 14),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: TextStyle(color: AppTheme.textPrimary.withOpacity(0.9), fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
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
                      'Position: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: mapsUrl));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Map link copied.')),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text('Copy link', style: TextStyle(color: AppTheme.neonCyan, fontSize: 10, fontWeight: FontWeight.bold)),
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
                  'Call ${emergencyName.isNotEmpty ? emergencyName : "emergency contact"} ($emergencyPhone)',
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
                  'Text my location to $emergencyPhone',
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
                'Dial 112 (emergency services)',
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
                      // Resolves this rider's own open SOS on the server (also when the sheet was
                      // opened without an alert id) and drops one that is still waiting to be sent.
                      if (convoyService != null) {
                        final known = alertId;
                        if (known != null && known != convoyService.myOpenSosAlertId) convoyService.resolveSosAlert(known);
                        convoyService.cancelMySos();
                      }
                      onResolved?.call();
                      final messenger = ScaffoldMessenger.maybeOf(context);
                      Navigator.pop(context);
                      messenger?.showSnackBar(
                        const SnackBar(content: Text('SOS cancelled. Your convoy sees that you are OK.')),
                      );
                    },
                    child: Text('I am safe, cancel the SOS', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Keep it on', style: TextStyle(color: AppTheme.neonCyan, fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
