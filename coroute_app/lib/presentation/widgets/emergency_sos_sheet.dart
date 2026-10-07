import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_bottom_sheet.dart';
import '../../core/ui/ui_tokens.dart';
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
    // No haptic here: the SOS button already gave one when the hold completed.
    return showAppSheet<void>(
      context,
      isScrollControlled: true,
      builder: (ctx) => SingleChildScrollView(
        child: EmergencySosSheet(
          lat: lat,
          lng: lng,
          alertId: alertId,
          onResolved: onResolved,
        ),
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

    return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                            style: AppText.body.copyWith(color: headerColor, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: AppText.label.copyWith(color: AppTheme.textPrimary, fontWeight: FontWeight.w400),
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
              padding: const EdgeInsets.only(left: Space.s12, right: Space.s4),
              decoration: BoxDecoration(
                color: AppTheme.elevatedCard,
                borderRadius: Radii.mdAll,
                border: Border.all(color: AppTheme.subtleBorder),
              ),
              child: Row(
                children: [
                  Icon(Icons.my_location_rounded, color: AppTheme.neonCyan, size: 18),
                  const SizedBox(width: Space.s8),
                  Expanded(
                    child: Text(
                      'Position: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(color: AppTheme.textSecondary, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: AppTheme.neonCyan),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: mapsUrl));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Map link copied.')),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Copy link', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
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
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.emeraldSafe,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(56),
                  shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
                ),
              ),
              const SizedBox(height: 8),

              // Action 2: Send SMS with Maps link
              ElevatedButton.icon(
                onPressed: () => _sendSms(context, emergencyPhone, lat, lng),
                icon: const Icon(Icons.sms_rounded, color: Colors.black),
                label: Text(
                  'Text my location to $emergencyPhone',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.black),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.hyperAmber,
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(56),
                  shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
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
                style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.laserRed, fontSize: 14),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppTheme.laserRed),
                minimumSize: const Size.fromHeight(56),
                shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
              ),
            ),
            const SizedBox(height: 12),

            // Resolve / Cancel Button: full width, then "Keep it on".
            FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.elevatedCard,
                      foregroundColor: AppTheme.textPrimary,
                      minimumSize: const Size.fromHeight(56),
                      shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: AppTheme.subtleBorder)),
                    ),
                    icon: Icon(Icons.verified_user_rounded, color: AppTheme.emeraldSafe),
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
                    label: const Text('I am safe, cancel the SOS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: Space.s4),
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: AppTheme.neonCyan),
              onPressed: () => Navigator.pop(context),
              child: const Text('Keep it on', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ],
    );
  }
}
