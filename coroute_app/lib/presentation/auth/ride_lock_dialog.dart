import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/safety_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../domain/auth/account_flows.dart';
import '../security/secure_screen.dart';

/// Round 4 ride lock: a sign-in was refused because another phone of this account is on a ride (423
/// RIDE_ACTIVE_ELSEWHERE). Explains it, offers "Send code to my e-mail", the 6-digit code entry with a resend timer,
/// and keeps "Call 112" visible. The right code signs this phone in (the other phone's ride is handed over to the group
/// as "(rider) switched phones"; an open SOS stays open). FLAG_SECURE while shown.
class RideLockDialog extends StatefulWidget {
  const RideLockDialog({super.key, required this.challenge, required this.sendCode, required this.verifyCode});

  final RideLockChallenge challenge;

  /// Sends the code: null when sent (resendAfterSec in [onSent]), else the message to show.
  final Future<({String? error, int? resendAfterSec, String? sentTo})> Function() sendCode;

  /// Checks the code: null when signed in, else the message to show.
  final Future<String?> Function(String code) verifyCode;

  /// Shows the dialog; true when this phone is now signed in.
  static Future<bool> show(BuildContext context, {required RideLockChallenge challenge,
      required Future<({String? error, int? resendAfterSec, String? sentTo})> Function() sendCode, required Future<String?> Function(String code) verifyCode}) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RideLockDialog(challenge: challenge, sendCode: sendCode, verifyCode: verifyCode),
    );
    return ok ?? false;
  }

  @override
  State<RideLockDialog> createState() => _RideLockDialogState();
}

class _RideLockDialogState extends State<RideLockDialog> {
  final _code = TextEditingController();
  final ResendTimer _timer = ResendTimer();
  Timer? _tick;
  bool _sent = false;
  bool _busy = false;
  String? _error;
  String? _sentTo;

  @override
  void dispose() {
    _tick?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await widget.sendCode();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.error == null) {
        _sent = true;
        _sentTo = r.sentTo;
        _timer.sent(DateTime.now(), serverWait: r.resendAfterSec);
        _tick?.cancel();
        _tick = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted) return;
          setState(() {});
          if (_timer.canResend(DateTime.now())) _tick?.cancel();
        });
      } else {
        _error = r.error;
      }
    });
  }

  Future<void> _verify() async {
    if (!isValidEmailCode(_code.text)) {
      setState(() => _error = 'Enter the 6-digit code from the e-mail.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.verifyCode(cleanEmailCode(_code.text));
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return SecureScreen(
      child: AlertDialog(
        title: Text(widget.challenge.title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.challenge.message, style: AppText.body),
              const SizedBox(height: Space.s8),
              Text("Phone lost, broken or out of battery? We can e-mail you a code. Using it signs the other phone out; your group sees that you switched phones and any SOS stays open.",
                  style: AppText.label.copyWith(color: AppTheme.textSecondary)),
              if (_sent) ...[
                const SizedBox(height: Space.s16),
                Text(_sentTo == null ? 'We sent a 6-digit code to your e-mail.' : 'We sent a 6-digit code to $_sentTo.', style: AppText.body),
                const SizedBox(height: Space.s8),
                TextField(
                  key: const Key('ride_lock_code'),
                  controller: _code,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')), LengthLimitingTextInputFormatter(7)],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _busy ? null : _verify(),
                  decoration: const InputDecoration(labelText: '6-digit code'),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('ride_lock_resend'),
                    onPressed: _busy || !_timer.canResend(now) ? null : _send,
                    child: Text(_timer.label(now)),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: Space.s8),
                Text(_error!, style: AppText.label.copyWith(color: AppTheme.sos)),
              ],
              const SizedBox(height: Space.s8),
              TextButton.icon(
                key: const Key('ride_lock_call_112'),
                onPressed: () => launchUrl(Uri(scheme: 'tel', path: SafetyConstants.emergencyNumber)),
                icon: Icon(Icons.emergency_outlined, color: AppTheme.sos),
                label: Text('Emergency? Call ${SafetyConstants.emergencyNumber}', style: TextStyle(color: AppTheme.sos, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Close')),
          if (!_sent)
            FilledButton(key: const Key('ride_lock_send'), onPressed: _busy ? null : _send, child: Text(_busy ? 'Sending…' : 'Send code to my e-mail'))
          else
            FilledButton(key: const Key('ride_lock_verify'), onPressed: _busy ? null : _verify, child: Text(_busy ? 'Checking…' : 'Sign in')),
        ],
      ),
    );
  }
}
