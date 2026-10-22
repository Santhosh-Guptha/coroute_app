import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/auth_service.dart';

/// Change password. When [forced] (temporary password issued by an admin) the
/// current password is not asked for and the screen cannot be dismissed.
class ChangePasswordScreen extends StatefulWidget {
  final bool forced;
  const ChangePasswordScreen({super.key, this.forced = false});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final next = _next.text;
    if (next.length < 8) {
      setState(() => _error = 'New password must be at least 8 characters.');
      return;
    }
    if (next != _confirm.text) {
      setState(() => _error = 'The two passwords do not match.');
      return;
    }
    if (!widget.forced && _current.text.isEmpty) {
      setState(() => _error = 'Enter your current password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final res = await context.read<AuthService>().changePassword(currentPassword: _current.text, newPassword: next);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res['success'] == true) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password changed.')));
      Navigator.pop(context, true);
    } else {
      setState(() => _error = res['error']?.toString() ?? 'Could not change the password.');
    }
  }

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        prefixIcon: Icon(Icons.lock_outline_rounded, color: AppTheme.accentText, size: 22),
        suffixIcon: IconButton(
          tooltip: _obscure ? 'Show passwords' : 'Hide passwords',
          icon: Icon(_obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: AppTheme.muted),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final err = _error;
    return PopScope(
      canPop: !widget.forced,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        backgroundColor: AppTheme.bg,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListView(
                physics: const BouncingScrollPhysics(),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: dsScreenPadding,
                children: [
                  DsScreenHeader(
                    title: widget.forced ? 'Set a new password' : 'Change password',
                    subtitle: widget.forced ? 'Choose one you will remember' : 'At least 8 characters',
                    onBack: widget.forced ? null : () => Navigator.maybePop(context),
                  ),
                  const SizedBox(height: 18),
                  if (widget.forced)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.s16),
                      child: DsCard(
                        tinted: true,
                        borderColor: AppTheme.tint,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.info_outline_rounded, size: 22, color: AppTheme.accentText),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'You signed in with a temporary password. Choose a new one to continue.',
                                style: AppText.body,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (!widget.forced) ...[
                    TextField(controller: _current, obscureText: _obscure, style: AppText.body, decoration: _dec('Current password')),
                    const SizedBox(height: 12),
                  ],
                  TextField(controller: _next, obscureText: _obscure, style: AppText.body, decoration: _dec('New password (8+ characters)')),
                  const SizedBox(height: 12),
                  TextField(controller: _confirm, obscureText: _obscure, style: AppText.body, decoration: _dec('Repeat new password')),
                  if (err != null) ...[
                    const SizedBox(height: 12),
                    RideAlert(tier: AlertTier.important, title: err),
                  ],
                  const SizedBox(height: Space.s24),
                  DsButton(
                    label: _busy ? 'Saving...' : 'Save password',
                    onPressed: _busy ? null : _submit,
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
