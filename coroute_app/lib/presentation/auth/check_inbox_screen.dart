import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/safety_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../domain/auth/account_flows.dart';

/// Round 4: after "Create account" the gateway e-mails a confirmation link (single use, 24 hours); the account works
/// once it is opened. This screen says so, offers "Send a new link" (rate limited, with a countdown) and goes back to
/// sign in.
class CheckInboxScreen extends StatefulWidget {
  const CheckInboxScreen({super.key, required this.email, required this.resend, this.resendAfterSec});

  final String email;

  /// Asks the gateway for a new link: null when done, else the message to show.
  final Future<String?> Function() resend;
  final int? resendAfterSec;

  static const String title = 'Check your inbox';

  @override
  State<CheckInboxScreen> createState() => _CheckInboxScreenState();
}

class _CheckInboxScreenState extends State<CheckInboxScreen> {
  final ResendTimer _timer = ResendTimer();
  Timer? _tick;
  int _secondsLeft = 0;
  bool _busy = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    _startTimer(widget.resendAfterSec);
  }

  void _startTimer(int? wait) {
    _timer.sent(DateTime.now(), serverWait: wait);
    _secondsLeft = wait ?? widget.resendAfterSec ?? 60;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_secondsLeft > 0) _secondsLeft--;
      });
      if (_secondsLeft <= 0 || _timer.canResend(DateTime.now())) _tick?.cancel();
    });
  }

  bool get _canResend => _timer.canResend(DateTime.now()) || _secondsLeft <= 0;

  String _resendLabel(DateTime now) {
    if (_canResend) return 'Send a new link';
    if (_secondsLeft > 0) return 'Send again in $_secondsLeft s';
    return _timer.label(now, action: 'Send a new link');
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _resend() async {
    setState(() => _busy = true);
    final err = await widget.resend();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = err ?? 'If this address is waiting for confirmation, a new link is on its way. Check your spam folder too.';
    });
    if (err == null) _startTimer(null);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Space.s24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.mark_email_unread_outlined, size: 56, color: AppTheme.primary),
                  const SizedBox(height: Space.s16),
                  Semantics(header: true, child: Text(CheckInboxScreen.title, textAlign: TextAlign.center, style: AppText.headline.copyWith(fontSize: 24))),
                  const SizedBox(height: Space.s12),
                  Text('Check your e-mail to finish creating your account. We sent a link to ${widget.email}. It works once, for 24 hours.',
                      textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppTheme.textSecondary)),
                  const SizedBox(height: Space.s8),
                  Text('Open it on this phone or any computer, then sign in here with your e-mail and password.',
                      textAlign: TextAlign.center, style: AppText.label),
                  if (_note != null) ...[
                    const SizedBox(height: Space.s16),
                    RideAlert(tier: AlertTier.normal, title: _note!),
                  ],
                  const SizedBox(height: Space.s24),
                  DsButton(
                    key: const Key('check_inbox_signin'),
                    label: 'Back to sign in',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(height: Space.s12),
                  DsButton(
                    key: const Key('check_inbox_resend'),
                    label: _busy ? 'Sending…' : _resendLabel(now),
                    tone: DsButtonTone.outline,
                    onPressed: _busy || !_canResend ? null : _resend,
                  ),
                  const SizedBox(height: Space.s24),
                  Center(
                    child: TextButton.icon(
                      onPressed: () => launchUrl(Uri(scheme: 'tel', path: SafetyConstants.emergencyNumber)),
                      icon: Icon(Icons.emergency_outlined, color: AppTheme.sos),
                      label: Text('Emergency? Call ${SafetyConstants.emergencyNumber}', style: TextStyle(color: AppTheme.sos, fontWeight: FontWeight.w600)),
                    ),
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
