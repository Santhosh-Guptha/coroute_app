import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/safety_native.dart';
import '../../data/services/settings_service.dart';

/// Phone brands with their own battery killers.
enum OemBrand { xiaomi, samsung, oneplus, oppo, vivo, huawei, motorola, generic }

/// One-time guide: the brand's settings that stop it from closing CoRoute
/// during a ride (autostart, background battery use). "Open settings" tries the
/// brand's page and falls back to CoRoute's app settings.
class OemBatteryGuide extends StatelessWidget {
  final OemBrand brand;
  const OemBatteryGuide({super.key, required this.brand});

  static OemBrand brandFor(String manufacturer) {
    final m = manufacturer.toLowerCase();
    if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) return OemBrand.xiaomi;
    if (m.contains('samsung')) return OemBrand.samsung;
    if (m.contains('oneplus')) return OemBrand.oneplus;
    if (m.contains('oppo') || m.contains('realme')) return OemBrand.oppo;
    if (m.contains('vivo') || m.contains('iqoo')) return OemBrand.vivo;
    if (m.contains('huawei') || m.contains('honor')) return OemBrand.huawei;
    if (m.contains('motorola') || m.contains('lenovo')) return OemBrand.motorola;
    return OemBrand.generic;
  }

  static String brandLabel(OemBrand b) {
    switch (b) {
      case OemBrand.xiaomi:
        return 'Xiaomi, Redmi or POCO';
      case OemBrand.samsung:
        return 'Samsung';
      case OemBrand.oneplus:
        return 'OnePlus';
      case OemBrand.oppo:
        return 'Oppo or Realme';
      case OemBrand.vivo:
        return 'Vivo or iQOO';
      case OemBrand.huawei:
        return 'Huawei or Honor';
      case OemBrand.motorola:
        return 'Motorola';
      case OemBrand.generic:
        return 'your phone';
    }
  }

  /// Short name for the checklist row: "Battery settings for Samsung".
  static String rowTitle(String manufacturer) {
    final b = brandFor(manufacturer);
    if (b == OemBrand.generic) return 'Battery settings for your phone';
    final name = manufacturer.trim();
    return 'Battery settings for ${name.isEmpty ? brandLabel(b) : _capitalise(name)}';
  }

  static String _capitalise(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static List<String> stepsFor(OemBrand b) {
    switch (b) {
      case OemBrand.xiaomi:
        return const [
          'Tap Open settings. In Autostart, turn CoRoute on.',
          'Go to Settings > Apps > Manage apps > CoRoute > Battery saver and choose No restrictions.',
          'In the recent apps screen, press and hold CoRoute and tap the lock so it is not cleared.',
        ];
      case OemBrand.samsung:
        return const [
          'Go to Settings > Apps > CoRoute > Battery and choose Unrestricted.',
          'Go to Settings > Battery > Background usage limits and make sure CoRoute is not in Sleeping apps or Deep sleeping apps.',
        ];
      case OemBrand.oneplus:
        return const [
          'Go to Settings > Apps > CoRoute > Battery usage and allow background activity.',
          'Turn on Auto launch for CoRoute if your phone has it.',
          'In the recent apps screen, lock CoRoute so it is not cleared.',
        ];
      case OemBrand.oppo:
        return const [
          'Go to Settings > Apps > App management > CoRoute > Battery usage.',
          'Turn on Allow background activity and Allow auto launch.',
          'In the recent apps screen, lock CoRoute so it is not cleared.',
        ];
      case OemBrand.vivo:
        return const [
          'Go to Settings > Battery > Background power consumption management and allow CoRoute.',
          'Tap Open settings and turn on Autostart for CoRoute.',
        ];
      case OemBrand.huawei:
        return const [
          'Go to Settings > Battery > App launch and find CoRoute.',
          'Turn off Manage automatically, then turn on Auto-launch, Secondary launch and Run in background.',
        ];
      case OemBrand.motorola:
        return const [
          'Go to Settings > Apps > CoRoute > Battery and choose Unrestricted.',
        ];
      case OemBrand.generic:
        return const [
          'Go to Settings > Apps > CoRoute > Battery and choose Unrestricted or Not optimised.',
          'If your phone has an Autostart or App launch list, allow CoRoute there.',
        ];
    }
  }

  /// Opens the guide for this phone's brand and marks it as seen.
  static Future<void> show(BuildContext context, {String? manufacturer}) async {
    final m = manufacturer ?? (await SafetyNative.deviceInfo()).manufacturer;
    if (!context.mounted) return;
    final settings = Provider.of<SettingsService?>(context, listen: false);
    await showAppSheet<void>(
      context,
      isScrollControlled: true,
      title: 'Keep CoRoute running',
      builder: (_) => OemBatteryGuide(brand: brandFor(m)),
    );
    await settings?.markOemGuideSeen();
  }

  @override
  Widget build(BuildContext context) {
    final steps = stepsFor(brand);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Some phones close apps in the background to save battery. Then your group stops seeing you and crash detection stops. '
            'On ${brandLabel(brand)}:',
            style: AppText.body.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: Space.s12),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: AppTheme.elevatedCard, shape: BoxShape.circle, border: Border.all(color: AppTheme.subtleBorder)),
                    child: Text('${i + 1}', style: AppText.label.copyWith(color: AppTheme.textPrimary)),
                  ),
                  const SizedBox(width: Space.s12),
                  Expanded(child: Text(steps[i], style: AppText.body)),
                ],
              ),
            ),
          const SizedBox(height: Space.s4),
          FilledButton.icon(
            onPressed: () async {
              final ok = await SafetyNative.openOemBatterySettings();
              if (!ok && context.mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  const SnackBar(content: Text('Open your phone settings and follow the steps above.')),
                );
              }
            },
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            icon: const Icon(Icons.settings_rounded),
            label: const Text('Open settings'),
          ),
          const SizedBox(height: Space.s8),
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
