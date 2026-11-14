import 'package:flutter/material.dart';
import 'package:coroute_app/core/ui/coroute_logo.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/app_config.dart';
import '../../core/ui/ui.dart';
import '../../data/services/meta_service.dart' show AppMeta;

/// Profile › Help › "Privacy & terms": one row, then this small sheet with three links
/// (privacy policy, terms of use, and the "Your data" page on the website).
class PrivacyTermsSheet extends StatelessWidget {
  final String privacyUrl;
  final String termsUrl;
  final String yourDataUrl;

  const PrivacyTermsSheet({super.key, required this.privacyUrl, required this.termsUrl, required this.yourDataUrl});

  static const String title = 'Privacy & terms';
  static const String privacyLabel = 'Privacy policy';
  static const String termsLabel = 'Terms of use';
  static const String yourDataLabel = 'Your data';
  static const String licensesLabel = 'Open-source licences';

  /// The website page that explains what CoRoute keeps and how to get or delete it.
  static const String yourDataPath = '/privacy-and-security';

  /// The three links, from the gateway's meta when it has them (pure, for tests).
  static (String, String, String) urlsFor(AppMeta? meta, {String? base}) {
    final b = _trim(base ?? AppConfig.apiBaseUrl);
    final privacy = meta?.privacyUrl.isNotEmpty == true ? meta!.privacyUrl : '$b/privacy';
    final terms = meta?.termsUrl.isNotEmpty == true ? meta!.termsUrl : '$b/terms';
    return (privacy, terms, '$b$yourDataPath');
  }

  static String _trim(String s) => s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  static Future<void> show(BuildContext context, AppMeta? meta) {
    final (privacy, terms, data) = urlsFor(meta);
    return showAppSheet<void>(
      context,
      title: title,
      builder: (_) => PrivacyTermsSheet(privacyUrl: privacy, termsUrl: terms, yourDataUrl: data),
    );
  }

  Future<void> _open(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok) {
      messenger
        ?..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DsListRow(
          key: const ValueKey('privacy_sheet_privacy'),
          icon: Icons.privacy_tip_rounded,
          label: privacyLabel,
          onTap: () => _open(context, privacyUrl),
        ),
        DsListRow(
          key: const ValueKey('privacy_sheet_terms'),
          icon: Icons.gavel_rounded,
          label: termsLabel,
          onTap: () => _open(context, termsUrl),
        ),
        DsListRow(
          key: const ValueKey('privacy_sheet_your_data'),
          icon: Icons.folder_shared_rounded,
          label: yourDataLabel,
          onTap: () => _open(context, yourDataUrl),
        ),
        // Round 8: the licences of the Flutter packages and of RNNoise (intercom noise suppression).
        DsListRow(
          key: const ValueKey('privacy_sheet_licenses'),
          icon: Icons.description_outlined,
          label: licensesLabel,
          divider: false,
          onTap: () => showLicensePage(context: context, applicationName: 'CoRoute', applicationIcon: const Padding(padding: EdgeInsets.all(8), child: CoRouteAppIcon(size: 56, semanticLabel: null))),
        ),
      ],
    );
  }
}
