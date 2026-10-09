import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_bottom_sheet.dart';
import '../../core/ui/ui_tokens.dart';
import '../../data/models/network_models.dart';
import '../../data/models/network_wire.dart';
import '../../data/models/safety_wire.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/safety_service.dart';
import '../../data/services/settings_service.dart';
import '../ride/incident_banner.dart' show PositiveLine;
import '../ride/incident_sheet.dart' show HospitalLine, LiveLinkControls;
import '../ride/incident_view.dart' show etaWords, networkStateWords;

/// What the SOS sheet tells the rider about delivery.
enum SosSheetStatus { delivered, sending, waitingForSignal, unknown }

/// The SOS sheet, shown right after the rider pressed SOS.
///
/// * Says honestly whether the convoy has the SOS: delivered (the server echoed it),
///   sending, or waiting for signal (kept on the phone and sent on reconnect).
/// * Calls or texts the rider's emergency contact (with a map link to the position).
/// * Dials 112.
/// * Says whether nearby riders of other groups are being asked or one is coming (3.15).
/// * Shows the nearest hospital with Navigate and lets the rider share a live link (3.16).
/// * "Help reached me" or "False alarm" closes the rider's own SOS from any screen.
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

  /// What the safety network does for my open SOS: (text, positive), or (null, false).
  static (String?, bool) networkLineOf(ConvoyService? s) {
    final c = s?.activeConvoy;
    final id = s?.myOpenSosAlertId;
    if (c == null || id == null) return (null, false);
    for (final a in c.activeAlerts) {
      if (a.alertId != id) continue;
      final net = a.network;
      if (net == null) return (null, false);
      final r = net.activeResponder;
      if (r != null) {
        if (r.status == ResponderStatus.arrived) return ('A nearby rider has reached you', true);
        final eta = etaWords(r.etaS);
        return (eta == null ? 'A nearby rider is responding' : 'A nearby rider is responding, $eta', true);
      }
      return (networkStateWords(net.state), false);
    }
    return (null, false);
  }

  /// The nearest hospital the gateway found for my open SOS, or null.
  static NearbyPlace? hospitalOf(ConvoyService? s) {
    final c = s?.activeConvoy;
    final id = s?.myOpenSosAlertId;
    if (c == null || id == null) return null;
    for (final a in c.activeAlerts) {
      if (a.alertId == id) return a.nearestHospital;
    }
    return null;
  }

  void _close(BuildContext context, ConvoyService? convoyService, ResolveReason reason) {
    // Resolves this rider's own open SOS on the server (also when the sheet was
    // opened without an alert id) and drops one that is still waiting to be sent.
    if (convoyService != null) {
      final known = alertId;
      if (known != null && known != convoyService.myOpenSosAlertId) convoyService.resolveSosAlert(known, reason: reason);
      convoyService.cancelMySos(reason: reason);
    }
    onResolved?.call();
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);
    messenger?.showSnackBar(SnackBar(
      content: Text(reason == ResolveReason.falseAlarm ? 'SOS cancelled. Your convoy sees that it was a false alarm.' : 'SOS closed. Your convoy sees that help reached you.'),
    ));
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
    // Emergency texts (opt-in): status line, and "Text the group now" while the SOS is not delivered.
    final smsOn = context.select<SettingsService?, bool>((s) => s?.smsFallback ?? false);
    final (smsStatus, smsAvailable) = context.select<SafetyService?, (SmsFallbackStatus?, bool)>(
      (s) => (s?.smsStatus, s?.smsAvailable ?? false),
    );
    final smsLine = smsStatus?.text ?? '';
    final showSmsButton = smsOn && pending && status != SosSheetStatus.delivered;
    final (netLine, netPositive) = context.select<ConvoyService?, (String?, bool)>(networkLineOf);
    // 3.16: the nearest hospital of my open alert, and the live link for it (3.16 gateway only).
    final hospital = context.select<ConvoyService?, NearbyPlace?>(hospitalOf);
    final ride316 = context.select<ConvoyService?, bool>((s) => s?.supports(ProtocolFeatures.ride316) ?? false);
    final linkId = ride316 ? (alertId ?? openAlertId) : null;

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
            if (netLine != null) ...[
              if (netPositive)
                PositiveLine(text: netLine)
              else
                Semantics(
                  liveRegion: true,
                  child: Row(
                    children: [
                      Icon(Icons.person_search_rounded, size: 18, color: AppTheme.textSecondary),
                      const SizedBox(width: Space.s8),
                      Expanded(child: Text(netLine, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: AppTheme.textPrimary))),
                    ],
                  ),
                ),
              const SizedBox(height: Space.s12),
            ],
            if (hospital != null) ...[
              HospitalLine(place: hospital),
              const SizedBox(height: Space.s8),
            ],

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
            if (linkId != null) ...[
              LiveLinkControls(alertId: linkId),
              const SizedBox(height: Space.s12),
            ],

            if (smsLine.isNotEmpty) ...[
              Semantics(
                liveRegion: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.sms_rounded, size: 18, color: AppTheme.textSecondary),
                    const SizedBox(width: Space.s8),
                    Expanded(
                      child: Text(
                        smsLine,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.label.copyWith(color: AppTheme.textPrimary, fontWeight: FontWeight.w400),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.s12),
            ],
            if (showSmsButton) ...[
              OutlinedButton.icon(
                onPressed: smsAvailable ? () => Provider.of<SafetyService?>(context, listen: false)?.sendSmsNow() : null,
                icon: const Icon(Icons.sms_rounded),
                label: const Text(
                  'Text the group now',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textPrimary,
                  side: BorderSide(color: AppTheme.subtleBorder),
                  minimumSize: const Size.fromHeight(56),
                  shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
                ),
              ),
              const SizedBox(height: 8),
            ],

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

            // Close my SOS: help reached me, or it was a false alarm. Then "Keep it on".
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.emeraldSafe,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(56),
                shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
              ),
              icon: const Icon(Icons.verified_user_rounded),
              onPressed: () => _close(context, convoyService, ResolveReason.resolved),
              label: Text(L10n.t('sos.ok'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: Space.s8),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.elevatedCard,
                foregroundColor: AppTheme.textPrimary,
                minimumSize: const Size.fromHeight(56),
                shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: AppTheme.subtleBorder)),
              ),
              icon: const Icon(Icons.do_not_disturb_on_rounded),
              onPressed: () => _close(context, convoyService, ResolveReason.falseAlarm),
              label: Text(L10n.t('sos.false'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
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
