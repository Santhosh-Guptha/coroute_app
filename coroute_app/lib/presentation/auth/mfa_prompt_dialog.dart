import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../domain/auth/account_flows.dart';
import '../security/secure_screen.dart';

/// Round 4 admin 2-step prompt: shown when an admin call answers 403 MFA_REQUIRED (ApiClient.onMfaRequired). The
/// code from the authenticator app (or a recovery code, or for operators an e-mailed code) marks this session as
/// 2-step verified on the gateway; the admin call is then repeated once. FLAG_SECURE while shown.
class MfaPromptDialog extends StatefulWidget {
  const MfaPromptDialog({super.key, required this.challenge, required this.submit, this.sendEmailCode});

  final MfaChallenge challenge;

  /// Sends the code: returns null when accepted, else the message to show.
  final Future<String?> Function({String? code, String? recoveryCode, String? emailCode}) submit;

  /// Operators only (never administrators): e-mails a code. Returns null when sent, else a message.
  final Future<String?> Function()? sendEmailCode;

  static const String title = '2-step verification';

  /// Shows the prompt; true when the session passed the step-up.
  static Future<bool> show(BuildContext context, {required MfaChallenge challenge,
      required Future<String?> Function({String? code, String? recoveryCode, String? emailCode}) submit, Future<String?> Function()? sendEmailCode}) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MfaPromptDialog(challenge: challenge, submit: submit, sendEmailCode: sendEmailCode),
    );
    return ok ?? false;
  }

  @override
  State<MfaPromptDialog> createState() => _MfaPromptDialogState();
}

class _MfaPromptDialogState extends State<MfaPromptDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  bool _emailSent = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final kind = mfaCodeKindOf(_code.text, emailSent: _emailSent);
    if (kind == MfaCodeKind.invalid) {
      setState(() => _error = 'Enter the 6-digit code, or a recovery code like ABCDE-12345.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final v = _code.text.trim().replaceAll(' ', '');
    final err = await widget.submit(
      code: kind == MfaCodeKind.totp ? v : null,
      recoveryCode: kind == MfaCodeKind.recovery ? v : null,
      emailCode: kind == MfaCodeKind.email ? v : null,
    );
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

  Future<void> _email() async {
    final f = widget.sendEmailCode;
    if (f == null) return;
    setState(() => _busy = true);
    final err = await f();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _emailSent = err == null;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.challenge;
    if (c.needsSetup) {
      return AlertDialog(
        title: const Text(MfaPromptDialog.title),
        content: Text('${c.message}\n\nAdmin tools need 2-step verification. Set it up first: sign in to the web admin on a computer; it guides you.',
            style: AppText.body),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('OK'))],
      );
    }
    return SecureScreen(
      child: AlertDialog(
        title: const Text(MfaPromptDialog.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_emailSent ? 'Enter the 6-digit code we e-mailed you.' : 'Enter the 6-digit code from your authenticator app, or a recovery code.',
                style: AppText.body),
            const SizedBox(height: Space.s12),
            TextField(
              key: const Key('mfa_code_field'),
              controller: _code,
              autofocus: true,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _busy ? null : _send(),
              decoration: const InputDecoration(labelText: 'Code'),
            ),
            if (_error != null) ...[
              const SizedBox(height: Space.s8),
              Text(_error!, style: AppText.label.copyWith(color: AppTheme.sos)),
            ],
            if (c.canUseEmail && widget.sendEmailCode != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: _busy ? null : _email, child: Text(_emailSent ? 'Send another e-mail code' : 'E-mail me a code instead')),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(key: const Key('mfa_submit'), onPressed: _busy ? null : _send, child: Text(_busy ? 'Checking…' : 'Confirm')),
        ],
      ),
    );
  }
}
