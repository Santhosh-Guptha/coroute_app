import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/config/app_config.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/safety_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/meta_service.dart';
import '../account/change_password_screen.dart';
import '../admin/master_admin_dashboard.dart';
import '../rider/rider_home_screen.dart';
import '../../domain/auth/account_flows.dart';
import '../security/secure_screen.dart';
import 'check_inbox_screen.dart';
import 'complete_profile_screen.dart';
import 'ride_lock_dialog.dart';
import 'package:coroute_app/core/ui/coroute_logo.dart';

/// Sign in and create account: one calm screen, one primary button.
///
/// Design system v3.55: small logo mark, one short line, light text, plenty
/// of space, secondary actions as plain text links. The backend calls and
/// the validation are unchanged.
class LoginScreen extends StatefulWidget {
  /// v3.58: "Get started" on the Welcome screen opens the create-account form; everything else signs in.
  final bool startInRegister;
  const LoginScreen({super.key, this.startInRegister = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  /// false: sign in, true: create account.
  late bool _register = widget.startInRegister;

  // Sign In Controllers
  final _loginIdentifierController = TextEditingController();
  final _loginPasswordController = TextEditingController();

  // Registration Controllers
  final _regNameController = TextEditingController();
  final _regEmailController = TextEditingController();
  final _regPasswordController = TextEditingController();
  final _regConfirmPasswordController = TextEditingController();
  final _regPhoneController = TextEditingController();
  final _regVehicleNoController = TextEditingController();
  final _regEmergencyNameController = TextEditingController();
  final _regEmergencyPhoneController = TextEditingController();

  bool _obscureLoginPassword = true;
  bool _obscureRegPassword = true;
  bool _obscureRegConfirmPassword = true;
  bool _isLoading = false;
  String? _errorMessage;

  /// Why the previous session ended (server said: blocked, deleted, signed in
  /// elsewhere). Shown once as a neutral, dismissible notice, not as a form
  /// error, and cleared as soon as the rider starts signing in.
  String? _sessionNotice;

  bool _isRegPillion = false;
  String _selectedVehicle = 'Motorcycle (Adv)';
  bool _acceptedTerms = false;

  final List<String> _vehicleTypes = [
    'Motorcycle (Adv)',
    'Motorcycle (Cruiser)',
    'Motorcycle (Sport)',
    'Motorcycle (Commuter)',
    'Scooter / Maxi',
    'Support Car / SUV',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        final auth = context.read<AuthService>();
        final reason = auth.lastSignOutReason;
        if (reason != null && reason.isNotEmpty) {
          setState(() => _sessionNotice = reason);
          auth.clearSignOutReason();
        }
      } on ProviderNotFoundException catch (_) {
        // Isolated widget tests
      }
    });
  }

  @override
  void dispose() {
    _loginIdentifierController.dispose();
    _loginPasswordController.dispose();
    _regNameController.dispose();
    _regEmailController.dispose();
    _regPasswordController.dispose();
    _regConfirmPasswordController.dispose();
    _regPhoneController.dispose();
    _regVehicleNoController.dispose();
    _regEmergencyNameController.dispose();
    _regEmergencyPhoneController.dispose();
    super.dispose();
  }

  Future<void> _enter(bool isAdmin) async {
    final auth = context.read<AuthService>();
    if (auth.mustChangePassword) {
      final changed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const ChangePasswordScreen(forced: true)),
      );
      if (changed != true || !mounted) return;
    }
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => isAdmin ? const MasterAdminDashboard() : const RiderHomeScreen()),
    );
  }

  String get _privacyUrl => context.read<MetaService>().meta?.privacyUrl.isNotEmpty == true
      ? context.read<MetaService>().meta!.privacyUrl
      : '${AppConfig.apiBaseUrl}/privacy';
  String get _termsUrl => context.read<MetaService>().meta?.termsUrl.isNotEmpty == true
      ? context.read<MetaService>().meta!.termsUrl
      : '${AppConfig.apiBaseUrl}/terms';

  Future<void> _openUrl(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void _showForgotPassword() {
    final support = context.read<MetaService>().meta?.supportEmail ?? '';
    showAppSheet<void>(
      context,
      title: 'Forgot your password?',
      builder: (ctx) => SingleChildScrollView(
        child: Text(
          'If you registered with Google, use "Continue with Google".\n\n'
          'Otherwise e-mail ${support.isNotEmpty ? support : 'the CoRoute team'} from the address you registered with. '
          'An admin will give you a temporary password. You set a new one when you sign in.',
          style: AppText.body.copyWith(color: AppTheme.text2),
        ),
      ),
    );
  }

  // --- SIGN IN ACTION ---
  Future<void> _handleSignIn() async {
    final identifier = _loginIdentifierController.text.trim();
    final password = _loginPasswordController.text.trim();

    if (identifier.isEmpty) {
      setState(() => _errorMessage = 'Please enter your email or callsign.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _sessionNotice = null;
    });

    final auth = context.read<AuthService>();
    final res = await auth.loginRiderWithPassword(
      identifier: identifier,
      password: password,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (res['success'] == true) {
      _enter(res['isAdmin'] == true);
    } else if (await _handleRideLock(res)) {
      return;
    } else {
      setState(() {
        _errorMessage = res['error']?.toString() ?? 'Invalid credentials.';
      });
      if (needsEmailVerification(res)) _offerNewLink(identifier.contains('@') ? identifier : (res['body'] is Map ? (res['body'] as Map)['email']?.toString() ?? '' : ''));
    }
  }

  /// Round 4 ride lock: another phone of this account is on a ride (423 RIDE_ACTIVE_ELSEWHERE). Shows the dialog
  /// with "Send code to my e-mail"; true when the result was such a refusal (signed in or not).
  Future<bool> _handleRideLock(Map<String, dynamic> res) async {
    final challenge = RideLockChallenge.fromResult(res);
    if (challenge == null) return false;
    final auth = context.read<AuthService>();
    final ok = await RideLockDialog.show(
      context,
      challenge: challenge,
      sendCode: () async {
        final r = await auth.sendRideLockCode(challenge.lockToken);
        final wait = r['resendAfterSec'];
        final body = r['body'];
        final retry = body is Map ? body['retryAfterSec'] : null;
        return (
          error: r['success'] == true ? null : (r['error']?.toString() ?? 'Could not send the code.'),
          resendAfterSec: wait is num ? wait.toInt() : (retry is num ? retry.toInt() : null),
          sentTo: r['sentTo']?.toString(),
        );
      },
      verifyCode: (code) async {
        final r = await auth.verifyRideLockCode(challenge.lockToken, code);
        return r['success'] == true ? null : (r['error']?.toString() ?? 'That code did not work.');
      },
    );
    if (!mounted) return true;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Signed in. Your other phone was signed out; your group sees you switched phones.')));
      _enter(auth.isMasterAdmin);
    } else {
      setState(() => _errorMessage = challenge.message);
    }
    return true;
  }

  /// Round 4: the address is not confirmed yet: offer a new link.
  void _offerNewLink(String email) {
    if (email.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 10),
      content: const Text('Confirm your e-mail first. Need a new link?'),
      action: SnackBarAction(label: 'Send link', onPressed: () => context.read<AuthService>().resendVerification(email).ignore()),
    ));
  }

  /// Round 4: "Check your inbox" after creating an account (the link makes it usable).
  Future<void> _showCheckInbox(String email, int? resendAfterSec) async {
    final auth = context.read<AuthService>();
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => CheckInboxScreen(
          email: email,
          resendAfterSec: resendAfterSec,
          resend: () async {
            final r = await auth.resendVerification(email);
            return r['success'] == true ? null : r['error']?.toString();
          },
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _register = false;
      _loginIdentifierController.text = email;
      _errorMessage = null;
    });
  }

  // --- REGISTRATION ACTION ---
  Future<void> _handleRegistration() async {
    final name = _regNameController.text.trim();
    final email = _regEmailController.text.trim();
    final password = _regPasswordController.text.trim();
    final confirmPassword = _regConfirmPasswordController.text.trim();
    final phone = _regPhoneController.text.trim();
    final vehicleNo = _regVehicleNoController.text.trim();
    final emergencyName = _regEmergencyNameController.text.trim();
    final emergencyPhone = _regEmergencyPhoneController.text.trim();

    if (name.isEmpty) {
      setState(() => _errorMessage = 'Please enter your callsign or full name.');
      return;
    }
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _errorMessage = 'Please provide a valid email address.');
      return;
    }
    if (password.length < 8) {
      setState(() => _errorMessage = 'Password must be at least 8 characters long.');
      return;
    }
    if (password != confirmPassword) {
      setState(() => _errorMessage = 'Passwords do not match. Please re-enter.');
      return;
    }
    if (phone.length < 7) {
      setState(() => _errorMessage = 'Enter your mobile number so your group can call you.');
      return;
    }
    if (!_isRegPillion && vehicleNo.length < 3) {
      setState(() => _errorMessage = 'Enter your bike number, or choose Pillion.');
      return;
    }
    if (emergencyName.length < 2) {
      setState(() => _errorMessage = 'Enter the name of your emergency contact.');
      return;
    }
    if (emergencyPhone.length < 7) {
      setState(() => _errorMessage = 'Enter the phone number of your emergency contact.');
      return;
    }
    if (!_acceptedTerms) {
      setState(() => _errorMessage = 'Please accept the Terms of Use and Privacy Policy to register.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _sessionNotice = null;
    });

    final auth = context.read<AuthService>();
    final res = await auth.registerRider(
      name: name,
      email: email,
      password: password,
      phone: phone,
      vehicleType: _isRegPillion ? 'Pillion Rider' : _selectedVehicle,
      vehicleNo: _isRegPillion ? 'PILLION' : vehicleNo,
      emergencyContact: emergencyPhone,
      emergencyContactName: emergencyName,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    final outcome = signUpOutcomeOf(res);
    if (outcome == SignUpOutcome.checkInbox) {
      final wait = res['resendAfterSec'];
      await _showCheckInbox(email, wait is num ? wait.toInt() : null);
    } else if (outcome == SignUpOutcome.signedIn) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Welcome to CoRoute, $name.')),
      );
      _enter(res['isAdmin'] == true);
    } else {
      setState(() {
        _errorMessage = res['error']?.toString() ?? 'Registration failed.';
      });
    }
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _sessionNotice = null;
    });

    final auth = context.read<AuthService>();
    final res = await auth.signInWithGoogle();

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (res['success'] == true) {
      final isAdmin = res['isAdmin'] == true;
      if (!auth.isProfileComplete && !isAdmin) {
        final completed = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => const CompleteProfileScreen(forced: true, isGoogleUser: true),
          ),
        );
        if (completed != true || !mounted) return;
      }
      _enter(isAdmin);
    } else if (await _handleRideLock(res)) {
      return;
    } else {
      setState(() {
        _errorMessage = res['error']?.toString();
      });
    }
  }

  /// Switches between sign in and create account. A form error from one
  /// mode means nothing in the other one.
  void _setMode(bool register) {
    if (register == _register) return;
    setState(() {
      _register = register;
      _errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Round 4: FLAG_SECURE on the sign-in screen (passwords; no screenshots or Recents preview).
    return SecureScreen(child: _scaffold(context));
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 36),

                  // Previous session ended (stale token on launch, block, delete):
                  // neutral and dismissible, so a fresh launch does not open on an error.
                  if (_sessionNotice != null && _errorMessage == null) ...[
                    RideAlert(
                      tier: AlertTier.normal,
                      title: _sessionNotice!,
                      message: 'You were signed out. Sign in to continue.',
                      onDismiss: () => setState(() => _sessionNotice = null),
                    ),
                    const SizedBox(height: Space.s16),
                  ],

                  if (_errorMessage != null) ...[
                    RideAlert(tier: AlertTier.important, title: _errorMessage!),
                    const SizedBox(height: Space.s16),
                  ],

                  // A gentle fade between the two modes, nothing more.
                  AnimatedSwitcher(
                    duration: Motion.tab,
                    switchInCurve: Motion.curve,
                    switchOutCurve: Motion.curve,
                    child: KeyedSubtree(
                      key: ValueKey<bool>(_register),
                      child: _register ? _buildRegistrationForm() : _buildSignInForm(),
                    ),
                  ),

                  if (!_register) _buildLegalFooter(),
                  // 3.57: help is one tap away even when signed out (the lock-screen Medical ID works without
                  // the app open; SOS in a ride never waits for a sign-in).
                  const SizedBox(height: Space.s16),
                  Center(
                    child: TextButton.icon(
                      key: const Key('login_call_112'),
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

  /// Small logo mark, the name and one short line.
  Widget _buildHeader() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CoRouteAppIcon(size: 44, semanticLabel: null),
        const SizedBox(height: Space.s16),
        // v3.58 logo: the helmet is the "o" of CoRoute.
        const CoRouteWordmark(fontSize: 28),
        const SizedBox(height: Space.s4),
        Text(
          'Ride together, safely.',
          textAlign: TextAlign.center,
          style: AppText.body.copyWith(color: AppTheme.textMuted),
        ),
      ],
    );
  }

  /// Floating-label field: the label sits inside the box, so no extra
  /// label line above it.
  InputDecoration _dec(String label, {IconData? icon, Widget? suffix, String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon, size: 22),
        suffixIcon: suffix,
      );

  Widget _eye(bool obscure, VoidCallback onTap) => IconButton(
        tooltip: obscure ? 'Show password' : 'Hide password',
        icon: Icon(obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 22),
        onPressed: onTap,
      );

  Widget _or() => Row(
        children: [
          Expanded(child: Divider(color: AppTheme.border)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text('or', style: AppText.caption.copyWith(color: AppTheme.textFaint)),
          ),
          Expanded(child: Divider(color: AppTheme.border)),
        ],
      );

  Widget _googleButton() => DsButton(
        label: 'Continue with Google',
        icon: Icons.g_mobiledata_rounded,
        tone: DsButtonTone.outline,
        fontSize: 15,
        onPressed: _isLoading ? null : _handleGoogleSignIn,
      );

  /// "New here?  Create account" as plain text with one link.
  Widget _switchLink(String lead, String action, VoidCallback onTap) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(child: Text(lead, style: AppText.body.copyWith(color: AppTheme.textMuted))),
          TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: Text(action),
          ),
        ],
      );

  /// Small sentence-case group label inside the long form.
  Widget _group(String text, IconData icon, {Color? color}) => Padding(
        padding: const EdgeInsets.only(top: Space.s24, bottom: Space.s12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color ?? AppTheme.textMuted),
            const SizedBox(width: Space.s8),
            Expanded(child: Text(text, style: AppText.overline.copyWith(color: color ?? AppTheme.textMuted))),
          ],
        ),
      );

  // --- SIGN IN FORM ---
  Widget _buildSignInForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _loginIdentifierController,
          inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxEmailLength)],
          textInputAction: TextInputAction.next,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.username, AutofillHints.email],
          autocorrect: false,
          style: AppText.body,
          decoration: _dec('Email or callsign', icon: Icons.person_outline_rounded),
        ),
        const SizedBox(height: Space.s12),
        TextField(
          controller: _loginPasswordController,
          obscureText: _obscureLoginPassword,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) {
            if (!_isLoading) _handleSignIn();
          },
          style: AppText.body,
          decoration: _dec(
            'Password',
            icon: Icons.lock_outline_rounded,
            suffix: _eye(_obscureLoginPassword, () => setState(() => _obscureLoginPassword = !_obscureLoginPassword)),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _showForgotPassword,
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
            child: Text('Forgot password?', style: AppText.label.copyWith(color: AppTheme.primary)),
          ),
        ),
        const SizedBox(height: Space.s8),
        DsButton(
          label: _isLoading ? 'Signing in…' : 'Sign in',
          onPressed: _isLoading ? null : _handleSignIn,
        ),
        const SizedBox(height: Space.s24),
        _or(),
        const SizedBox(height: Space.s24),
        _googleButton(),
        const SizedBox(height: Space.s32),
        _switchLink('New here?', 'Create account', () => _setMode(true)),
      ],
    );
  }

  // --- REGISTRATION FORM ---
  Widget _buildRegistrationForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your details', style: AppText.title.copyWith(fontSize: 18)),
        const SizedBox(height: Space.s4),
        Text('Your group sees these. Kept for emergencies.', style: AppText.label),
        const SizedBox(height: Space.s16),

        // Field order is unchanged: name, email, phone, password, confirm.
        TextField(
          controller: _regNameController,
          inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxCallsignLength)],
          textInputAction: TextInputAction.next,
          style: AppText.body,
          decoration: _dec('Name or callsign', icon: Icons.person_outline_rounded),
        ),
        const SizedBox(height: Space.s12),
        TextField(
          controller: _regEmailController,
          inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxEmailLength)],
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          style: AppText.body,
          decoration: _dec('Email', icon: Icons.mail_outline_rounded),
        ),
        const SizedBox(height: Space.s12),
        TextField(
          controller: _regPhoneController,
          inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxPhoneInputLength)],
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.next,
          style: AppText.body,
          decoration: _dec('Phone', icon: Icons.phone_outlined),
        ),
        const SizedBox(height: Space.s12),
        TextField(
          controller: _regPasswordController,
          obscureText: _obscureRegPassword,
          textInputAction: TextInputAction.next,
          style: AppText.body,
          decoration: _dec(
            'Password',
            hint: 'At least 8 characters',
            icon: Icons.lock_outline_rounded,
            suffix: _eye(_obscureRegPassword, () => setState(() => _obscureRegPassword = !_obscureRegPassword)),
          ),
        ),
        const SizedBox(height: Space.s12),
        TextField(
          controller: _regConfirmPasswordController,
          obscureText: _obscureRegConfirmPassword,
          textInputAction: TextInputAction.next,
          style: AppText.body,
          decoration: _dec(
            'Confirm password',
            icon: Icons.lock_outline_rounded,
            suffix: _eye(_obscureRegConfirmPassword, () => setState(() => _obscureRegConfirmPassword = !_obscureRegConfirmPassword)),
          ),
        ),

        _group('Your ride', Icons.two_wheeler_outlined),
        DsSegment<bool>(
          values: const [false, true],
          selected: _isRegPillion,
          label: (pillion) => pillion ? 'Pillion' : 'Rider',
          onChanged: (pillion) => setState(() => _isRegPillion = pillion),
        ),
        const SizedBox(height: Space.s12),
        if (!_isRegPillion) ...[
          InputDecorator(
            decoration: _dec('Vehicle type').copyWith(contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _selectedVehicle,
                dropdownColor: AppTheme.card,
                isExpanded: true,
                isDense: true,
                style: AppText.body,
                items: _vehicleTypes.map((v) => DropdownMenuItem(value: v, child: Text(v, overflow: TextOverflow.ellipsis))).toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _selectedVehicle = val);
                },
              ),
            ),
          ),
          const SizedBox(height: Space.s12),
          TextField(
            controller: _regVehicleNoController,
            inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxVehicleNoLength)],
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.next,
            style: AppText.body,
            decoration: _dec('Bike number', hint: 'KA 01 AB 1234'),
          ),
        ] else
          Row(
            children: [
              Icon(Icons.check_circle_outline_rounded, size: 20, color: AppTheme.success),
              const SizedBox(width: Space.s8),
              Expanded(child: Text('No bike number needed.', style: AppText.label)),
            ],
          ),

        _group('Emergency contact', Icons.emergency_outlined, color: AppTheme.sos),
        TextField(
          controller: _regEmergencyNameController,
          inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxContactNameLength)],
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          style: AppText.body,
          decoration: _dec('Contact name', icon: Icons.person_outline_rounded),
        ),
        const SizedBox(height: Space.s12),
        TextField(
          controller: _regEmergencyPhoneController,
          inputFormatters: [LengthLimitingTextInputFormatter(AppConstants.maxPhoneInputLength)],
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          style: AppText.body,
          decoration: _dec('Contact phone', icon: Icons.phone_outlined),
        ),

        const SizedBox(height: Space.s16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Checkbox(
              value: _acceptedTerms,
              onChanged: (v) => setState(() => _acceptedTerms = v ?? false),
            ),
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('I accept the ', style: AppText.label),
                  _link('Terms', _termsUrl),
                  Text(' and ', style: AppText.label),
                  _link('Privacy Policy', _privacyUrl),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.s16),
        DsButton(
          label: _isLoading ? 'Creating account…' : 'Create account',
          onPressed: _isLoading ? null : _handleRegistration,
        ),
        const SizedBox(height: Space.s24),
        _or(),
        const SizedBox(height: Space.s24),
        _googleButton(),
        const SizedBox(height: Space.s24),
        _switchLink('Have an account?', 'Sign in', () => _setMode(false)),
      ],
    );
  }

  Widget _link(String text, String url) => InkWell(
        onTap: () => _openUrl(url),
        child: Text(
          text,
          style: AppText.label.copyWith(color: AppTheme.primary, decoration: TextDecoration.underline, decorationColor: AppTheme.primary),
        ),
      );

  /// One faint line at the bottom.
  Widget _buildLegalFooter() {
    final faint = AppText.caption.copyWith(color: AppTheme.textMuted);
    return Padding(
      padding: const EdgeInsets.only(top: Space.s24),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('By continuing you agree to the ', style: faint),
          InkWell(onTap: () => _openUrl(_termsUrl), child: Text('Terms', style: faint.copyWith(decoration: TextDecoration.underline))),
          Text(' and ', style: faint),
          InkWell(onTap: () => _openUrl(_privacyUrl), child: Text('Privacy Policy', style: faint.copyWith(decoration: TextDecoration.underline))),
          Text('.', style: faint),
        ],
      ),
    );
  }
}

/// Backwards compatibility typedef
typedef AccessGateScreen = LoginScreen;
