import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/app_version_service.dart';

/// Full-screen, non-dismissible screen displayed when a mandatory application
/// update is required. Back navigation is strictly intercepted via [PopScope].
class ForceUpdateScreen extends StatelessWidget {
  const ForceUpdateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final versionService = context.watch<AppVersionService>();

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppTheme.bg,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 540),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Pulsing Warning Icon
                    Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppTheme.warnText.withValues(alpha: 0.15),
                        border: Border.all(color: AppTheme.warnText, width: 2.5),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.warnText.withValues(alpha: 0.35),
                            blurRadius: 24,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.system_security_update_rounded,
                        color: AppTheme.warnText,
                        size: 44,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Title & Subtitle
                    Text(
                      'MANDATORY UPDATE REQUIRED',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppTheme.text,
                        fontWeight: FontWeight.w900,
                        fontSize: 20,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'A critical safety and protocol update has been released. You must update CoRoute to stay synchronized with your convoy.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppTheme.text2,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Version Details Card
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: AppTheme.card,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppTheme.border2),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Installed Version',
                                style: TextStyle(color: AppTheme.text2, fontSize: 12),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  '${versionService.currentVersion} (Build ${versionService.currentBuild})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: AppTheme.text,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Minimum Required',
                                style: TextStyle(color: AppTheme.warnText, fontSize: 12, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  'Build ${versionService.minRequiredBuild}+',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: AppTheme.warnText,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Divider(height: 24, color: AppTheme.border2),
                          Text(
                            'Why is this update required?',
                            style: TextStyle(
                              color: AppTheme.text,
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            versionService.releaseNotes,
                            style: TextStyle(
                              color: AppTheme.text2,
                              fontSize: 11,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),

                    // UPDATE NOW Button (56dp target)
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.brand,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 4,
                        ),
                        onPressed: () => versionService.launchUpdate(),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.download_rounded, color: Colors.white, size: 22),
                            SizedBox(width: 8),
                            Text(
                              'UPDATE NOW',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Check Again Button
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.text,
                          side: BorderSide(color: AppTheme.border2),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: versionService.checking
                            ? null
                            : () async {
                                await versionService.checkForUpdates();
                                if (!context.mounted) return;
                                if (!versionService.isMandatoryUpdateRequired) {
                                  Navigator.of(context).maybePop();
                                } else {
                                  ScaffoldMessenger.of(context)
                                    ..clearSnackBars()
                                    ..showSnackBar(
                                      const SnackBar(
                                        content: Text('Update still required. Please install the latest release.'),
                                        duration: Duration(seconds: 2),
                                      ),
                                    );
                                }
                              },
                        child: versionService.checking
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accentText),
                              )
                            : const Text(
                                'Check Again',
                                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
