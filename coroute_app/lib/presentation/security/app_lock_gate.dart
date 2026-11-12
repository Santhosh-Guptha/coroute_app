import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/safety_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/app_lock_service.dart';
import '../../data/services/app_security_native.dart';
import '../../data/services/safety_service.dart';
import '../widgets/emergency_sos_sheet.dart';

/// Round 4 app lock: covers the app (kept alive underneath, hidden from screen readers) while [AppLockService.locked].
/// The lock screen offers Unlock plus the safety actions that never wait for an unlock: SOS, Call 112, Medical ID.
class AppLockGate extends StatelessWidget {
  const AppLockGate({super.key, required this.child, required this.navigatorKey});

  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) {
    final lock = context.watch<AppLockService?>();
    final locked = lock?.locked ?? false;
    return Stack(
      children: [
        ExcludeSemantics(excluding: locked, child: child),
        if (locked && lock != null) Positioned.fill(child: AppLockScreen(lock: lock, navigatorKey: navigatorKey)),
      ],
    );
  }
}

class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key, required this.lock, required this.navigatorKey});

  final AppLockService lock;
  final GlobalKey<NavigatorState> navigatorKey;

  static const String title = 'CoRoute is locked';

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Ask at once (fingerprint prompt); the buttons stay for a cancelled prompt.
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    await widget.lock.unlock();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _sos() async {
    widget.lock.bypassForSafety();
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null) return;
    final fix = SafetyService.hasInstance ? SafetyService.instance.lastFix : null;
    await EmergencySosSheet.show(ctx, lat: fix?.lat ?? 0, lng: fix?.lng ?? 0);
    // No SOS left open: back to the lock screen (an open SOS keeps the lock away by the rules).
    widget.lock.relock();
  }

  Future<void> _call112() async {
    widget.lock.bypassForSafety(external: true);
    await launchUrl(Uri(scheme: 'tel', path: SafetyConstants.emergencyNumber));
  }

  Future<void> _medicalId() async {
    widget.lock.bypassForSafety(external: true);
    final ok = await AppSecurityNative.openMedicalId();
    if (!ok) widget.lock.relock();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.bg,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Space.s24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.lock_outline_rounded, size: 48, color: AppTheme.primary),
                  const SizedBox(height: Space.s16),
                  Semantics(header: true, child: Text(AppLockScreen.title, textAlign: TextAlign.center, style: AppText.title)),
                  const SizedBox(height: Space.s8),
                  Text('Use your fingerprint or screen lock. SOS, Call ${SafetyConstants.emergencyNumber} and your Medical ID work without unlocking.',
                      textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppTheme.textSecondary)),
                  const SizedBox(height: Space.s24),
                  DsButton(
                    key: const Key('app_lock_unlock'),
                    label: _busy ? 'Waiting…' : 'Unlock',
                    icon: Icons.fingerprint_rounded,
                    onPressed: _busy ? null : _unlock,
                  ),
                  const SizedBox(height: Space.s32),
                  DsButton(key: const Key('app_lock_sos'), label: 'SOS', icon: Icons.sos_rounded, tone: DsButtonTone.sos, onPressed: _sos),
                  const SizedBox(height: Space.s12),
                  DsButton(
                    key: const Key('app_lock_call_112'),
                    label: 'Call ${SafetyConstants.emergencyNumber}',
                    icon: Icons.call_rounded,
                    tone: DsButtonTone.outline,
                    onPressed: _call112,
                  ),
                  const SizedBox(height: Space.s12),
                  DsButton(
                    key: const Key('app_lock_medical_id'),
                    label: 'Medical ID',
                    icon: Icons.medical_information_rounded,
                    tone: DsButtonTone.outline,
                    onPressed: _medicalId,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
