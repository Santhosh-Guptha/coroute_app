import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/permissions_service.dart';

/// 3.57 phone-first emergency texts: the prominent disclosure (one calm screen) shown before the
/// system SEND_SMS prompt. Opened from the emergency contact form (once, after a contact is saved),
/// the permissions screen and Safety health. "Not now" changes nothing: the SOS text then opens in
/// the messages app, ready to send.
class EmergencyTextsDisclosure extends StatelessWidget {
  const EmergencyTextsDisclosure({super.key});

  static const String title = 'Text your contacts in an emergency';
  static const String allowLabel = 'Allow texts';
  static const String laterLabel = 'Not now';
  static const String deniedNote =
      'Without this, the SOS text opens in your messages app and someone has to press Send.';

  static bool get _android => !kIsWeb && Platform.isAndroid;

  /// Shows the screen; on "Allow texts" asks Android for SEND_SMS. True when texts are allowed.
  static Future<bool> show(BuildContext context) async {
    if (!_android) return false;
    if (await PermissionsService.isSmsGranted()) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(AppConstants.keyEmergencyTextsDisclosure, true);
    } catch (_) {}
    if (!context.mounted) return false;
    final go = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(fullscreenDialog: true, builder: (_) => const EmergencyTextsDisclosure()),
    );
    if (go != true) return false;
    return PermissionsService.request('sms');
  }

  /// After an emergency contact was saved: the disclosure once, unless texts are already allowed.
  static Future<void> offerOnce(BuildContext context) async {
    if (!_android) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(AppConstants.keyEmergencyTextsDisclosure) == true) return;
    } catch (_) {
      return;
    }
    if (await PermissionsService.isSmsGranted()) return;
    if (!context.mounted) return;
    await show(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
              children: [
                Container(
                  width: 72,
                  height: 72,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: AppTheme.tint, shape: BoxShape.circle),
                  child: Icon(Icons.sms_rounded, size: 36, color: AppTheme.accentText),
                ),
                const SizedBox(height: Space.s24),
                Text(title, style: AppText.headline),
                const SizedBox(height: Space.s12),
                Text(
                  PermissionsService.emergencyTextsDisclosure,
                  key: const ValueKey('emergency_texts_disclosure'),
                  style: AppText.body,
                ),
                const SizedBox(height: Space.s12),
                Text(
                  'The text has your name, what happened, the time, a live location link and your coordinates. '
                  'When you are safe again, they get a short "safe now" text. CoRoute never reads your messages.',
                  style: AppText.body.copyWith(color: AppTheme.text2),
                ),
                const SizedBox(height: Space.s12),
                Text(deniedNote, style: AppText.caption.copyWith(color: AppTheme.text2)),
                const SizedBox(height: Space.s24),
                DsButton(
                  key: const ValueKey('emergency_texts_allow'),
                  label: allowLabel,
                  icon: Icons.check_rounded,
                  onPressed: () => Navigator.of(context).pop(true),
                ),
                const SizedBox(height: Space.s12),
                DsButton(
                  key: const ValueKey('emergency_texts_later'),
                  label: laterLabel,
                  tone: DsButtonTone.outline,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
